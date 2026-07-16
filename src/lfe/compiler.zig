//! 层流图构建器：将 AST 编译为层流图。
//!
//! 阶段 1 范围：
//! - 整数/浮点/布尔/字符字面量
//! - 变量绑定与引用（val_decl / identifier）
//! - 二元算术（add/sub/mul/div/mod, 位运算, 比较）
//! - 一元运算（neg/not）
//! - 条件分支（if → select 谓词化）
//! - 块表达式（语句序列 + 尾表达式）
//! - 函数返回（halt_return）
//! - debug_print（用于 println 等副作用）
//!
//! 类型从 AST 结构本地推断（字面量后缀、操作数类型传播），
//! 阶段 2+ 可接入 sema 精确类型信息。

const std = @import("std");
const ast = @import("ast");
const lamina_mod = @import("lamina.zig");
const builtin = @import("builtin.zig");
const value = @import("value");

const Lamina = lamina_mod.Lamina;
const LaminaOp = lamina_mod.LaminaOp;
const ScalarChanType = lamina_mod.ScalarChanType;
const ChannelMeta = lamina_mod.ChannelMeta;
const LaminarGraph = lamina_mod.LaminarGraph;
const IntKind = lamina_mod.IntKind;
const FloatKind = lamina_mod.FloatKind;
const OrbitHub = lamina_mod.OrbitHub;
const OrbitHubKind = lamina_mod.OrbitHubKind;
const OrbitEntry = lamina_mod.OrbitEntry;
const Orbit = lamina_mod.Orbit;
const CondKind = lamina_mod.CondKind;
const ChannelScope = lamina_mod.ChannelScope;
const DeferEntry = lamina_mod.DeferEntry;
const ParamBind = lamina_mod.ParamBind;
const TraitMethodEntry = lamina_mod.TraitMethodEntry;

/// 编译错误
pub const CompileError = error{
    OutOfMemory,
    UnsupportedExpr,
    UnsupportedStmt,
    UnsupportedType,
};

/// 变量绑定：名称 → 通道索引
const VarBinding = struct {
    name: []const u8,
    chan: u16,
};

/// 轨道构建信息（编译期间使用）
const OrbitBuildInfo = struct {
    output_channel: u16 = 0,
    is_cyclic: bool = false,
    continue_channel: ?u16 = null,
    capture_channels: []const u16 = &.{},
    input_channels: []const u16 = &.{},
};

/// 函数轨道信息：用于递归调用时重用已编译的轨道
const FuncOrbitInfo = struct {
    orbit_index: u16,
    param_channels: []const u16, // 轨道入口参数通道索引
    output_channel: u16, // 轨道输出通道
    /// 轨道使用的通道范围 [channel_start, channel_end)
    /// 递归重入时需保存/恢复此范围内的所有通道，防止中间结果被覆盖
    channel_start: u16 = 0,
    channel_end: u16 = 0,
    /// 临时通道（在轨道范围外分配），用于递归调用结果暂存
    /// 递归调用流程：
    ///   1. stack_push 保存 [channel_start, channel_end)
    ///   2. 运行轨道 → out_chan 写入结果
    ///   3. move out_chan → temp_chan（暂存结果到范围外）
    ///   4. stack_pop 恢复 [channel_start, channel_end)（out_chan 被恢复为调用前值）
    ///   5. move temp_chan → out_chan（将结果写回 out_chan）
    temp_chan: u16 = 0,
};

/// E2: 闭包轨道信息（编译期追踪用）
const ClosureInfo = struct {
    orbit_index: u16,
    param_channels: []const u16, // 轨道内参数 bridge_in 通道
    capture_channels: []const u16, // 轨道内捕获 bridge_in 通道
    capture_count: u16, // 捕获数量（存储在闭包值中）
    output_channel: u16, // 轨道输出 bridge_out 通道
};

/// 作用域
const Scope = struct {
    bindings: std.ArrayList(VarBinding),

    fn init() Scope {
        return .{ .bindings = .empty };
    }

    fn deinit(self: *Scope, allocator: std.mem.Allocator) void {
        self.bindings.deinit(allocator);
    }

    fn lookup(self: *const Scope, name: []const u8) ?u16 {
        var i = self.bindings.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.bindings.items[i].name, name)) {
                return self.bindings.items[i].chan;
            }
        }
        return null;
    }

    fn define(self: *Scope, allocator: std.mem.Allocator, name: []const u8, chan: u16) !void {
        try self.bindings.append(allocator, .{ .name = name, .chan = chan });
    }
};

/// 层流图构建器
pub const LaminarCompiler = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    laminas: std.ArrayList(Lamina),
    channel_metas: std.ArrayList(ChannelMeta),
    channel_count: u16,
    string_table: std.ArrayList([]const u8),
    name_table: std.ArrayList([]const u8),
    scope_stack: std.ArrayList(Scope),
    /// async 函数/lambda 编译的子图列表（保留用于旧接口兼容）
    subgraphs: std.ArrayList(LaminarGraph) = .empty,
    /// async 函数名 → 子图索引（旧接口，保留用于非 orbit 路径）
    async_func_map: std.StringHashMap(u16) = undefined,
    /// async 函数名 → 轨道信息（E1：async 编译为轨道）
    async_orbit_map: std.StringHashMap(FuncOrbitInfo) = undefined,

    // ── 星轨模型编译状态 ──
    /// 已完成的轨道 lamina 序列列表（索引 = 轨道索引）
    orbit_laminas_list: std.ArrayList([]const Lamina) = .empty,
    /// 轨道构建信息（索引 = 轨道索引）
    orbit_build_infos: std.ArrayList(OrbitBuildInfo) = .empty,
    /// OrbitHub 元数据列表
    orbit_hubs_list: std.ArrayList(OrbitHub) = .empty,
    /// 通道归属层级（与 channel_metas 一一对应）
    channel_scopes_list: std.ArrayList(ChannelScope) = .empty,
    /// defer 条目列表
    defer_entries_list: std.ArrayList(DeferEntry) = .empty,
    /// 轨道上下文保存栈（用于嵌套轨道）
    saved_laminas_stack: std.ArrayList(std.ArrayList(Lamina)) = .empty,
    /// 当前是否在轨道上下文中编译
    in_orbit: bool = false,
    /// 当前谓词通道（用于循环体门控：条件为假时跳过体操作）
    current_predicate: ?u16 = null,
    /// 函数表：函数名 → 声明指针（在 compile 中初始化）
    func_table: std.StringHashMap(*const ast.Decl) = undefined,
    /// 当前函数调用的返回通道（null = main 函数的 halt_return）
    current_return_channel: ?u16 = null,
    /// 递归内联深度计数器（编译期展开 ≤ 3 层）
    recursion_depth: u32 = 0,
    /// isStatic 分析递归深度（避免递归函数体无限判定）
    isstatic_depth: u32 = 0,
    /// 函数轨道映射：函数名 → (轨道索引, 参数通道, 输出通道)
    /// 用于递归调用时重用已编译的函数轨道
    func_orbit_map: std.StringHashMap(FuncOrbitInfo) = undefined,

    // ── E2: 闭包/Trait 追踪 ──
    /// 闭包通道 → 闭包轨道信息（编译期追踪闭包值）
    closure_chan_map: std.AutoHashMap(u16, ClosureInfo) = undefined,
    /// Trait 值通道 → Trait 值信息（编译期追踪 trait 值）
    trait_chan_map: std.AutoHashMap(u16, u64) = undefined,
    /// Trait 方法分派表条目（运行时 trait_hub 查找用）
    trait_method_entries_list: std.ArrayList(TraitMethodEntry) = .empty,
    /// 下一个 trait type_tag（每个 inline_trait_value 分配唯一 tag）
    next_trait_type_tag: u64 = 1,

    /// 从模块编译层流图
    /// 返回的 LaminarGraph 持有 arena 所有权，调用者负责 deinit
    pub fn compile(allocator: std.mem.Allocator, module: ast.Module) CompileError!LaminarGraph {
        // arena 分配在堆上，所有权转移给 LaminarGraph
        const arena_ptr = try allocator.create(std.heap.ArenaAllocator);
        arena_ptr.* = std.heap.ArenaAllocator.init(allocator);
        errdefer {
            arena_ptr.deinit();
            allocator.destroy(arena_ptr);
        }
        const a = arena_ptr.allocator();

        var self = LaminarCompiler{
            .allocator = allocator,
            .arena = arena_ptr,
            .laminas = .empty,
            .channel_metas = .empty,
            .channel_count = 0,
            .string_table = .empty,
            .name_table = .empty,
            .scope_stack = .empty,
            .async_func_map = std.StringHashMap(u16).init(a),
            .async_orbit_map = std.StringHashMap(FuncOrbitInfo).init(a),
            .func_table = std.StringHashMap(*const ast.Decl).init(a),
            .func_orbit_map = std.StringHashMap(FuncOrbitInfo).init(a),
            .closure_chan_map = std.AutoHashMap(u16, ClosureInfo).init(a),
            .trait_chan_map = std.AutoHashMap(u16, u64).init(a),
        };

        // 第一遍：扫描所有函数，建立函数表
        for (module.declarations) |*decl| {
            switch (decl.*) {
                .fun_decl => |*f| {
                    if (!f.is_async) {
                        try self.func_table.put(f.name, decl);
                    }
                },
                else => {},
            }
        }

        // 第二遍：扫描所有 async 函数，编译为异步轨道（E1：orbit_hub_async）
        for (module.declarations) |decl| {
            switch (decl) {
                .fun_decl => |f| {
                    if (f.is_async) {
                        try self.compileAsyncOrbit(f);
                    }
                },
                else => {},
            }
        }

        // 查找 main 函数
        for (module.declarations) |decl| {
            switch (decl) {
                .fun_decl => |f| {
                    if (std.mem.eql(u8, f.name, "main")) {
                        try self.compileFunction(f);
                        break;
                    }
                },
                else => {},
            }
        }

        // 确定 output_channel：最后一个 halt_return 的 output
        var output_chan: u16 = 0;
        for (self.laminas.items) |lam| {
            if (lam.op == .halt_return) output_chan = lam.output;
        }

        // 组装轨道列表
        const orbits = try a.alloc(Orbit, self.orbit_laminas_list.items.len);
        for (self.orbit_laminas_list.items, self.orbit_build_infos.items, 0..) |olams, info, i| {
            orbits[i] = .{
                .laminas = olams,
                .output_channel = info.output_channel,
                .is_cyclic = info.is_cyclic,
                .continue_channel = info.continue_channel,
                .capture_channels = info.capture_channels,
                .input_channels = info.input_channels,
            };
        }

        const graph = LaminarGraph{
            .laminas = try a.dupe(Lamina, self.laminas.items),
            .channel_metas = try a.dupe(ChannelMeta, self.channel_metas.items),
            .channel_count = self.channel_count,
            .input_channels = &.{},
            .output_channel = output_chan,
            .string_table = try a.dupe([]const u8, self.string_table.items),
            .name_table = try a.dupe([]const u8, self.name_table.items),
            .subgraphs = try a.dupe(LaminarGraph, self.subgraphs.items),
            .orbits = orbits,
            .orbit_hubs = try a.dupe(OrbitHub, self.orbit_hubs_list.items),
            .defer_entries = try a.dupe(DeferEntry, self.defer_entries_list.items),
            .channel_scopes = try a.dupe(ChannelScope, self.channel_scopes_list.items),
            .trait_method_table = try a.dupe(TraitMethodEntry, self.trait_method_entries_list.items),
            .arena = arena_ptr,
        };

        return graph;
    }

    /// 编译 async 函数为子图
    /// 保存当前编译状态，切换到子图上下文编译，再恢复
    fn compileAsyncSubgraph(self: *LaminarCompiler, f: anytype) !void {
        // 保存主图的编译状态
        const saved_laminas = self.laminas;
        const saved_metas = self.channel_metas;
        const saved_count = self.channel_count;
        const saved_scopes = self.scope_stack;
        const saved_chan_scopes = self.channel_scopes_list;

        // 子图使用独立的编译状态
        self.laminas = .empty;
        self.channel_metas = .empty;
        self.channel_count = 0;
        self.scope_stack = .empty;
        self.channel_scopes_list = .empty;

        const func_idx: u16 = @intCast(self.subgraphs.items.len);
        const a = self.arena.allocator();

        // 编译函数体（含参数和 halt_return）
        try self.compileFunction(f);

        // 确定子图 output_channel
        var sub_output: u16 = 0;
        for (self.laminas.items) |lam| {
            if (lam.op == .halt_return) sub_output = lam.output;
        }

        // 收集输入通道（参数通道索引）
        var input_list = std.ArrayList(u16).empty;
        defer input_list.deinit(a);
        if (f.params.len > 0) {
            // 参数是子图的前 N 个通道
            for (0..@intCast(f.params.len)) |i| {
                try input_list.append(a, @intCast(i));
            }
        }

        const subgraph = LaminarGraph{
            .laminas = try a.dupe(Lamina, self.laminas.items),
            .channel_metas = try a.dupe(ChannelMeta, self.channel_metas.items),
            .channel_count = self.channel_count,
            .input_channels = try a.dupe(u16, input_list.items),
            .output_channel = sub_output,
            .string_table = &.{},
            .name_table = &.{},
            .arena = null, // 子图不持有 arena
        };
        try self.subgraphs.append(a, subgraph);

        // 记录函数名 → 子图索引
        try self.async_func_map.put(f.name, func_idx);

        // 恢复主图的编译状态
        self.laminas = saved_laminas;
        self.channel_metas = saved_metas;
        self.channel_count = saved_count;
        self.scope_stack = saved_scopes;
        self.channel_scopes_list = saved_chan_scopes;
    }

    /// E1：编译 async 函数为异步轨道（替代 compileAsyncSubgraph）
    /// async 函数体编译为轨道模板，调用时通过 orbit_hub_async 激活
    fn compileAsyncOrbit(self: *LaminarCompiler, f: anytype) !void {
        const a = self.arena.allocator();

        // 开始异步轨道
        const orbit_idx = try self.beginOrbit();
        try self.pushScope();

        // 分配桥接入口通道（bridge_in）并绑定参数
        const param_channels = try a.alloc(u16, f.params.len);
        for (f.params, 0..) |param, i| {
            const chan_type = mapTypeNode(param.type_annotation) orelse .i64_chan;
            const param_chan = try self.allocBridgeInChannel(chan_type);
            param_channels[i] = param_chan;
            try self.defineVar(param.name, param_chan);
        }

        // 分配桥接出口通道（bridge_out）
        const ret_type = if (f.return_type) |rt|
            mapTypeNode(rt) orelse .i64_chan
        else
            .i64_chan;
        const ret_chan = try self.allocBridgeOutChannel(ret_type);

        // 设置返回通道
        const saved_return_channel = self.current_return_channel;
        self.current_return_channel = ret_chan;

        // 编译函数体
        const body_result = try self.compileExpr(f.body);

        // 尾表达式 fallback：move 到返回通道
        try self.emit(.{
            .op = .move,
            .inputs = .{ body_result, 0, 0 },
            .output = ret_chan,
            .input_count = 1,
        });

        // 恢复返回通道
        self.current_return_channel = saved_return_channel;
        self.popScope();

        // 固化轨道
        try self.endOrbit(orbit_idx, ret_chan, false, null);

        // 注册到 async_orbit_map（调用时通过 orbit_hub_async 激活）
        try self.async_orbit_map.put(f.name, .{
            .orbit_index = orbit_idx,
            .param_channels = param_channels,
            .output_channel = ret_chan,
        });
    }

    /// 释放构建器临时状态
    /// 注意：compile 返回的 LaminarGraph 已持有 arena 所有权，
    /// 调用者通过 graph.deinit(allocator) 释放。
    pub fn deinitScratch(self: *LaminarCompiler) void {
        for (self.scope_stack.items) |*s| s.deinit(self.arena.allocator());
        self.scope_stack.deinit(self.arena.allocator());
        self.laminas.deinit(self.arena.allocator());
        self.channel_metas.deinit(self.arena.allocator());
        self.string_table.deinit(self.arena.allocator());
        self.name_table.deinit(self.arena.allocator());
    }

    // ── 通道管理 ──

    fn allocChannel(self: *LaminarCompiler, chan_type: ScalarChanType) !u16 {
        return self.allocChannelScoped(chan_type, if (self.in_orbit) .orbit else .solar);
    }

    /// 分配通道并指定作用域（用于桥接通道标记）
    fn allocChannelScoped(self: *LaminarCompiler, chan_type: ScalarChanType, scope: ChannelScope) !u16 {
        const idx = self.channel_count;
        self.channel_count += 1;
        try self.channel_metas.append(self.arena.allocator(), .{
            .chan_type = chan_type,
            .elem_width = lamina_mod.chanElemWidth(chan_type),
        });
        try self.channel_scopes_list.append(self.arena.allocator(), scope);
        return idx;
    }

    /// 分配桥接入口通道（太阳层 → 轨道）：在轨道上下文中分配，标记为 bridge_in
    fn allocBridgeInChannel(self: *LaminarCompiler, chan_type: ScalarChanType) !u16 {
        return self.allocChannelScoped(chan_type, .bridge_in);
    }

    /// 分配桥接出口通道（轨道 → 太阳层）：在轨道上下文中分配，标记为 bridge_out
    fn allocBridgeOutChannel(self: *LaminarCompiler, chan_type: ScalarChanType) !u16 {
        return self.allocChannelScoped(chan_type, .bridge_out);
    }

    /// 分配 Nullable<T> 通道：elem_width = inner_width + 1（null 标志字节）
    fn allocNullableChannel(self: *LaminarCompiler, inner_type: ScalarChanType) !u16 {
        const idx = self.channel_count;
        self.channel_count += 1;
        try self.channel_metas.append(self.arena.allocator(), .{
            .chan_type = .nullable_chan,
            .elem_width = lamina_mod.nullableElemWidth(inner_type),
            .inner_type = inner_type,
        });
        const scope: ChannelScope = if (self.in_orbit) .orbit else .solar;
        try self.channel_scopes_list.append(self.arena.allocator(), scope);
        return idx;
    }

    fn internString(self: *LaminarCompiler, s: []const u8) !u16 {
        for (self.string_table.items, 0..) |item, i| {
            if (std.mem.eql(u8, item, s)) return @intCast(i);
        }
        const idx: u16 = @intCast(self.string_table.items.len);
        try self.string_table.append(self.arena.allocator(), s);
        return idx;
    }

    // ── 作用域管理 ──

    fn pushScope(self: *LaminarCompiler) !void {
        try self.scope_stack.append(self.arena.allocator(), Scope.init());
    }

    fn popScope(self: *LaminarCompiler) void {
        var scope = self.scope_stack.pop() orelse return;
        scope.deinit(self.arena.allocator());
    }

    fn lookupVar(self: *LaminarCompiler, name: []const u8) ?u16 {
        var i = self.scope_stack.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scope_stack.items[i].lookup(name)) |chan| return chan;
        }
        return null;
    }

    fn defineVar(self: *LaminarCompiler, name: []const u8, chan: u16) !void {
        if (self.scope_stack.items.len > 0) {
            try self.scope_stack.items[self.scope_stack.items.len - 1].define(
                self.arena.allocator(),
                name,
                chan,
            );
        }
    }

    // ── 层发射 ──

    fn emit(self: *LaminarCompiler, lam: Lamina) !void {
        var l = lam;
        // 应用当前谓词门控（循环体操作在条件为假时跳过）
        if (self.current_predicate) |p| {
            if (l.predicate == null) {
                l.predicate = p;
            }
        }
        // 记录 ref_kind 到通道元数据（用于 builtin 方法按类型分派）
        if (l.ref_kind != null and l.output < self.channel_metas.items.len) {
            self.channel_metas.items[l.output].ref_kind = l.ref_kind;
        }
        try self.laminas.append(self.arena.allocator(), l);
    }

    // ── 星轨模型：轨道上下文管理 ──

    /// 进入轨道上下文：保存当前 laminas，创建新的空列表
    /// 返回新轨道的索引
    fn beginOrbit(self: *LaminarCompiler) !u16 {
        const orbit_idx: u16 = @intCast(self.orbit_laminas_list.items.len);
        // 预留轨道 laminas 占位（endOrbit 时覆写）
        try self.orbit_laminas_list.append(self.arena.allocator(), &.{});
        // 预留轨道构建信息（endOrbit 时填充）
        try self.orbit_build_infos.append(self.arena.allocator(), .{});
        // 保存当前 laminas 到栈
        try self.saved_laminas_stack.append(self.arena.allocator(), self.laminas);
        // 创建新的空 laminas 列表
        self.laminas = .empty;
        self.in_orbit = true;
        return orbit_idx;
    }

    /// 退出轨道上下文：固化轨道 laminas，恢复父层 laminas
    fn endOrbit(
        self: *LaminarCompiler,
        orbit_idx: u16,
        output_channel: u16,
        is_cyclic: bool,
        continue_channel: ?u16,
    ) !void {
        return self.endOrbitFull(orbit_idx, output_channel, is_cyclic, continue_channel, &.{}, &.{});
    }

    /// 退出轨道上下文（带捕获通道信息，E2 闭包用）
    fn endOrbitWithCaptures(
        self: *LaminarCompiler,
        orbit_idx: u16,
        output_channel: u16,
        is_cyclic: bool,
        continue_channel: ?u16,
        capture_channels: []const u16,
    ) !void {
        return self.endOrbitFull(orbit_idx, output_channel, is_cyclic, continue_channel, &.{}, capture_channels);
    }

    /// 退出轨道上下文（完整版，带参数和捕获通道信息）
    fn endOrbitFull(
        self: *LaminarCompiler,
        orbit_idx: u16,
        output_channel: u16,
        is_cyclic: bool,
        continue_channel: ?u16,
        input_channels: []const u16,
        capture_channels: []const u16,
    ) !void {
        const a = self.arena.allocator();
        // 固化轨道 lamina 序列（直接写入对应索引，避免嵌套轨道 LIFO 顺序错乱）
        const olams = try a.dupe(Lamina, self.laminas.items);
        self.orbit_laminas_list.items[orbit_idx] = olams;
        // 填充轨道构建信息
        self.orbit_build_infos.items[orbit_idx] = .{
            .output_channel = output_channel,
            .is_cyclic = is_cyclic,
            .continue_channel = continue_channel,
            .capture_channels = try a.dupe(u16, capture_channels),
            .input_channels = try a.dupe(u16, input_channels),
        };
        // 恢复父层 laminas
        self.laminas = self.saved_laminas_stack.pop().?;
        self.in_orbit = self.saved_laminas_stack.items.len > 0;
    }

    /// 创建 OrbitHub 并返回其索引
    fn createOrbitHub(self: *LaminarCompiler, hub: OrbitHub) !u16 {
        const idx: u16 = @intCast(self.orbit_hubs_list.items.len);
        try self.orbit_hubs_list.append(self.arena.allocator(), hub);
        return idx;
    }

    // ── 函数编译 ──

    fn compileFunction(self: *LaminarCompiler, f: anytype) !void {
        try self.pushScope();
        defer self.popScope();

        // 为参数分配通道（main 通常无参数）
        for (f.params) |param| {
            const chan_type = mapTypeNode(param.type_annotation) orelse .i64_chan;
            const chan = try self.allocChannel(chan_type);
            // 如果是数组类型，设置 ref_kind=.array 用于方法分派
            if (chan_type == .ref_chan) {
                if (param.type_annotation) |tn| {
                    if (tn.* == .array) {
                        self.channel_metas.items[chan].ref_kind = .array;
                    }
                }
            }
            try self.defineVar(param.name, chan);
        }

        // 编译函数体
        const result_chan = try self.compileExpr(f.body);

        // 发射返回层
        try self.emit(.{
            .op = .halt_return,
            .inputs = .{ result_chan, 0, 0 },
            .output = result_chan,
            .input_count = 1,
        });
    }

    // ── 静态/动态判定（设计文档第 6.4 节）──
    // 核心规则：编译期完全确定执行路径 → 静态（太阳层）；否则 → 动态（轨道层）

    /// 判定表达式是否完全静态
    /// 静态 = 编译期可完全确定执行路径（无控制流分支、无动态分派、无副作用）
    pub fn isStatic(self: *LaminarCompiler, expr: *const ast.Expr) bool {
        return switch (expr.*) {
            // 字面量：静态
            .int_literal,
            .float_literal,
            .bool_literal,
            .char_literal,
            .string_literal,
            .null_literal,
            .unit_literal,
            => true,

            // 标识符引用：静态
            .identifier => true,

            // 二元/一元运算：操作数都静态则静态
            .binary => |b| self.isStatic(b.left) and self.isStatic(b.right),
            .unary => |u| self.isStatic(u.operand),

            // 字段访问：对象静态则静态
            .field_access => |fa| self.isStatic(fa.object),

            // 索引：对象和索引都静态则静态
            .index => |idx| self.isStatic(idx.object) and self.isStatic(idx.index),

            // 类型转换：内部表达式静态则静态
            .type_cast => |tc| self.isStatic(tc.expr),

            // 闭包构造本身：静态（不涉及调用）
            .lambda => true,
            // inline_trait_value 构造本身：静态
            .inline_trait_value => true,

            // 数组字面量：所有元素静态则静态
            .array_literal => |al| blk: {
                for (al.elements) |elem| {
                    if (!self.isStatic(elem)) break :blk false;
                }
                break :blk true;
            },

            // 记录字面量：所有字段值静态则静态
            .record_literal => |rl| blk: {
                for (rl.fields) |field| {
                    if (!self.isStatic(field.value)) break :blk false;
                }
                break :blk true;
            },

            // 块表达式：所有语句和尾表达式静态则静态
            .block => |blk_expr| self.isStaticBlock(blk_expr),

            // 函数调用：参数和函数体都静态则静态
            .call => |c| self.isStaticCall(c),

            // 动态构造（控制流 / 副作用 / 动态分派 / 延迟求值）
            .if_expr, // if-else 分支
            .match, // match 分派
            .select, // select 多路复用
            .propagate, // ? 错误传播
            .safe_access, // ?. 安全访问
            .safe_method_call, // ?. 方法调用
            .non_null_assert, // ! 非空断言
            .assignment_expr, // 赋值副作用
            .compound_assign, // 复合赋值副作用
            .record_extend, // 记录扩展（运行时合并）
            .string_interpolation, // 字符串插值（运行时构造）
            .atomic_expr, // atomic 包装（并发原语）
            .lazy, // 延迟求值
            .method_call, // 方法调用（可能动态分派）
            => false,
        };
    }

    /// 判定块表达式是否静态（所有语句 + 尾表达式都静态）
    fn isStaticBlock(self: *LaminarCompiler, blk: anytype) bool {
        for (blk.statements) |stmt| {
            if (!self.isStaticStmt(stmt)) return false;
        }
        if (blk.trailing_expr) |tail| {
            return self.isStatic(tail);
        }
        return true;
    }

    /// 判定语句是否静态
    fn isStaticStmt(self: *LaminarCompiler, stmt: *const ast.Stmt) bool {
        return switch (stmt.*) {
            // val 声明：值静态则静态
            .val_decl => |vd| self.isStatic(vd.value),
            // 表达式语句：表达式静态则静态
            .expression => |e| self.isStatic(e.expr),
            // 可变状态 / 控制流 / 循环：动态
            .var_decl, // var 涉及 Cell
            .assignment,
            .field_assignment,
            .compound_assignment,
            .return_stmt,
            .defer_stmt,
            .throw_stmt,
            .break_stmt,
            .continue_stmt,
            .for_stmt,
            .while_stmt,
            .loop_stmt,
            => false,
        };
    }

    /// 判定函数调用是否静态
    fn isStaticCall(self: *LaminarCompiler, c: anytype) bool {
        // callee 必须是标识符（直接函数名）才可能静态
        if (c.callee.* != .identifier) return false;
        const fn_name = c.callee.identifier.name;

        // IO 函数：动态（副作用）
        if (std.mem.eql(u8, fn_name, "println") or std.mem.eql(u8, fn_name, "print")) {
            return false;
        }

        // async 函数：动态
        if (self.async_func_map.get(fn_name) != null) {
            return false;
        }

        // 构造函数（atomic/channel）：参数都静态则静态
        if (std.mem.eql(u8, fn_name, "atomic") or std.mem.eql(u8, fn_name, "channel")) {
            for (c.arguments) |arg| {
                if (!self.isStatic(arg)) return false;
            }
            return true;
        }

        // 已知 Glue 函数：参数和函数体都静态则静态
        if (self.func_table.get(fn_name)) |func_decl| {
            for (c.arguments) |arg| {
                if (!self.isStatic(arg)) return false;
            }
            return self.isStaticBody(func_decl);
        }

        // 未知函数调用：动态
        return false;
    }

    /// 判定函数体是否完全静态
    /// 递归深度超限（≥3）视为动态，避免递归函数无限判定
    pub fn isStaticBody(self: *LaminarCompiler, decl: *const ast.Decl) bool {
        if (self.isstatic_depth >= 3) return false;

        const func_decl = switch (decl.*) {
            .fun_decl => |*f| f,
            else => return false,
        };

        self.isstatic_depth += 1;
        defer self.isstatic_depth -= 1;

        return self.isStatic(func_decl.body);
    }

    // ── 表达式编译 ──

    fn compileExpr(self: *LaminarCompiler, expr: *const ast.Expr) CompileError!u16 {
        return switch (expr.*) {
            .int_literal => |lit| blk: {
                const int_val = std.fmt.parseInt(i64, lit.raw, 10) catch 0;
                const kind: IntKind = if (lit.suffix) |sfx|
                    parseIntKindFromSuffix(sfx) orelse .i64
                else
                    .i64;
                const chan_type = lamina_mod.chanTypeFromIntKind(kind);
                const chan = try self.allocChannel(chan_type);
                try self.emit(.{
                    .op = .constant,
                    .inputs = .{ chan, 0, 0 },
                    .output = chan,
                    .const_val = int_val,
                    .int_kind = kind,
                    .input_count = 0,
                });
                break :blk chan;
            },

            .float_literal => |lit| blk: {
                const float_val = std.fmt.parseFloat(f64, lit.raw) catch 0;
                const kind: FloatKind = if (lit.suffix) |sfx|
                    parseFloatKindFromSuffix(sfx) orelse .f64
                else
                    .f64;
                const chan_type = lamina_mod.chanTypeFromFloatKind(kind);
                const chan = try self.allocChannel(chan_type);
                const bits: i64 = @bitCast(float_val);
                try self.emit(.{
                    .op = .constant,
                    .inputs = .{ chan, 0, 0 },
                    .output = chan,
                    .const_val = bits,
                    .float_kind = kind,
                    .input_count = 0,
                });
                break :blk chan;
            },

            .bool_literal => |b| blk: {
                const chan = try self.allocChannel(.bool_chan);
                try self.emit(.{
                    .op = .constant,
                    .inputs = .{ chan, 0, 0 },
                    .output = chan,
                    .const_val = if (b.value) 1 else 0,
                    .input_count = 0,
                });
                break :blk chan;
            },

            .char_literal => |c| blk: {
                const chan = try self.allocChannel(.char_chan);
                try self.emit(.{
                    .op = .constant,
                    .inputs = .{ chan, 0, 0 },
                    .output = chan,
                    .const_val = @intCast(c.value),
                    .input_count = 0,
                });
                break :blk chan;
            },

            .null_literal => blk: {
                const chan = try self.allocChannel(.null_chan);
                try self.emit(.{
                    .op = .constant,
                    .inputs = .{ chan, 0, 0 },
                    .output = chan,
                    .input_count = 0,
                });
                break :blk chan;
            },
            .unit_literal => blk: {
                const chan = try self.allocChannel(.unit_chan);
                try self.emit(.{
                    .op = .constant,
                    .inputs = .{ chan, 0, 0 },
                    .output = chan,
                    .input_count = 0,
                });
                break :blk chan;
            },

            .string_literal => |s| blk: {
                const chan = try self.allocChannel(.ref_chan);
                const str_idx = try self.internString(s.value);
                try self.emit(.{
                    .op = .str_const,
                    .inputs = .{ chan, 0, 0 },
                    .output = chan,
                    .name_idx = str_idx,
                    .ref_kind = .str,
                    .input_count = 0,
                });
                break :blk chan;
            },

            .identifier => |id| blk: {
                if (self.lookupVar(id.name)) |chan| {
                    const meta = self.channel_metas.items[chan];
                    if (meta.is_cell) {
                        // Cell 变量 — 发射 cell_get 读取内部值（自动解引用）
                        // 输出通道类型 = cell 内部值类型（inner_type）
                        const out_chan = try self.allocChannel(meta.inner_type);
                        try self.emit(.{
                            .op = .cell_get,
                            .inputs = .{ chan, 0, 0 },
                            .output = out_chan,
                            .ref_kind = .cell,
                            .input_count = 1,
                        });
                        // 继承 cell 的 ref_kind（如数组变量读取后仍为 .array）
                        self.channel_metas.items[out_chan].ref_kind = meta.ref_kind;
                        break :blk out_chan;
                    }
                    break :blk chan;
                }
                break :blk try self.allocChannel(.unit_chan);
            },

            .binary => |b| try self.compileBinary(b),

            .unary => |u| try self.compileUnary(u),

            .if_expr => |iff| try self.compileIf(iff),

            .block => |blk_expr| try self.compileBlock(blk_expr),

            .call => |c| try self.compileCall(c),

            .method_call => |mc| try self.compileMethodCall(mc),

            .assignment_expr => |assign| try self.compileAssignment(assign),

            .propagate => |prop| blk: {
                // E3: ? 传播 → OrbitHub(error_hub)
                const a = self.arena.allocator();
                const throw_chan = try self.compileExpr(prop.expr);

                // 发射 throw_is_ok 检查条件
                const is_ok_chan = try self.allocChannel(.bool_chan);
                try self.emit(.{
                    .op = .throw_is_ok,
                    .inputs = .{ throw_chan, 0, 0 },
                    .output = is_ok_chan,
                    .ref_kind = .throw_val,
                    .input_count = 1,
                });

                // 预分配共享的 bridge_in 通道（两个轨道共用）
                const shared_input = try self.allocBridgeInChannel(.ref_chan);

                // 创建 ok 轨道：throw_get_ok → output
                const ok_orbit = try self.beginOrbit();
                const ok_output = try self.allocBridgeOutChannel(.i64_chan);
                try self.emit(.{
                    .op = .throw_get_ok,
                    .inputs = .{ shared_input, 0, 0 },
                    .output = ok_output,
                    .ref_kind = .throw_val,
                    .input_count = 1,
                });
                try self.endOrbit(ok_orbit, ok_output, false, null);

                // 创建 err 轨道：halt_throw（传播异常）
                const err_orbit = try self.beginOrbit();
                const err_output = try self.allocBridgeOutChannel(.ref_chan);
                try self.emit(.{
                    .op = .halt_throw,
                    .inputs = .{ shared_input, 0, 0 },
                    .output = err_output,
                    .ref_kind = .error_val,
                    .input_count = 1,
                });
                try self.endOrbit(err_orbit, err_output, false, null);

                // 分配太阳层输出通道
                const out_chan = try self.allocChannel(.i64_chan);

                // 创建 OrbitHub(error_hub)
                const orbit_table = try a.alloc(OrbitEntry, 2);
                orbit_table[0] = .{ .cond_channel = is_ok_chan, .cond_kind = .eq, .expected_val = 1, .orbit_index = ok_orbit };
                orbit_table[1] = .{ .cond_channel = is_ok_chan, .cond_kind = .eq, .expected_val = 0, .orbit_index = err_orbit };

                const param_mapping = try a.alloc(ParamBind, 1);
                param_mapping[0] = .{ .src = throw_chan, .dst = shared_input };

                const hub_idx = try self.createOrbitHub(.{
                    .kind = .error_hub,
                    .cond_channel = is_ok_chan,
                    .orbit_table = orbit_table,
                    .output_channel = out_chan,
                    .param_mapping = param_mapping,
                });

                try self.emit(.{
                    .op = .orbit_hub,
                    .hub_index = hub_idx,
                    .output = out_chan,
                    .input_count = 0,
                });

                break :blk out_chan;
            },

            // E2: lambda → 编译为轨道 + closure_make（带自由变量捕获）
            .lambda => |lam| try self.compileLambda(lam),

            // E2: inline_trait_value → 编译方法为轨道 + trait_make
            .inline_trait_value => |itv| try self.compileInlineTraitValue(itv),

            // 阶段 5: match → switch_lamina（简化：单 arm 分派）
            .match => |m| try self.compileMatch(m),

            // 类型转换：type_cast(expr, target_type) → type_cast / type_cast_safe lamina
            .type_cast => |tc| blk: {
                const src_chan = try self.compileExpr(tc.expr);
                const dst_chan_type = mapTypeNode(tc.target_type) orelse {
                    // 未知目标类型，退化为 unit
                    break :blk try self.allocChannel(.unit_chan);
                };
                const dst_tag = lamina_mod.chanTypeToScalarTag(dst_chan_type) orelse {
                    // null/unit/mask/ref 无标量转换
                    break :blk try self.allocChannel(dst_chan_type);
                };
                const dst_chan = try self.allocChannel(dst_chan_type);
                if (tc.safe) {
                    // 安全转换：i32(x)? → tryCast，越界抛出错误，成功输出 target_type 标量
                    try self.emit(.{
                        .op = .type_cast_safe,
                        .inputs = .{ src_chan, 0, 0 },
                        .output = dst_chan,
                        .const_val = @intFromEnum(dst_tag),
                        .input_count = 1,
                    });
                } else {
                    // 不安全转换：i32(x) → wrap/饱和
                    try self.emit(.{
                        .op = .type_cast,
                        .inputs = .{ src_chan, 0, 0 },
                        .output = dst_chan,
                        .const_val = @intFromEnum(dst_tag),
                        .input_count = 1,
                    });
                }
                break :blk dst_chan;
            },

            // E3: ! 非空断言 → OrbitHub(nullable_hub)
            .non_null_assert => |nn| blk: {
                const a = self.arena.allocator();
                const nullable_chan = try self.compileExpr(nn.expr);

                // 发射 nullable_is_null 检查条件
                const is_null_chan = try self.allocChannel(.bool_chan);
                try self.emit(.{
                    .op = .nullable_is_null,
                    .inputs = .{ nullable_chan, 0, 0 },
                    .output = is_null_chan,
                    .input_count = 1,
                });

                // 预分配共享的 bridge_in 通道
                const shared_input = try self.allocBridgeInChannel(.nullable_chan);

                // 创建 ok 轨道（非空）：nullable_unwrap → output
                const ok_orbit = try self.beginOrbit();
                const ok_output = try self.allocBridgeOutChannel(.i64_chan);
                try self.emit(.{
                    .op = .nullable_unwrap,
                    .inputs = .{ shared_input, 0, 0 },
                    .output = ok_output,
                    .input_count = 1,
                });
                try self.endOrbit(ok_orbit, ok_output, false, null);

                // 创建 err 轨道（空）：halt_throw（panic）
                const err_orbit = try self.beginOrbit();
                const err_output = try self.allocBridgeOutChannel(.ref_chan);
                try self.emit(.{
                    .op = .halt_throw,
                    .inputs = .{ 0, 0, 0 },
                    .output = err_output,
                    .ref_kind = .error_val,
                    .input_count = 0,
                });
                try self.endOrbit(err_orbit, err_output, false, null);

                // 分配太阳层输出通道
                const out_chan = try self.allocChannel(.i64_chan);

                // 创建 OrbitHub(nullable_hub)
                const orbit_table = try a.alloc(OrbitEntry, 2);
                orbit_table[0] = .{ .cond_channel = is_null_chan, .cond_kind = .eq, .expected_val = 0, .orbit_index = ok_orbit };
                orbit_table[1] = .{ .cond_channel = is_null_chan, .cond_kind = .eq, .expected_val = 1, .orbit_index = err_orbit };

                const param_mapping = try a.alloc(ParamBind, 1);
                param_mapping[0] = .{ .src = nullable_chan, .dst = shared_input };

                const hub_idx = try self.createOrbitHub(.{
                    .kind = .nullable_hub,
                    .cond_channel = is_null_chan,
                    .orbit_table = orbit_table,
                    .output_channel = out_chan,
                    .param_mapping = param_mapping,
                });

                try self.emit(.{
                    .op = .orbit_hub,
                    .hub_index = hub_idx,
                    .output = out_chan,
                    .input_count = 0,
                });

                break :blk out_chan;
            },

            // E3: ?. 安全访问 → OrbitHub(nullable_hub)
            .safe_access => |sa| blk: {
                const a = self.arena.allocator();
                const nullable_chan = try self.compileExpr(sa.object);

                // 发射 nullable_is_null 检查条件
                const is_null_chan = try self.allocChannel(.bool_chan);
                try self.emit(.{
                    .op = .nullable_is_null,
                    .inputs = .{ nullable_chan, 0, 0 },
                    .output = is_null_chan,
                    .input_count = 1,
                });

                // 预分配共享的 bridge_in 通道
                const shared_input = try self.allocBridgeInChannel(.nullable_chan);

                // 创建 ok 轨道（非空）：nullable_unwrap → record_get(field) → output
                const ok_orbit = try self.beginOrbit();
                const unwrapped_chan = try self.allocChannel(.i64_chan);
                const ok_output = try self.allocBridgeOutChannel(.i64_chan);
                try self.emit(.{
                    .op = .nullable_unwrap,
                    .inputs = .{ shared_input, 0, 0 },
                    .output = unwrapped_chan,
                    .input_count = 1,
                });
                const field_name_id = try self.internName(sa.field);
                try self.emit(.{
                    .op = .record_get,
                    .inputs = .{ unwrapped_chan, 0, 0 },
                    .output = ok_output,
                    .name_idx = field_name_id,
                    .input_count = 1,
                });
                try self.endOrbit(ok_orbit, ok_output, false, null);

                // 创建 null 轨道（空）：返回默认值 0
                const null_orbit = try self.beginOrbit();
                const null_output = try self.allocBridgeOutChannel(.i64_chan);
                try self.emit(.{
                    .op = .constant,
                    .inputs = .{ 0, 0, 0 },
                    .output = null_output,
                    .const_val = 0,
                    .input_count = 0,
                });
                try self.endOrbit(null_orbit, null_output, false, null);

                // 分配太阳层输出通道
                const out_chan = try self.allocChannel(.i64_chan);

                // 创建 OrbitHub(nullable_hub)
                const orbit_table = try a.alloc(OrbitEntry, 2);
                orbit_table[0] = .{ .cond_channel = is_null_chan, .cond_kind = .eq, .expected_val = 0, .orbit_index = ok_orbit };
                orbit_table[1] = .{ .cond_channel = is_null_chan, .cond_kind = .eq, .expected_val = 1, .orbit_index = null_orbit };

                const param_mapping = try a.alloc(ParamBind, 1);
                param_mapping[0] = .{ .src = nullable_chan, .dst = shared_input };

                const hub_idx = try self.createOrbitHub(.{
                    .kind = .nullable_hub,
                    .cond_channel = is_null_chan,
                    .orbit_table = orbit_table,
                    .output_channel = out_chan,
                    .param_mapping = param_mapping,
                });

                try self.emit(.{
                    .op = .orbit_hub,
                    .hub_index = hub_idx,
                    .output = out_chan,
                    .input_count = 0,
                });

                break :blk out_chan;
            },

            // E5: select 多路复用 → 循环轨道 + select_hub
            .select => |sel| blk: {
                const a = self.arena.allocator();

                // 1. 为每个 arm 创建处理轨道
                const arm_count = sel.arms.len;
                const arm_orbits = try a.alloc(u16, arm_count);
                const arm_ready_chans = try a.alloc(u16, arm_count);
                const arm_recv_chans = try a.alloc(u16, arm_count); // 接收到的值通道

                for (sel.arms, 0..) |arm, i| {
                    switch (arm) {
                        .receive => |r| {
                            // 编译通道表达式（在太阳层）
                            const chan_chan = try self.compileExpr(r.channel_expr);

                            // 创建处理轨道
                            arm_orbits[i] = try self.beginOrbit();
                            try self.pushScope();

                            // 绑定接收到的消息（通过 bridge_in 通道）
                            const msg_chan = try self.allocBridgeInChannel(.i64_chan);
                            arm_recv_chans[i] = msg_chan;
                            if (r.binding) |name| {
                                try self.defineVar(name, msg_chan);
                            }

                            const body_result = try self.compileExpr(r.body);
                            const arm_output = try self.allocBridgeOutChannel(.i64_chan);
                            try self.emit(.{
                                .op = .move,
                                .inputs = .{ body_result, 0, 0 },
                                .output = arm_output,
                                .input_count = 1,
                            });
                            // halt_break 退出循环轨道
                            try self.emit(.{
                                .op = .halt_break,
                                .inputs = .{ 0, 0, 0 },
                                .output = 0,
                                .input_count = 0,
                            });
                            self.popScope();
                            try self.endOrbit(arm_orbits[i], arm_output, false, null);

                            // 在太阳层发射 try_recv 获取就绪标志
                            const try_recv_chan = try self.allocChannel(.i64_chan);
                            try self.emit(.{
                                .op = .channel_try_recv,
                                .inputs = .{ chan_chan, 0, 0 },
                                .output = try_recv_chan,
                                .input_count = 1,
                            });
                            arm_ready_chans[i] = try_recv_chan;
                            arm_recv_chans[i] = try_recv_chan; // try_recv 输出包含值 + ready 标志
                        },
                        .timeout => |t| {
                            // timeout arm：简化处理，直接编译 body
                            arm_orbits[i] = try self.beginOrbit();
                            try self.pushScope();
                            const body_result = try self.compileExpr(t.body);
                            const arm_output = try self.allocBridgeOutChannel(.i64_chan);
                            try self.emit(.{
                                .op = .move,
                                .inputs = .{ body_result, 0, 0 },
                                .output = arm_output,
                                .input_count = 1,
                            });
                            try self.emit(.{
                                .op = .halt_break,
                                .inputs = .{ 0, 0, 0 },
                                .output = 0,
                                .input_count = 0,
                            });
                            self.popScope();
                            try self.endOrbit(arm_orbits[i], arm_output, false, null);

                            // timeout 暂时不检查（简化），ready 标志设为常量 0
                            const ready_chan = try self.allocChannel(.bool_chan);
                            try self.emit(.{
                                .op = .constant,
                                .inputs = .{ 0, 0, 0 },
                                .output = ready_chan,
                                .const_val = 0,
                                .input_count = 0,
                            });
                            arm_ready_chans[i] = ready_chan;
                            arm_recv_chans[i] = ready_chan;
                        },
                    }
                }

                // 2. 创建"继续等待"轨道（都未就绪时继续循环）
                const continue_orbit = try self.beginOrbit();
                const continue_output = try self.allocBridgeOutChannel(.i64_chan);
                try self.emit(.{
                    .op = .halt_continue,
                    .inputs = .{ 0, 0, 0 },
                    .output = 0,
                    .input_count = 0,
                });
                try self.endOrbit(continue_orbit, continue_output, false, null);

                // 3. 分配太阳层输出通道
                const out_chan = try self.allocChannel(.i64_chan);

                // 4. 创建 OrbitHub(select_hub)
                // orbit_table: 每个 arm 一个条目（cond: ready==1），最后是 always（继续循环）
                const orbit_table = try a.alloc(OrbitEntry, arm_count + 1);
                for (0..arm_count) |i| {
                    orbit_table[i] = .{
                        .cond_channel = arm_ready_chans[i],
                        .cond_kind = .eq,
                        .expected_val = 1,
                        .orbit_index = arm_orbits[i],
                    };
                }
                orbit_table[arm_count] = .{
                    .cond_kind = .always,
                    .orbit_index = continue_orbit,
                };

                // param_mapping: 每个 arm 的接收值通道 → 轨道入口通道
                // 简化：所有 arm 共享同一组 param_mapping
                // 注：当前实现中，try_recv 的输出通道包含值和 ready 标志
                // arm 处理轨道通过 bridge_in 通道接收消息
                const hub_idx = try self.createOrbitHub(.{
                    .kind = .select_hub,
                    .cond_channel = null, // 使用每个 entry 的 cond_channel
                    .orbit_table = orbit_table,
                    .output_channel = out_chan,
                });

                // 5. 发射 orbit_hub lamina（同步执行 select_hub）
                try self.emit(.{
                    .op = .orbit_hub,
                    .hub_index = hub_idx,
                    .output = out_chan,
                    .input_count = 0,
                });

                break :blk out_chan;
            },

            // 数组索引：a[i] → array_get
            .index => |idx| blk: {
                const obj_chan = try self.compileExpr(idx.object);
                const idx_chan = try self.compileExpr(idx.index);
                const out_chan = try self.allocChannel(.i64_chan);
                try self.emit(.{
                    .op = .array_get,
                    .inputs = .{ obj_chan, idx_chan, 0 },
                    .output = out_chan,
                    .ref_kind = .array,
                    .input_count = 2,
                });
                break :blk out_chan;
            },

            // 数组字面量：[a, b, c] → array_make + N 次 array_push
            .array_literal => |al| blk: {
                // 分配数组通道（ref_chan, ref_kind=array）
                const arr_chan = try self.allocChannel(.ref_chan);
                const elem_count: i64 = @intCast(al.elements.len);
                try self.emit(.{
                    .op = .array_make,
                    .inputs = .{ 0, 0, 0 },
                    .output = arr_chan,
                    .const_val = elem_count,
                    .ref_kind = .array,
                    .input_count = 0,
                });
                // 逐个 push 元素
                for (al.elements) |elem| {
                    const elem_chan = try self.compileExpr(elem);
                    try self.emit(.{
                        .op = .array_push,
                        .inputs = .{ arr_chan, elem_chan, 0 },
                        .output = arr_chan,
                        .ref_kind = .array,
                        .input_count = 2,
                    });
                }
                break :blk arr_chan;
            },

            else => try self.allocChannel(.unit_chan),
        };
    }

    // ── 二元运算编译 ──

    fn compileBinary(self: *LaminarCompiler, b: anytype) CompileError!u16 {
        const lhs_chan = try self.compileExpr(b.left);
        const rhs_chan = try self.compileExpr(b.right);

        // 从左操作数的通道类型推断运算类型
        const lhs_meta = self.channel_metas.items[lhs_chan];
        const lhs_type = lhs_meta.chan_type;

        switch (lhs_type) {
            .i8_chan, .i16_chan, .i32_chan, .i64_chan, .i128_chan,
            .u8_chan, .u16_chan, .u32_chan, .u64_chan, .u128_chan,
            => |ct| {
                const kind = intKindFromChanType(ct);
                return try self.compileIntBinary(b.op, lhs_chan, rhs_chan, kind);
            },
            .f16_chan, .f32_chan, .f64_chan, .f128_chan => |ct| {
                const kind = floatKindFromChanType(ct);
                return try self.compileFloatBinary(b.op, lhs_chan, rhs_chan, kind);
            },
            .bool_chan, .mask_chan => return try self.compileBoolBinary(b.op, lhs_chan, rhs_chan),
            .char_chan => return try self.compileCharBinary(b.op, lhs_chan, rhs_chan),
            else => return try self.compileIntBinary(b.op, lhs_chan, rhs_chan, .i64),
        }
    }

    /// 将 CompoundAssignOp 映射到对应的二元运算并编译
    fn compileCompoundOp(
        self: *LaminarCompiler,
        op: ast.CompoundAssignOp,
        lhs: u16,
        rhs: u16,
    ) CompileError!u16 {
        const bin_op: ast.BinaryOp = switch (op) {
            .add_assign => .add,
            .sub_assign => .sub,
            .mul_assign => .mul,
            .div_assign => .div,
            .mod_assign => .mod,
            .bit_and_assign => .bit_and,
            .bit_or_assign => .bit_or,
            .bit_xor_assign => .bit_xor,
            .shl_assign => .shl,
            .shr_assign => .shr,
        };
        const lhs_meta = self.channel_metas.items[lhs];
        switch (lhs_meta.chan_type) {
            .f16_chan, .f32_chan, .f64_chan, .f128_chan => {
                return try self.compileFloatBinary(bin_op, lhs, rhs, floatKindFromChanType(lhs_meta.chan_type));
            },
            .char_chan => return try self.compileCharBinary(bin_op, lhs, rhs),
            else => return try self.compileIntBinary(bin_op, lhs, rhs, .i64),
        }
    }

    fn compileIntBinary(
        self: *LaminarCompiler,
        op: ast.BinaryOp,
        lhs: u16,
        rhs: u16,
        kind: IntKind,
    ) CompileError!u16 {
        const is_comparison = switch (op) {
            .lt, .gt, .eq, .not_eq, .lt_eq, .gt_eq => true,
            else => false,
        };

        const out_type: ScalarChanType = if (is_comparison) .mask_chan else lamina_mod.chanTypeFromIntKind(kind);
        const out_chan = try self.allocChannel(out_type);

        const lamina_op: LaminaOp = switch (op) {
            .add => .int_add,
            .sub => .int_sub,
            .mul => .int_mul,
            .div => .int_div,
            .mod => .int_mod,
            .bit_and => .int_and,
            .bit_or => .int_or,
            .bit_xor => .int_xor,
            .shl => .int_shl,
            .shr => .int_shr,
            .lt => .int_lt,
            .gt => .int_gt,
            .eq => .int_eq,
            .not_eq => .int_ne,
            .lt_eq => .int_le,
            .gt_eq => .int_ge,
            else => return error.UnsupportedExpr,
        };

        try self.emit(.{
            .op = lamina_op,
            .inputs = .{ lhs, rhs, 0 },
            .output = out_chan,
            .int_kind = kind,
            .input_count = 2,
        });
        return out_chan;
    }

    fn compileFloatBinary(
        self: *LaminarCompiler,
        op: ast.BinaryOp,
        lhs: u16,
        rhs: u16,
        kind: FloatKind,
    ) CompileError!u16 {
        const is_comparison = switch (op) {
            .lt, .gt, .eq, .not_eq, .lt_eq, .gt_eq => true,
            else => false,
        };

        const out_type: ScalarChanType = if (is_comparison) .mask_chan else lamina_mod.chanTypeFromFloatKind(kind);
        const out_chan = try self.allocChannel(out_type);

        const lamina_op: LaminaOp = switch (op) {
            .add => .float_add,
            .sub => .float_sub,
            .mul => .float_mul,
            .div => .float_div,
            .lt => .float_lt,
            .gt => .float_gt,
            .eq => .float_eq,
            .not_eq => .float_ne,
            .lt_eq => .float_le,
            .gt_eq => .float_ge,
            else => return error.UnsupportedExpr,
        };

        try self.emit(.{
            .op = lamina_op,
            .inputs = .{ lhs, rhs, 0 },
            .output = out_chan,
            .float_kind = kind,
            .input_count = 2,
        });
        return out_chan;
    }

    fn compileBoolBinary(
        self: *LaminarCompiler,
        op: ast.BinaryOp,
        lhs: u16,
        rhs: u16,
    ) CompileError!u16 {
        const is_comparison = switch (op) {
            .eq, .not_eq => true,
            else => false,
        };

        const out_chan = try self.allocChannel(if (is_comparison) .mask_chan else .bool_chan);

        const lamina_op: LaminaOp = switch (op) {
            .and_op => .bool_and,
            .or_op => .bool_or,
            .eq => .bool_eq,
            .not_eq => .bool_ne,
            else => return error.UnsupportedExpr,
        };

        try self.emit(.{
            .op = lamina_op,
            .inputs = .{ lhs, rhs, 0 },
            .output = out_chan,
            .input_count = 2,
        });
        return out_chan;
    }

    fn compileCharBinary(
        self: *LaminarCompiler,
        op: ast.BinaryOp,
        lhs: u16,
        rhs: u16,
    ) CompileError!u16 {
        const out_chan = try self.allocChannel(.mask_chan);

        const lamina_op: LaminaOp = switch (op) {
            .lt => .char_lt,
            .gt => .char_gt,
            .eq => .char_eq,
            .not_eq => .char_ne,
            .lt_eq => .char_le,
            .gt_eq => .char_ge,
            else => return error.UnsupportedExpr,
        };

        try self.emit(.{
            .op = lamina_op,
            .inputs = .{ lhs, rhs, 0 },
            .output = out_chan,
            .input_count = 2,
        });
        return out_chan;
    }

    // ── 一元运算编译 ──

    fn compileUnary(self: *LaminarCompiler, u: anytype) CompileError!u16 {
        const operand_chan = try self.compileExpr(u.operand);
        const operand_type = self.channel_metas.items[operand_chan].chan_type;

        switch (operand_type) {
            .i8_chan, .i16_chan, .i32_chan, .i64_chan, .i128_chan,
            .u8_chan, .u16_chan, .u32_chan, .u64_chan, .u128_chan,
            => |ct| {
                const kind = intKindFromChanType(ct);
                const out_chan = try self.allocChannel(ct);
                const op: LaminaOp = switch (u.op) {
                    .neg => .int_neg,
                    .not => .int_not,
                    .bit_not => .int_not,
                };
                try self.emit(.{
                    .op = op,
                    .inputs = .{ operand_chan, 0, 0 },
                    .output = out_chan,
                    .int_kind = kind,
                    .input_count = 1,
                });
                return out_chan;
            },
            .f16_chan, .f32_chan, .f64_chan, .f128_chan => |ct| {
                const kind = floatKindFromChanType(ct);
                const out_chan = try self.allocChannel(ct);
                const op: LaminaOp = switch (u.op) {
                    .neg => .float_neg,
                    .not, .bit_not => return error.UnsupportedExpr,
                };
                try self.emit(.{
                    .op = op,
                    .inputs = .{ operand_chan, 0, 0 },
                    .output = out_chan,
                    .float_kind = kind,
                    .input_count = 1,
                });
                return out_chan;
            },
            .bool_chan => {
                if (u.op == .bit_not) return error.UnsupportedExpr;
                const out_chan = try self.allocChannel(.bool_chan);
                try self.emit(.{
                    .op = .bool_not,
                    .inputs = .{ operand_chan, 0, 0 },
                    .output = out_chan,
                    .input_count = 1,
                });
                return out_chan;
            },
            else => return error.UnsupportedExpr,
        }
    }

    // ── 条件表达式编译（if → select 谓词化）──

    fn compileIf(self: *LaminarCompiler, iff: anytype) CompileError!u16 {
        // 1. 在太阳层编译条件表达式
        const cond_chan = try self.compileExpr(iff.condition);

        // 2. 创建 then 轨道
        const then_orbit = try self.beginOrbit();
        try self.pushScope();
        const then_result = try self.compileExpr(iff.then_branch);
        self.popScope();
        // 分配桥接出口通道（bridge_out，太阳层读取）
        const result_type = self.channel_metas.items[then_result].chan_type;
        const out_chan = try self.allocBridgeOutChannel(result_type);
        // 在轨道内发射 move：then_result → out_chan
        try self.emit(.{
            .op = .move,
            .inputs = .{ then_result, 0, 0 },
            .output = out_chan,
            .input_count = 1,
        });
        try self.endOrbit(then_orbit, out_chan, false, null);

        // 3. 创建 else 轨道
        const else_orbit = try self.beginOrbit();
        const else_result: u16 = if (iff.else_branch) |else_expr| blk: {
            try self.pushScope();
            const chan = try self.compileExpr(else_expr);
            self.popScope();
            break :blk chan;
        } else try self.allocChannel(.unit_chan);
        // 在轨道内发射 move：else_result → out_chan
        try self.emit(.{
            .op = .move,
            .inputs = .{ else_result, 0, 0 },
            .output = out_chan,
            .input_count = 1,
        });
        try self.endOrbit(else_orbit, out_chan, false, null);

        // 4. 创建 OrbitHub：条件值 1(true) → then 轨道，否则 → else 轨道
        const a = self.arena.allocator();
        const orbit_table = try a.alloc(OrbitEntry, 2);
        orbit_table[0] = .{ .cond_kind = .eq, .expected_val = 1, .orbit_index = then_orbit };
        orbit_table[1] = .{ .cond_kind = .always, .orbit_index = else_orbit };
        const hub_idx = try self.createOrbitHub(.{
            .kind = .if_hub,
            .cond_channel = cond_chan,
            .orbit_table = orbit_table,
            .output_channel = out_chan,
        });

        // 5. 在太阳层发射 orbit_hub lamina
        try self.emit(.{
            .op = .orbit_hub,
            .hub_index = hub_idx,
            .output = out_chan,
            .input_count = 0,
        });

        return out_chan;
    }

    // ── match 表达式编译（→ OrbitHub(match_hub) + arm 轨道）──

    fn compileMatch(self: *LaminarCompiler, m: anytype) CompileError!u16 {
        const a = self.arena.allocator();

        // 1. 在太阳层编译 scrutinee
        const scrutinee_chan = try self.compileExpr(m.scrutinee);

        // 2. 为每个 arm 创建轨道
        const n_arms = m.arms.len;
        if (n_arms == 0) return try self.allocChannel(.unit_chan);

        const orbit_indices = try a.alloc(u16, n_arms);
        var out_chan: u16 = 0;

        for (m.arms, 0..) |arm, i| {
            const orbit_idx = try self.beginOrbit();
            orbit_indices[i] = orbit_idx;

            try self.pushScope();
            // variable 模式绑定 scrutinee 到变量名
            if (arm.pattern.* == .variable) {
                try self.defineVar(arm.pattern.variable.name, scrutinee_chan);
            }
            const arm_result = try self.compileExpr(arm.body);
            self.popScope();

            // 第一个 arm 确定输出通道类型，分配桥接出口通道
            if (i == 0) {
                const result_type = self.channel_metas.items[arm_result].chan_type;
                out_chan = try self.allocBridgeOutChannel(result_type);
            }
            // 在轨道内发射 move：arm_result → out_chan
            try self.emit(.{
                .op = .move,
                .inputs = .{ arm_result, 0, 0 },
                .output = out_chan,
                .input_count = 1,
            });
            try self.endOrbit(orbit_idx, out_chan, false, null);
        }

        // 3. 构建 orbit_table：根据模式确定匹配条件
        const orbit_table = try a.alloc(OrbitEntry, n_arms);
        for (m.arms, 0..) |arm, i| {
            orbit_table[i] = try self.patternToOrbitEntry(arm.pattern, orbit_indices[i]);
        }

        // 4. 创建 OrbitHub
        const hub_idx = try self.createOrbitHub(.{
            .kind = .match_hub,
            .cond_channel = scrutinee_chan,
            .orbit_table = orbit_table,
            .output_channel = out_chan,
        });

        // 5. 在太阳层发射 orbit_hub lamina
        try self.emit(.{
            .op = .orbit_hub,
            .hub_index = hub_idx,
            .output = out_chan,
            .input_count = 0,
        });

        return out_chan;
    }

    /// 将模式转换为 OrbitEntry（条件 → 轨道索引映射）
    fn patternToOrbitEntry(self: *LaminarCompiler, pattern: *const ast.Pattern, orbit_index: u16) !OrbitEntry {
        return switch (pattern.*) {
            .wildcard => .{ .cond_kind = .always, .orbit_index = orbit_index },
            .variable => .{ .cond_kind = .always, .orbit_index = orbit_index },
            .literal => |lit| switch (lit) {
                .int => |s| .{
                    .cond_kind = .eq,
                    .expected_val = std.fmt.parseInt(i64, s, 10) catch 0,
                    .orbit_index = orbit_index,
                },
                .bool => |b| .{
                    .cond_kind = .eq,
                    .expected_val = if (b) 1 else 0,
                    .orbit_index = orbit_index,
                },
                .char => |c| .{
                    .cond_kind = .eq,
                    .expected_val = @intCast(c),
                    .orbit_index = orbit_index,
                },
                .null => .{
                    .cond_kind = .eq,
                    .expected_val = 0,
                    .orbit_index = orbit_index,
                },
                else => .{ .cond_kind = .always, .orbit_index = orbit_index },
            },
            // 构造器模式：用名称索引作为 tag（简化）
            .constructor => |c| blk: {
                const name_idx = try self.internString(c.name);
                break :blk .{
                    .cond_kind = .eq,
                    .expected_val = @as(i64, name_idx),
                    .orbit_index = orbit_index,
                };
            },
            // or_pattern / guard / record：简化为 always（需后续完善）
            else => .{ .cond_kind = .always, .orbit_index = orbit_index },
        };
    }

    // ── 块表达式编译 ──

    fn compileBlock(self: *LaminarCompiler, blk: anytype) CompileError!u16 {
        try self.pushScope();
        defer self.popScope();

        for (blk.statements) |stmt| {
            _ = try self.compileStmt(stmt);
        }

        if (blk.trailing_expr) |tail| {
            return try self.compileExpr(tail);
        }
        return try self.allocChannel(.unit_chan);
    }

    // ── 语句编译 ──

    fn compileStmt(self: *LaminarCompiler, stmt: *const ast.Stmt) CompileError!u16 {
        return switch (stmt.*) {
            .val_decl => |vd| blk: {
                const val_chan = try self.compileExpr(vd.value);
                try self.defineVar(vd.name, val_chan);
                break :blk val_chan;
            },
            .var_decl => |vd| blk: {
                const val_chan = try self.compileExpr(vd.value);
                // var 变量用 Cell 包装，支持后续赋值
                const val_meta = self.channel_metas.items[val_chan];
                const cell_chan = try self.allocChannel(.ref_chan);
                self.channel_metas.items[cell_chan].is_cell = true;
                self.channel_metas.items[cell_chan].inner_type = val_meta.chan_type;
                try self.emit(.{
                    .op = .cell_make,
                    .inputs = .{ val_chan, 0, 0 },
                    .output = cell_chan,
                    .ref_kind = .cell,
                    .input_count = 1,
                });
                // emit 会将 ref_kind 设为 .cell，但方法分派需要内部值的 ref_kind
                // （如数组变量需要 ref_kind=.array 才能查到 array 方法表）
                self.channel_metas.items[cell_chan].ref_kind = val_meta.ref_kind;
                try self.defineVar(vd.name, cell_chan);
                break :blk cell_chan;
            },
            .expression => |e| try self.compileExpr(e.expr),
            .return_stmt => |rs| blk: {
                const val_chan: u16 = if (rs.value) |v| try self.compileExpr(v) else try self.allocChannel(.unit_chan);
                if (self.current_return_channel) |ret_chan| {
                    // 函数调用轨道内：move 到返回通道 + halt_break 退出轨道
                    try self.emit(.{
                        .op = .move,
                        .inputs = .{ val_chan, 0, 0 },
                        .output = ret_chan,
                        .input_count = 1,
                    });
                    try self.emit(.{
                        .op = .halt_break,
                        .inputs = .{ 0, 0, 0 },
                        .output = 0,
                        .input_count = 0,
                    });
                } else {
                    // main 函数：halt_return
                    try self.emit(.{
                        .op = .halt_return,
                        .inputs = .{ val_chan, 0, 0 },
                        .output = val_chan,
                        .input_count = 1,
                    });
                }
                break :blk val_chan;
            },
            .assignment => |assign| blk: {
                const val_chan = try self.compileExpr(assign.value);
                if (assign.target.* == .identifier) {
                    // 查找变量 — 如果是 Cell（var_decl 创建的），发射 cell_set
                    if (self.lookupVar(assign.target.identifier.name)) |cell_chan| {
                        const meta = self.channel_metas.items[cell_chan];
                        if (meta.is_cell) {
                            try self.emit(.{
                                .op = .cell_set,
                                .inputs = .{ cell_chan, val_chan, 0 },
                                .output = cell_chan,
                                .input_count = 2,
                            });
                            break :blk val_chan;
                        }
                        // 非 Cell 变量 — 直接重绑定（val 语义）
                        try self.defineVar(assign.target.identifier.name, val_chan);
                    }
                }
                break :blk val_chan;
            },
            .compound_assignment => |ca| blk: {
                // 复合赋值：target op= value → target = target op value
                const target_chan = try self.compileExpr(ca.target);
                const val_chan = try self.compileExpr(ca.value);
                // 映射 CompoundAssignOp → 二元运算
                const result_chan = try self.compileCompoundOp(ca.op, target_chan, val_chan);
                if (ca.target.* == .identifier) {
                    if (self.lookupVar(ca.target.identifier.name)) |cell_chan| {
                        const meta = self.channel_metas.items[cell_chan];
                        if (meta.is_cell) {
                            try self.emit(.{
                                .op = .cell_set,
                                .inputs = .{ cell_chan, result_chan, 0 },
                                .output = cell_chan,
                                .input_count = 2,
                            });
                            break :blk result_chan;
                        }
                        try self.defineVar(ca.target.identifier.name, result_chan);
                    }
                }
                break :blk result_chan;
            },
            .throw_stmt => |ts| blk: {
                // 编译 throw 表达式，发射 halt_throw 层
                const err_chan = try self.compileExpr(ts.expr);
                const out_chan = try self.allocChannel(.ref_chan);
                try self.emit(.{
                    .op = .halt_throw,
                    .inputs = .{ err_chan, 0, 0 },
                    .output = out_chan,
                    .ref_kind = .error_val,
                    .input_count = 1,
                });
                break :blk out_chan;
            },

            // 阶段 5: break 语句 — 发射 halt_break
            .break_stmt => blk: {
                try self.emit(.{
                    .op = .halt_break,
                    .inputs = .{ 0, 0, 0 },
                    .output = 0,
                    .input_count = 0,
                });
                break :blk try self.allocChannel(.unit_chan);
            },

            // 阶段 5: continue 语句 — 发射 halt_continue
            .continue_stmt => blk: {
                try self.emit(.{
                    .op = .halt_continue,
                    .inputs = .{ 0, 0, 0 },
                    .output = 0,
                    .input_count = 0,
                });
                break :blk try self.allocChannel(.unit_chan);
            },

            // ── 星轨模型：defer → 编译为轨道 + defer_register ──
            .defer_stmt => |ds| blk: {
                // 将 defer 体编译为独立轨道
                const defer_orbit = try self.beginOrbit();
                try self.pushScope();
                _ = try self.compileExpr(ds.expr);
                self.popScope();
                const defer_out = try self.allocChannel(.unit_chan);
                try self.endOrbit(defer_orbit, defer_out, false, null);

                // 在当前层发射 defer_register（const_val = 轨道索引）
                try self.emit(.{
                    .op = .defer_register,
                    .inputs = .{ 0, 0, 0 },
                    .output = 0,
                    .const_val = @intCast(defer_orbit),
                    .input_count = 0,
                });

                // 记录 DeferEntry
                try self.defer_entries_list.append(self.arena.allocator(), .{
                    .orbit_index = defer_orbit,
                    .order = @intCast(self.defer_entries_list.items.len),
                });

                break :blk try self.allocChannel(.unit_chan);
            },

            // ── 星轨模型：for → 环形轨道 + 迭代器 ──
            .for_stmt => |fs| blk: {
                const a = self.arena.allocator();

                // 1. 在太阳层创建迭代器
                var iter_chan: u16 = 0;
                if (fs.iterable.* == .call and fs.iterable.call.callee.* == .identifier) {
                    const fn_name = fs.iterable.call.callee.identifier.name;
                    if (std.mem.eql(u8, fn_name, "range")) {
                        const args = fs.iterable.call.arguments;
                        if (args.len >= 2) {
                            const start_chan = try self.compileExpr(args[0]);
                            const end_chan = try self.compileExpr(args[1]);
                            iter_chan = try self.allocChannel(.ref_chan);
                            self.channel_metas.items[iter_chan].elem_width = 17;
                            try self.emit(.{
                                .op = .range_make,
                                .inputs = .{ start_chan, end_chan, 0 },
                                .output = iter_chan,
                                .const_val = 0,
                                .ref_kind = .range,
                                .input_count = 2,
                            });
                        }
                    }
                }
                if (iter_chan == 0) {
                    iter_chan = try self.compileExpr(fs.iterable);
                }

                // 2. 创建环形轨道
                const loop_orbit = try self.beginOrbit();

                try self.pushScope();
                // 3. 在轨道内发射 iter_has_next → has_next_chan
                const has_next_chan = try self.allocChannel(.bool_chan);
                try self.emit(.{
                    .op = .iter_has_next,
                    .inputs = .{ iter_chan, 0, 0 },
                    .output = has_next_chan,
                    .input_count = 1,
                });

                // 4. 设置谓词门控：无下一个元素时跳过体
                const saved_predicate = self.current_predicate;
                self.current_predicate = has_next_chan;

                // 5. 发射 iter_next → val_chan，绑定循环变量
                const val_chan = try self.allocChannel(.i64_chan);
                try self.emit(.{
                    .op = .iter_next,
                    .inputs = .{ iter_chan, 0, 0 },
                    .output = val_chan,
                    .input_count = 1,
                });
                try self.defineVar(fs.name, val_chan);

                // 6. 编译循环体
                _ = try self.compileExpr(fs.body);

                // 7. 恢复谓词
                self.current_predicate = saved_predicate;
                self.popScope();

                // 8. 固化轨道：is_cyclic=true, continue_channel=has_next_chan
                const loop_out = try self.allocChannel(.unit_chan);
                try self.endOrbit(loop_orbit, loop_out, true, has_next_chan);

                // 9. 创建 OrbitHub(loop_hub)
                const orbit_table = try a.alloc(OrbitEntry, 1);
                orbit_table[0] = .{ .cond_kind = .always, .orbit_index = loop_orbit };
                const hub_idx = try self.createOrbitHub(.{
                    .kind = .loop_hub,
                    .cond_channel = null,
                    .orbit_table = orbit_table,
                    .output_channel = loop_out,
                    .is_cyclic = true,
                    .continue_channel = has_next_chan,
                });

                // 10. 在太阳层发射 orbit_hub lamina
                try self.emit(.{
                    .op = .orbit_hub,
                    .hub_index = hub_idx,
                    .output = loop_out,
                    .input_count = 0,
                });

                break :blk loop_out;
            },

            // ── 星轨模型：while → OrbitHub(loop_hub) + 环形轨道 ──
            .while_stmt => |ws| blk: {
                const a = self.arena.allocator();

                // 1. 创建环形轨道
                const loop_orbit = try self.beginOrbit();

                try self.pushScope();
                // 2. 在轨道内编译条件 → cond_chan（bool: 1=继续, 0=停止）
                const cond_chan = try self.compileExpr(ws.condition);

                // 3. 设置谓词门控：条件为假时跳过循环体
                const saved_predicate = self.current_predicate;
                self.current_predicate = cond_chan;

                // 4. 编译循环体（体 lamina 自动获得 predicate = cond_chan）
                _ = try self.compileExpr(ws.body);

                // 5. 恢复谓词
                self.current_predicate = saved_predicate;
                self.popScope();

                // 6. 固化轨道：is_cyclic=true, continue_channel=cond_chan
                const loop_out = try self.allocChannel(.unit_chan);
                try self.endOrbit(loop_orbit, loop_out, true, cond_chan);

                // 7. 创建 OrbitHub(loop_hub)
                const orbit_table = try a.alloc(OrbitEntry, 1);
                orbit_table[0] = .{ .cond_kind = .always, .orbit_index = loop_orbit };
                const hub_idx = try self.createOrbitHub(.{
                    .kind = .loop_hub,
                    .cond_channel = null,
                    .orbit_table = orbit_table,
                    .output_channel = loop_out,
                    .is_cyclic = true,
                    .continue_channel = cond_chan,
                });

                // 8. 在太阳层发射 orbit_hub lamina
                try self.emit(.{
                    .op = .orbit_hub,
                    .hub_index = hub_idx,
                    .output = loop_out,
                    .input_count = 0,
                });

                break :blk loop_out;
            },

            // ── 星轨模型：loop → 环形轨道（无限循环，break 退出）──
            .loop_stmt => |ls| blk: {
                const a = self.arena.allocator();

                // 1. 创建环形轨道
                const loop_orbit = try self.beginOrbit();

                try self.pushScope();
                // 2. 发射常量 1 → continue_chan（永远继续，仅 break 退出）
                const continue_chan = try self.allocChannel(.bool_chan);
                try self.emit(.{
                    .op = .constant,
                    .inputs = .{ continue_chan, 0, 0 },
                    .output = continue_chan,
                    .const_val = 1,
                    .input_count = 0,
                });

                // 3. 编译循环体（无谓词门控，始终执行）
                _ = try self.compileExpr(ls.body);
                self.popScope();

                // 4. 固化轨道：is_cyclic=true, continue_channel=continue_chan
                const loop_out = try self.allocChannel(.unit_chan);
                try self.endOrbit(loop_orbit, loop_out, true, continue_chan);

                // 5. 创建 OrbitHub(loop_hub)
                const orbit_table = try a.alloc(OrbitEntry, 1);
                orbit_table[0] = .{ .cond_kind = .always, .orbit_index = loop_orbit };
                const hub_idx = try self.createOrbitHub(.{
                    .kind = .loop_hub,
                    .cond_channel = null,
                    .orbit_table = orbit_table,
                    .output_channel = loop_out,
                    .is_cyclic = true,
                    .continue_channel = continue_chan,
                });

                // 6. 在太阳层发射 orbit_hub lamina
                try self.emit(.{
                    .op = .orbit_hub,
                    .hub_index = hub_idx,
                    .output = loop_out,
                    .input_count = 0,
                });

                break :blk loop_out;
            },

            else => try self.allocChannel(.unit_chan),
        };
    }

    // ── 函数调用编译 ──

    fn compileCall(self: *LaminarCompiler, c: anytype) CompileError!u16 {
        // 检查是否为内置函数（callee 为 identifier）
        if (c.callee.* == .identifier) {
            const fn_name = c.callee.identifier.name;

            // 查 builtin 函数表（O(1) comptime StaticStringMap）
            if (builtin.lookupFunction(fn_name)) |fn_kind| {
                return try self.compileBuiltinFunction(fn_kind, c.arguments);
            }

            // E1：检查是否为 async 函数调用（通过异步轨道）
            if (self.async_orbit_map.get(fn_name)) |orbit_info| {
                const a = self.arena.allocator();
                // 编译参数
                const arg_chans = try a.alloc(u16, c.arguments.len);
                for (c.arguments, 0..) |arg, i| {
                    arg_chans[i] = try self.compileExpr(arg);
                }

                // 分配输出通道（异步句柄）
                const out_chan = try self.allocChannel(.ref_chan);

                // 构建 param_mapping：太阳层参数通道 → 轨道入口通道
                const param_mapping = try a.alloc(ParamBind, orbit_info.param_channels.len);
                for (orbit_info.param_channels, 0..) |pc, i| {
                    param_mapping[i] = .{
                        .src = if (i < arg_chans.len) arg_chans[i] else 0,
                        .dst = pc,
                    };
                }

                // 创建 OrbitHub（async_hub 类型，无条件激活）
                const orbit_table = try a.alloc(OrbitEntry, 1);
                orbit_table[0] = .{ .cond_kind = .always, .orbit_index = orbit_info.orbit_index };
                const hub_idx = try self.createOrbitHub(.{
                    .kind = .async_hub,
                    .cond_channel = null,
                    .orbit_table = orbit_table,
                    .output_channel = out_chan,
                    .param_mapping = param_mapping,
                });

                // 发射 orbit_hub_async lamina（异步激活，不等待）
                try self.emit(.{
                    .op = .orbit_hub_async,
                    .hub_index = hub_idx,
                    .output = out_chan,
                    .input_count = 0,
                });

                return out_chan;
            }
        }

        // 检查是否为已知 Glue 函数（非 async、非内置）
        if (c.callee.* == .identifier) {
            const fn_name = c.callee.identifier.name;
            if (self.func_table.get(fn_name)) |func_decl| {
                return try self.compileFunctionCall(func_decl, c.arguments);
            }

            // E2: 检查是否为闭包变量（编译期追踪）
            if (self.lookupVar(fn_name)) |closure_chan| {
                if (self.closure_chan_map.get(closure_chan)) |ci| {
                    return try self.compileClosureCall(ci, closure_chan, c.arguments);
                }
            }
        }

        // E2: callee 是表达式（非 identifier）— 编译为闭包值后运行时分派
        // 运行时 closure_hub 分派需要引擎支持，E2-8 实现
        // 目前先编译 callee 获取闭包值，再通过 closure_call op 调用（占位）
        // 注：完整运行时分派在 E2-8 中实现

        // 未知函数调用：返回编译错误（星轨模型不使用 extern_call）
        return error.UnsupportedExpr;
    }

    /// 编译 builtin 函数（通过 builtin 表分派）
    fn compileBuiltinFunction(
        self: *LaminarCompiler,
        fn_kind: builtin.BuiltinFnKind,
        arguments: []const *ast.Expr,
    ) CompileError!u16 {
        switch (fn_kind) {
            .println, .print => {
                // println/print(arg) → debug_print(arg) 到 stdout
                if (arguments.len > 0) {
                    const arg_chan = try self.compileExpr(arguments[0]);
                    try self.emit(.{
                        .op = .debug_print,
                        .inputs = .{ arg_chan, 0, 0 },
                        .output = arg_chan,
                        .input_count = 1,
                    });
                }
                return try self.allocChannel(.unit_chan);
            },
            .eprintln, .eprint => {
                // eprintln/eprint(arg) → debug_print_err(arg) 到 stderr
                if (arguments.len > 0) {
                    const arg_chan = try self.compileExpr(arguments[0]);
                    try self.emit(.{
                        .op = .debug_print_err,
                        .inputs = .{ arg_chan, 0, 0 },
                        .output = arg_chan,
                        .input_count = 1,
                    });
                }
                return try self.allocChannel(.unit_chan);
            },
            .scanln, .scan => {
                // scanln/scan() → 返回 null（stdin 输入暂未实现）
                return try self.allocChannel(.null_chan);
            },
            .eq => {
                // eq(a, b) → int_eq(a, b)
                if (arguments.len < 2) return error.UnsupportedExpr;
                const a_chan = try self.compileExpr(arguments[0]);
                const b_chan = try self.compileExpr(arguments[1]);
                const out_chan = try self.allocChannel(.bool_chan);
                try self.emit(.{
                    .op = .int_eq,
                    .inputs = .{ a_chan, b_chan, 0 },
                    .output = out_chan,
                    .int_kind = .i64,
                    .input_count = 2,
                });
                return out_chan;
            },
            .type_name => {
                // type(x) → 返回类型名字符串（暂返回 "unknown"）
                const out_chan = try self.allocChannel(.ref_chan);
                const str_idx = try self.internString("unknown");
                try self.emit(.{
                    .op = .str_const,
                    .const_val = @intCast(str_idx),
                    .output = out_chan,
                    .input_count = 0,
                });
                return out_chan;
            },
            .panic_fn => {
                // Panic(msg) → halt_throw
                if (arguments.len > 0) {
                    const arg_chan = try self.compileExpr(arguments[0]);
                    try self.emit(.{
                        .op = .halt_throw,
                        .inputs = .{ arg_chan, 0, 0 },
                        .output = arg_chan,
                        .input_count = 1,
                    });
                }
                return try self.allocChannel(.unit_chan);
            },
            .atomic => {
                // atomic(value) → atomic_make
                const arg_chan = if (arguments.len > 0)
                    try self.compileExpr(arguments[0])
                else
                    try self.allocChannel(.i64_chan);
                const out_chan = try self.allocChannel(.ref_chan);
                try self.emit(.{
                    .op = .atomic_make,
                    .inputs = .{ arg_chan, 0, 0 },
                    .output = out_chan,
                    .input_count = 1,
                });
                return out_chan;
            },
            .channel => {
                // channel(capacity) → channel_make
                const cap: i64 = if (arguments.len > 0 and arguments[0].* == .int_literal) blk: {
                    const lit = arguments[0].int_literal;
                    break :blk std.fmt.parseInt(i64, lit.raw, 10) catch 0;
                } else 0;
                const out_chan = try self.allocChannel(.ref_chan);
                try self.emit(.{
                    .op = .channel_make,
                    .inputs = .{ 0, 0, 0 },
                    .output = out_chan,
                    .const_val = cap,
                    .input_count = 0,
                });
                return out_chan;
            },
        }
    }

    /// 编译 builtin 方法（通过 builtin 表分派）
    /// obj_chan = 对象通道, ref_kind = 对象的 ref 类型（null 表示标量）
    fn compileBuiltinMethod(
        self: *LaminarCompiler,
        method_kind: builtin.BuiltinMethodKind,
        obj_chan: u16,
        arguments: []const *ast.Expr,
    ) CompileError!u16 {
        switch (method_kind) {
            // ── 通用方法 ──
            .universal_println => {
                // obj.println() → debug_print(obj)
                try self.emit(.{
                    .op = .debug_print,
                    .inputs = .{ obj_chan, 0, 0 },
                    .output = obj_chan,
                    .input_count = 1,
                });
                return try self.allocChannel(.unit_chan);
            },

            // ── 数组方法 ──
            .array_len => {
                // arr.len() → array_len
                const out_chan = try self.allocChannel(.i64_chan);
                try self.emit(.{
                    .op = .array_len,
                    .inputs = .{ obj_chan, 0, 0 },
                    .output = out_chan,
                    .ref_kind = .array,
                    .input_count = 1,
                });
                return out_chan;
            },
            .array_push => {
                // arr.push(x) → array_push（in-place 修改，返回数组引用）
                if (arguments.len < 1) return error.UnsupportedExpr;
                const val_chan = try self.compileExpr(arguments[0]);
                const out_chan = try self.allocChannel(.ref_chan);
                try self.emit(.{
                    .op = .array_push,
                    .inputs = .{ obj_chan, val_chan, 0 },
                    .output = out_chan,
                    .ref_kind = .array,
                    .input_count = 2,
                });
                return out_chan;
            },
            .array_get => {
                // arr.get(i) → array_get
                if (arguments.len < 1) return error.UnsupportedExpr;
                const idx_chan = try self.compileExpr(arguments[0]);
                const out_chan = try self.allocChannel(.i64_chan);
                try self.emit(.{
                    .op = .array_get,
                    .inputs = .{ obj_chan, idx_chan, 0 },
                    .output = out_chan,
                    .ref_kind = .array,
                    .input_count = 2,
                });
                return out_chan;
            },
            .array_set => {
                // arr.set(i, x) → array_set
                if (arguments.len < 2) return error.UnsupportedExpr;
                const idx_chan = try self.compileExpr(arguments[0]);
                const val_chan = try self.compileExpr(arguments[1]);
                try self.emit(.{
                    .op = .array_set,
                    .inputs = .{ obj_chan, idx_chan, val_chan },
                    .output = obj_chan,
                    .ref_kind = .array,
                    .input_count = 3,
                });
                return try self.allocChannel(.unit_chan);
            },

            // ── Channel 方法 ──
            .channel_send => {
                // ch.send(x) → channel_send
                if (arguments.len < 1) return error.UnsupportedExpr;
                const val_chan = try self.compileExpr(arguments[0]);
                try self.emit(.{
                    .op = .channel_send,
                    .inputs = .{ obj_chan, val_chan, 0 },
                    .output = obj_chan,
                    .ref_kind = .channel_val,
                    .input_count = 2,
                });
                return try self.allocChannel(.unit_chan);
            },
            .channel_recv => {
                // ch.recv() → channel_recv
                const out_chan = try self.allocChannel(.i64_chan);
                try self.emit(.{
                    .op = .channel_recv,
                    .inputs = .{ obj_chan, 0, 0 },
                    .output = out_chan,
                    .ref_kind = .channel_val,
                    .input_count = 1,
                });
                return out_chan;
            },
            .channel_try_recv => {
                // ch.tryRecv() → channel_try_recv（返回 nullable）
                const out_chan = try self.allocChannel(.nullable_chan);
                try self.emit(.{
                    .op = .channel_try_recv,
                    .inputs = .{ obj_chan, 0, 0 },
                    .output = out_chan,
                    .ref_kind = .channel_val,
                    .input_count = 1,
                });
                return out_chan;
            },
            .channel_close => {
                // ch.close() → channel_close
                try self.emit(.{
                    .op = .channel_close,
                    .inputs = .{ obj_chan, 0, 0 },
                    .output = obj_chan,
                    .ref_kind = .channel_val,
                    .input_count = 1,
                });
                return try self.allocChannel(.unit_chan);
            },
            .channel_sender => {
                // ch.sender() → channel_get_sender
                const out_chan = try self.allocChannel(.ref_chan);
                try self.emit(.{
                    .op = .channel_get_sender,
                    .inputs = .{ obj_chan, 0, 0 },
                    .output = out_chan,
                    .ref_kind = .channel_val,
                    .input_count = 1,
                });
                return out_chan;
            },
            .channel_receiver => {
                // ch.receiver() → channel_get_receiver
                const out_chan = try self.allocChannel(.ref_chan);
                try self.emit(.{
                    .op = .channel_get_receiver,
                    .inputs = .{ obj_chan, 0, 0 },
                    .output = out_chan,
                    .ref_kind = .channel_val,
                    .input_count = 1,
                });
                return out_chan;
            },

            // ── Atomic 方法 ──
            .atomic_load => {
                // atomic.load() → atomic_load
                const out_chan = try self.allocChannel(.i64_chan);
                try self.emit(.{
                    .op = .atomic_load,
                    .inputs = .{ obj_chan, 0, 0 },
                    .output = out_chan,
                    .ref_kind = .atomic_val,
                    .input_count = 1,
                });
                return out_chan;
            },
            .atomic_store => {
                // atomic.store(x) → atomic_store
                if (arguments.len < 1) return error.UnsupportedExpr;
                const val_chan = try self.compileExpr(arguments[0]);
                try self.emit(.{
                    .op = .atomic_store,
                    .inputs = .{ obj_chan, val_chan, 0 },
                    .output = obj_chan,
                    .ref_kind = .atomic_val,
                    .input_count = 2,
                });
                return try self.allocChannel(.unit_chan);
            },
            .atomic_swap => {
                // atomic.swap(x) → atomic_swap
                if (arguments.len < 1) return error.UnsupportedExpr;
                const val_chan = try self.compileExpr(arguments[0]);
                const out_chan = try self.allocChannel(.i64_chan);
                try self.emit(.{
                    .op = .atomic_swap,
                    .inputs = .{ obj_chan, val_chan, 0 },
                    .output = out_chan,
                    .ref_kind = .atomic_val,
                    .input_count = 2,
                });
                return out_chan;
            },
            .atomic_compare_swap => {
                // atomic.compare_swap(expected, new) → atomic_cas
                if (arguments.len < 2) return error.UnsupportedExpr;
                const expected_chan = try self.compileExpr(arguments[0]);
                const new_chan = try self.compileExpr(arguments[1]);
                const out_chan = try self.allocChannel(.bool_chan);
                try self.emit(.{
                    .op = .atomic_cas,
                    .inputs = .{ obj_chan, expected_chan, new_chan },
                    .output = out_chan,
                    .ref_kind = .atomic_val,
                    .input_count = 3,
                });
                return out_chan;
            },

            // ── Async 方法 ──
            .async_await => {
                // async.await() → async_join
                const out_chan = try self.allocChannel(.i64_chan);
                try self.emit(.{
                    .op = .async_join,
                    .inputs = .{ obj_chan, 0, 0 },
                    .output = out_chan,
                    .ref_kind = .async_val,
                    .input_count = 1,
                });
                return out_chan;
            },
            .async_status => {
                // async.status() → async_status
                const out_chan = try self.allocChannel(.i64_chan);
                try self.emit(.{
                    .op = .async_status,
                    .inputs = .{ obj_chan, 0, 0 },
                    .output = out_chan,
                    .ref_kind = .async_val,
                    .input_count = 1,
                });
                return out_chan;
            },

            // ── 字符串方法（暂未实现引擎执行） ──
            .string_len, .string_char_at, .string_slice => return error.UnsupportedExpr,
        }
    }

    // ── 函数调用编译（C2：递归 + 内联）──

    /// 编译对已知 Glue 函数的调用
    /// 静态函数（无分支）→ 内联到当前层（太阳层或轨道内）
    /// 动态函数（含分支）→ 生成轨道 + OrbitHub
    /// 递归调用 → 重用已编译轨道 + stack_push/pop 保存/恢复参数
    fn compileFunctionCall(
        self: *LaminarCompiler,
        decl: *const ast.Decl,
        arguments: []const *ast.Expr,
    ) CompileError!u16 {
        const func_decl = switch (decl.*) {
            .fun_decl => |*f| f,
            else => unreachable,
        };
        const a = self.arena.allocator();

        // 1. 编译参数到通道（在父层/当前层）
        const arg_chans = try a.alloc(u16, arguments.len);
        for (arguments, 0..) |arg, i| {
            arg_chans[i] = try self.compileExpr(arg);
        }

        const ret_type = if (func_decl.return_type) |rt|
            mapTypeNode(rt) orelse .i64_chan
        else
            .i64_chan;
        const ret_ref_kind = mapTypeNodeToRefKind(func_decl.return_type);

        // 2. 检查函数轨道是否已注册（递归调用或函数重用）
        if (self.func_orbit_map.get(func_decl.name)) |orbit_info| {
            return try self.compileRecursiveCall(orbit_info, arg_chans, ret_type);
        }

        // 3. 判定函数体是否完全静态
        const is_body_static = self.isStaticBody(decl);

        // ── 路径 A：静态函数内联到当前层（不生成轨道）──
        if (is_body_static and self.recursion_depth < 3) {
            try self.pushScope();
            for (func_decl.params, 0..) |param, i| {
                const chan = if (i < arg_chans.len) arg_chans[i] else 0;
                try self.defineVar(param.name, chan);
            }
            const out_chan = try self.allocChannel(ret_type);
            self.channel_metas.items[out_chan].ref_kind = ret_ref_kind;
            const saved_return_channel = self.current_return_channel;
            self.current_return_channel = out_chan;
            self.recursion_depth += 1;

            const body_result = try self.compileExpr(func_decl.body);

            try self.emit(.{
                .op = .move,
                .inputs = .{ body_result, 0, 0 },
                .output = out_chan,
                .input_count = 1,
            });

            self.recursion_depth -= 1;
            self.current_return_channel = saved_return_channel;
            self.popScope();
            return out_chan;
        }

        // ── 路径 B：动态函数生成轨道 + OrbitHub ──
        const out_chan = try self.allocChannel(ret_type);
        self.channel_metas.items[out_chan].ref_kind = ret_ref_kind;
        // temp_chan 在轨道范围外分配（before beginOrbit），用于递归调用结果暂存
        const temp_chan = try self.allocChannel(ret_type);
        const channel_start = self.channel_count; // 记录轨道通道范围起点
        const call_orbit = try self.beginOrbit();
        try self.pushScope();

        // 分配桥接入口通道（bridge_in），记录 param_mapping
        const param_mapping = try a.alloc(ParamBind, func_decl.params.len);
        const param_channels = try a.alloc(u16, func_decl.params.len);
        for (func_decl.params, 0..) |param, i| {
            const chan_type = mapTypeNode(param.type_annotation) orelse .i64_chan;
            const param_chan = try self.allocBridgeInChannel(chan_type);
            // 设置 ref_kind 以支持方法分派（如 arr.len()）
            self.channel_metas.items[param_chan].ref_kind = mapTypeNodeToRefKind(param.type_annotation);
            param_mapping[i] = .{
                .src = if (i < arg_chans.len) arg_chans[i] else 0,
                .dst = param_chan,
            };
            param_channels[i] = param_chan;
            try self.defineVar(param.name, param_chan);
        }

        // 分配桥接出口通道（bridge_out）
        const ret_chan = try self.allocBridgeOutChannel(ret_type);

        // 注册到 func_orbit_map（编译体之前注册，以便递归调用能找到）
        // channel_end 暂填 0，endOrbit 后更新
        try self.func_orbit_map.put(func_decl.name, .{
            .orbit_index = call_orbit,
            .param_channels = param_channels,
            .output_channel = ret_chan,
            .channel_start = channel_start,
            .channel_end = 0,
            .temp_chan = temp_chan,
        });

        const saved_return_channel = self.current_return_channel;
        self.current_return_channel = ret_chan;
        self.recursion_depth += 1;

        // 编译函数体
        const body_result = try self.compileExpr(func_decl.body);

        // 尾表达式 fallback：move 到返回通道
        try self.emit(.{
            .op = .move,
            .inputs = .{ body_result, 0, 0 },
            .output = ret_chan,
            .input_count = 1,
        });

        self.recursion_depth -= 1;
        self.current_return_channel = saved_return_channel;
        self.popScope();

        // 轨道体编译完毕，确定通道范围终点
        const channel_end = self.channel_count;
        if (self.func_orbit_map.getPtr(func_decl.name)) |info_ptr| {
            info_ptr.channel_end = channel_end;
        }

        // 修补递归调用的 stack_push/pop：编译时 channel_end 尚未知，const_val2 填了 0
        // 递归调用可能位于嵌套轨道中（如 if-else 的 else 分支），
        // 需扫描所有已固化的轨道 laminas 和当前 self.laminas
        const range_count: i64 = @intCast(channel_end - channel_start);
        for (self.laminas.items) |*lam| {
            if (lam.op == .stack_push or lam.op == .stack_pop) {
                if (lam.const_val) |cv| {
                    if (@as(u16, @intCast(cv)) == channel_start) {
                        lam.const_val2 = range_count;
                    }
                }
            }
        }
        for (self.orbit_laminas_list.items) |*olams| {
            // orbit_laminas_list 存储 []const Lamina，但底层数据由 dupe 分配，可安全 @constCast
            const mutable_lams: []Lamina = @constCast(olams.*);
            for (mutable_lams) |*lam| {
                if (lam.op == .stack_push or lam.op == .stack_pop) {
                    if (lam.const_val) |cv| {
                        if (@as(u16, @intCast(cv)) == channel_start) {
                            lam.const_val2 = range_count;
                        }
                    }
                }
            }
        }

        // 固化轨道
        try self.endOrbit(call_orbit, ret_chan, false, null);

        // 创建 OrbitHub
        const orbit_table = try a.alloc(OrbitEntry, 1);
        orbit_table[0] = .{ .cond_kind = .always, .orbit_index = call_orbit };
        const hub_idx = try self.createOrbitHub(.{
            .kind = .if_hub,
            .cond_channel = null,
            .orbit_table = orbit_table,
            .output_channel = out_chan,
            .param_mapping = param_mapping,
        });
        try self.emit(.{
            .op = .orbit_hub,
            .hub_index = hub_idx,
            .output = out_chan,
            .input_count = 0,
        });

        return out_chan;
    }

    /// 递归调用编译：重用已编译的函数轨道
    /// 通过 stack_push/pop 保存/恢复轨道的完整通道范围，实现递归重入
    /// 关键：不仅保存参数通道，还要保存所有中间结果通道，
    /// 否则 fib(n-1)+fib(n-2) 中第二次调用会覆盖第一次调用的中间结果
    ///
    /// 流程（使用轨道范围外的 temp_chan 暂存结果）：
    ///   1. stack_push 保存 [channel_start, channel_end)
    ///   2. 写入新参数，运行轨道 → out_chan 写入结果
    ///   3. move out_chan → temp_chan（暂存到范围外）
    ///   4. stack_pop 恢复 [channel_start, channel_end)（out_chan 被恢复为调用前值）
    ///   5. move temp_chan → out_chan（将结果写回 out_chan）
    fn compileRecursiveCall(
        self: *LaminarCompiler,
        orbit_info: FuncOrbitInfo,
        arg_chans: []const u16,
        ret_type: ScalarChanType,
    ) CompileError!u16 {
        const a = self.arena.allocator();
        const out_chan = try self.allocChannel(ret_type);
        // 继承函数返回通道的 ref_kind（如数组返回值需支持 .len() 调用）
        if (orbit_info.output_channel < self.channel_metas.items.len) {
            self.channel_metas.items[out_chan].ref_kind =
                self.channel_metas.items[orbit_info.output_channel].ref_kind;
        }
        // channel_end 在编译期可能为 0（endOrbit 前递归调用自身），
        // 此时先发射 const_val2=0 的占位 stack_push，由 compileFunctionCall 的修补逻辑更新
        const range_count: i64 = if (orbit_info.channel_end > orbit_info.channel_start)
            @intCast(orbit_info.channel_end - orbit_info.channel_start)
        else
            0; // 占位，后续修补

        // 1. stack_push：保存轨道完整通道范围（递归重入前保存现场）
        try self.emit(.{
            .op = .stack_push,
            .const_val = @intCast(orbit_info.channel_start),
            .const_val2 = range_count,
            .output = orbit_info.output_channel,
            .input_count = 0,
        });

        // 2. 写入新参数到轨道入口通道
        for (arg_chans, 0..) |arg_chan, i| {
            if (i < orbit_info.param_channels.len) {
                try self.emit(.{
                    .op = .move,
                    .inputs = .{ arg_chan, 0, 0 },
                    .output = orbit_info.param_channels[i],
                    .input_count = 1,
                });
            }
        }

        // 3. 激活轨道（同步执行，复用同一轨道模板）
        const orbit_table = try a.alloc(OrbitEntry, 1);
        orbit_table[0] = .{ .cond_kind = .always, .orbit_index = orbit_info.orbit_index };
        const hub_idx = try self.createOrbitHub(.{
            .kind = .if_hub,
            .cond_channel = null,
            .orbit_table = orbit_table,
            .output_channel = out_chan,
        });
        try self.emit(.{
            .op = .orbit_hub,
            .hub_index = hub_idx,
            .output = out_chan,
            .input_count = 0,
        });

        // 4. 暂存递归结果到 temp_chan（在轨道范围外，不会被 stack_pop 覆盖）
        try self.emit(.{
            .op = .move,
            .inputs = .{ out_chan, 0, 0 },
            .output = orbit_info.temp_chan,
            .input_count = 1,
        });

        // 5. stack_pop：恢复轨道完整通道范围（恢复调用方现场）
        try self.emit(.{
            .op = .stack_pop,
            .const_val = @intCast(orbit_info.channel_start),
            .const_val2 = range_count,
            .input_count = 0,
        });

        // 6. 将递归结果从 temp_chan 写回 out_chan
        try self.emit(.{
            .op = .move,
            .inputs = .{ orbit_info.temp_chan, 0, 0 },
            .output = out_chan,
            .input_count = 1,
        });

        return out_chan;
    }

    // ── 方法调用编译 ──

    fn compileMethodCall(self: *LaminarCompiler, mc: anytype) CompileError!u16 {
        const obj_chan = try self.compileExpr(mc.object);

        // 获取对象通道的 ref_kind（用于按类型分派 builtin 方法）
        const ref_kind: ?value.obj_header.RefKind = blk: {
            if (obj_chan < self.channel_metas.items.len) {
                const meta = self.channel_metas.items[obj_chan];
                break :blk meta.ref_kind;
            }
            break :blk null;
        };

        // 查 builtin 方法表（O(1) comptime StaticStringMap，按 ref_kind 分组）
        if (builtin.lookupMethod(ref_kind, mc.method)) |method_kind| {
            return try self.compileBuiltinMethod(method_kind, obj_chan, mc.arguments);
        }

        // E2: 检查是否为 trait 方法调用（编译期追踪）
        if (self.trait_chan_map.get(obj_chan)) |type_tag| {
            return try self.compileTraitMethodCall(obj_chan, type_tag, mc.method, mc.arguments);
        }

        // 未知方法调用：返回编译错误（星轨模型不使用 extern_call）
        return error.UnsupportedExpr;
    }

    // ── 赋值表达式编译 ──

    fn compileAssignment(self: *LaminarCompiler, assign: anytype) CompileError!u16 {
        const val_chan = try self.compileExpr(assign.value);
        if (assign.target.* == .identifier) {
            try self.defineVar(assign.target.identifier.name, val_chan);
        }
        return val_chan;
    }

    // ── E2: 闭包编译 ──

    /// 编译 lambda 表达式为轨道 + closure_make
    /// 1. 自由变量分析：扫描 body 找出引用的外层变量
    /// 2. 编译为轨道：bridge_in 通道绑定参数和捕获
    /// 3. 发射 closure_make：存储 orbit_index + 捕获值
    fn compileLambda(self: *LaminarCompiler, lam: anytype) CompileError!u16 {
        const a = self.arena.allocator();

        // 1. 自由变量分析
        var free_vars_set = std.StringHashMap(void).init(a);
        defer free_vars_set.deinit();
        switch (lam.body) {
            .block => |b| try collectFreeVars(b, a, &free_vars_set),
            .expression => |e| try collectFreeVars(e, a, &free_vars_set),
        }

        // 排除 lambda 自身参数
        for (lam.params) |param| {
            _ = free_vars_set.remove(param.name);
        }

        // 在当前作用域中查找捕获通道
        var capture_names = std.ArrayList([]const u8).empty;
        defer capture_names.deinit(a);
        var capture_src_chans = std.ArrayList(u16).empty;
        defer capture_src_chans.deinit(a);

        var fv_it = free_vars_set.iterator();
        while (fv_it.next()) |entry| {
            if (self.lookupVar(entry.key_ptr.*)) |chan| {
                try capture_names.append(a, entry.key_ptr.*);
                try capture_src_chans.append(a, chan);
            }
        }

        // 2. 编译为轨道
        const orbit_idx = try self.beginOrbit();
        try self.pushScope();

        // 分配参数 bridge_in 通道并绑定
        const param_channels = try a.alloc(u16, lam.params.len);
        for (lam.params, 0..) |param, i| {
            const chan_type = mapTypeNode(param.type_annotation) orelse .i64_chan;
            const param_chan = try self.allocBridgeInChannel(chan_type);
            self.channel_metas.items[param_chan].ref_kind = mapTypeNodeToRefKind(param.type_annotation);
            param_channels[i] = param_chan;
            try self.defineVar(param.name, param_chan);
        }

        // 分配捕获 bridge_in 通道并绑定
        const capture_bridge_chans = try a.dupe(u16, capture_src_chans.items);
        for (capture_names.items, 0..) |name, i| {
            const cap_chan = try self.allocBridgeInChannel(.i64_chan);
            capture_bridge_chans[i] = cap_chan;
            try self.defineVar(name, cap_chan);
        }

        // 分配返回 bridge_out 通道
        const ret_type = if (lam.return_type) |rt|
            mapTypeNode(rt) orelse .i64_chan
        else
            .i64_chan;
        const ret_chan = try self.allocBridgeOutChannel(ret_type);

        // 编译函数体
        const saved_return_channel = self.current_return_channel;
        self.current_return_channel = ret_chan;

        const body_result = switch (lam.body) {
            .block => |b| try self.compileExpr(b),
            .expression => |e| try self.compileExpr(e),
        };

        // 尾表达式 fallback：move 到返回通道
        try self.emit(.{
            .op = .move,
            .inputs = .{ body_result, 0, 0 },
            .output = ret_chan,
            .input_count = 1,
        });

        self.current_return_channel = saved_return_channel;
        self.popScope();

        // 固化轨道（带参数和捕获通道信息）
        try self.endOrbitFull(orbit_idx, ret_chan, false, null, param_channels, capture_bridge_chans);

        // 3. 发射 closure_make：存储 orbit_index + 捕获值
        const closure_chan = try self.allocChannel(.ref_chan);

        // closure_make 的 inputs 是捕获通道，const_val 是 orbit_index
        var inputs: [3]u16 = .{ 0, 0, 0 };
        const cap_count = capture_src_chans.items.len;
        if (cap_count > 0) inputs[0] = capture_src_chans.items[0];
        if (cap_count > 1) inputs[1] = capture_src_chans.items[1];
        if (cap_count > 2) inputs[2] = capture_src_chans.items[2];

        try self.emit(.{
            .op = .closure_make,
            .inputs = inputs,
            .output = closure_chan,
            .const_val = @intCast(orbit_idx),
            .ref_kind = .closure,
            .input_count = @intCast(@min(cap_count, 3)),
        });

        // 4. 注册闭包信息到 closure_chan_map（编译期追踪用）
        try self.closure_chan_map.put(closure_chan, .{
            .orbit_index = orbit_idx,
            .param_channels = param_channels,
            .capture_channels = capture_bridge_chans,
            .capture_count = @intCast(cap_count),
            .output_channel = ret_chan,
        });

        return closure_chan;
    }

    // ── E2: 闭包调用编译 ──

    /// 编译对闭包值的调用（编译期追踪路径）
    /// 1. 从闭包值中提取捕获值（closure_capture）
    /// 2. 构建 param_mapping：参数 + 捕获 → 轨道入口通道
    /// 3. 创建 OrbitHub(closure_hub) 激活闭包轨道
    fn compileClosureCall(
        self: *LaminarCompiler,
        ci: ClosureInfo,
        closure_chan: u16,
        arguments: []const *ast.Expr,
    ) CompileError!u16 {
        const a = self.arena.allocator();

        // 1. 编译参数
        const arg_chans = try a.alloc(u16, arguments.len);
        for (arguments, 0..) |arg, i| {
            arg_chans[i] = try self.compileExpr(arg);
        }

        // 2. 从闭包值提取捕获值（closure_capture）
        const capture_val_chans = try a.alloc(u16, ci.capture_count);
        for (0..ci.capture_count) |i| {
            const cap_chan = try self.allocChannel(.i64_chan);
            try self.emit(.{
                .op = .closure_capture,
                .inputs = .{ closure_chan, 0, 0 },
                .output = cap_chan,
                .const_val = @intCast(i),
                .ref_kind = .closure,
                .input_count = 1,
            });
            capture_val_chans[i] = cap_chan;
        }

        // 3. 构建 param_mapping
        const total_mapping = ci.param_channels.len + ci.capture_channels.len;
        const param_mapping = try a.alloc(ParamBind, total_mapping);
        for (ci.param_channels, 0..) |pc, i| {
            param_mapping[i] = .{
                .src = if (i < arg_chans.len) arg_chans[i] else 0,
                .dst = pc,
            };
        }
        for (ci.capture_channels, 0..) |cc, i| {
            param_mapping[ci.param_channels.len + i] = .{
                .src = if (i < capture_val_chans.len) capture_val_chans[i] else 0,
                .dst = cc,
            };
        }

        // 4. 分配太阳层输出通道
        const out_chan = try self.allocChannel(.i64_chan);

        // 5. 创建 OrbitHub(closure_hub)
        const orbit_table = try a.alloc(OrbitEntry, 1);
        orbit_table[0] = .{ .cond_kind = .always, .orbit_index = ci.orbit_index };
        const hub_idx = try self.createOrbitHub(.{
            .kind = .closure_hub,
            .cond_channel = null,
            .orbit_table = orbit_table,
            .output_channel = out_chan,
            .param_mapping = param_mapping,
        });

        // 6. 发射 orbit_hub lamina（同步执行闭包轨道）
        try self.emit(.{
            .op = .orbit_hub,
            .hub_index = hub_idx,
            .output = out_chan,
            .input_count = 0,
        });

        return out_chan;
    }

    // ── E2: Trait 方法调用编译 ──

    /// 编译对 trait 值的方法调用（编译期追踪路径）
    /// 1. 在 trait_method_entries_list 中查找 (type_tag, method_name) 对应的轨道
    /// 2. 构建 param_mapping：self 数据 + 参数 → 轨道入口通道
    /// 3. 创建 OrbitHub(trait_hub) 激活方法轨道
    fn compileTraitMethodCall(
        self: *LaminarCompiler,
        obj_chan: u16,
        type_tag: u64,
        method_name: []const u8,
        arguments: []const *ast.Expr,
    ) CompileError!u16 {
        const a = self.arena.allocator();

        // 1. 查找方法轨道
        const method_name_id = try self.internName(method_name);
        var entry: ?TraitMethodEntry = null;
        for (self.trait_method_entries_list.items) |e| {
            if (e.type_tag == type_tag and e.method_name_id == method_name_id) {
                entry = e;
                break;
            }
        }
        if (entry == null) return error.UnsupportedExpr;
        const me = entry.?;

        // 2. 编译参数
        const arg_chans = try a.alloc(u16, arguments.len);
        for (arguments, 0..) |arg, i| {
            arg_chans[i] = try self.compileExpr(arg);
        }

        // 2.5 从 trait 值提取 self 数据（trait_downcast: slot 1 = data_value）
        const self_data_chan = try self.allocChannel(.i64_chan);
        try self.emit(.{
            .op = .trait_downcast,
            .inputs = .{ obj_chan, 0, 0 },
            .output = self_data_chan,
            .ref_kind = .trait_val,
            .input_count = 1,
        });

        // 3. 构建 param_mapping
        // 轨道入口通道布局: [self_channel, param_channels...]
        const total_mapping = 1 + me.param_channels.len;
        const param_mapping = try a.alloc(ParamBind, total_mapping);
        // self 数据绑定（提取后的 data_value → 轨道 self_channel）
        param_mapping[0] = .{ .src = self_data_chan, .dst = me.self_channel };
        // 参数绑定
        for (me.param_channels, 0..) |pc, i| {
            param_mapping[1 + i] = .{
                .src = if (i < arg_chans.len) arg_chans[i] else 0,
                .dst = pc,
            };
        }

        // 4. 分配太阳层输出通道
        const out_chan = try self.allocChannel(.i64_chan);

        // 5. 创建 OrbitHub(trait_hub)
        const orbit_table = try a.alloc(OrbitEntry, 1);
        orbit_table[0] = .{ .cond_kind = .always, .orbit_index = me.orbit_index };
        const hub_idx = try self.createOrbitHub(.{
            .kind = .trait_hub,
            .cond_channel = null,
            .orbit_table = orbit_table,
            .output_channel = out_chan,
            .param_mapping = param_mapping,
        });

        // 6. 发射 orbit_hub lamina（同步执行 trait 方法轨道）
        try self.emit(.{
            .op = .orbit_hub,
            .hub_index = hub_idx,
            .output = out_chan,
            .input_count = 0,
        });

        return out_chan;
    }

    // ── E2: Trait 值编译 ──

    /// 编译 inline_trait_value 为多个方法轨道 + trait_make
    /// 1. 每个方法体编译为独立轨道
    /// 2. 发射 trait_make：存储 type_tag + 数据占位
    /// 3. 方法调用时通过 OrbitHub(trait_hub) 分派
    fn compileInlineTraitValue(self: *LaminarCompiler, itv: anytype) CompileError!u16 {
        const a = self.arena.allocator();

        // 分配唯一 type_tag
        const type_tag = self.next_trait_type_tag;
        self.next_trait_type_tag += 1;

        // 为每个方法编译轨道
        for (itv.methods) |method| {
            if (method.body == null) continue;

            const orbit_idx = try self.beginOrbit();
            try self.pushScope();

            // self 数据通道（trait 值本身的数据）
            const self_chan = try self.allocBridgeInChannel(.i64_chan);
            try self.defineVar("self", self_chan);

            // 方法参数 bridge_in 通道
            const param_channels = try a.alloc(u16, method.params.len);
            for (method.params, 0..) |param, i| {
                const chan_type = mapTypeNode(param.type_annotation) orelse .i64_chan;
                const param_chan = try self.allocBridgeInChannel(chan_type);
                param_channels[i] = param_chan;
                try self.defineVar(param.name, param_chan);
            }

            // 返回 bridge_out 通道
            const ret_type = if (method.return_type) |rt|
                mapTypeNode(rt) orelse .i64_chan
            else
                .i64_chan;
            const ret_chan = try self.allocBridgeOutChannel(ret_type);

            // 编译方法体
            const saved_return_channel = self.current_return_channel;
            self.current_return_channel = ret_chan;

            const body_result = try self.compileExpr(method.body.?);

            // 尾表达式 fallback
            try self.emit(.{
                .op = .move,
                .inputs = .{ body_result, 0, 0 },
                .output = ret_chan,
                .input_count = 1,
            });

            self.current_return_channel = saved_return_channel;
            self.popScope();

            // 固化轨道（self 通道 + 参数通道作为 input_channels）
            const trait_input_chans = try a.alloc(u16, 1 + method.params.len);
            trait_input_chans[0] = self_chan;
            for (param_channels, 0..) |pc, i| {
                trait_input_chans[1 + i] = pc;
            }
            try self.endOrbitFull(orbit_idx, ret_chan, false, null, trait_input_chans, &.{});

            // 添加到 trait 方法分派表
            const method_name_id = try self.internName(method.name);
            try self.trait_method_entries_list.append(a, .{
                .type_tag = type_tag,
                .method_name_id = method_name_id,
                .orbit_index = orbit_idx,
                .param_channels = param_channels,
                .self_channel = self_chan,
                .output_channel = ret_chan,
            });
        }

        // 发射 trait_make：type_tag + 数据占位（数据通过方法调用时传入）
        const trait_chan = try self.allocChannel(.ref_chan);
        const data_chan = try self.allocChannel(.i64_chan);
        try self.emit(.{
            .op = .constant,
            .const_val = 0,
            .output = data_chan,
            .int_kind = .i64,
            .input_count = 0,
        });
        try self.emit(.{
            .op = .trait_make,
            .inputs = .{ data_chan, 0, 0 },
            .output = trait_chan,
            .const_val = @intCast(type_tag),
            .ref_kind = .trait_val,
            .input_count = 1,
        });

        // 注册 trait 值通道 → type_tag（编译期追踪用）
        try self.trait_chan_map.put(trait_chan, type_tag);

        return trait_chan;
    }

    /// 将名称注册到 name_table 并返回索引
    fn internName(self: *LaminarCompiler, name: []const u8) !u16 {
        for (self.name_table.items, 0..) |item, i| {
            if (std.mem.eql(u8, item, name)) return @intCast(i);
        }
        const idx: u16 = @intCast(self.name_table.items.len);
        try self.name_table.append(self.arena.allocator(), name);
        return idx;
    }
};

// ── 辅助函数 ──

fn parseIntKindFromSuffix(sfx: []const u8) ?IntKind {
    if (std.mem.eql(u8, sfx, "i8")) return .i8;
    if (std.mem.eql(u8, sfx, "i16")) return .i16;
    if (std.mem.eql(u8, sfx, "i32")) return .i32;
    if (std.mem.eql(u8, sfx, "i64")) return .i64;
    if (std.mem.eql(u8, sfx, "i128")) return .i128;
    if (std.mem.eql(u8, sfx, "u8")) return .u8;
    if (std.mem.eql(u8, sfx, "u16")) return .u16;
    if (std.mem.eql(u8, sfx, "u32")) return .u32;
    if (std.mem.eql(u8, sfx, "u64")) return .u64;
    if (std.mem.eql(u8, sfx, "u128")) return .u128;
    return null;
}

fn parseFloatKindFromSuffix(sfx: []const u8) ?FloatKind {
    if (std.mem.eql(u8, sfx, "f16")) return .f16;
    if (std.mem.eql(u8, sfx, "f32")) return .f32;
    if (std.mem.eql(u8, sfx, "f64")) return .f64;
    if (std.mem.eql(u8, sfx, "f128")) return .f128;
    return null;
}

fn intKindFromChanType(ct: ScalarChanType) IntKind {
    return switch (ct) {
        .i8_chan => .i8, .i16_chan => .i16, .i32_chan => .i32, .i64_chan => .i64, .i128_chan => .i128,
        .u8_chan => .u8, .u16_chan => .u16, .u32_chan => .u32, .u64_chan => .u64, .u128_chan => .u128,
        else => .i64,
    };
}

fn floatKindFromChanType(ct: ScalarChanType) FloatKind {
    return switch (ct) {
        .f16_chan => .f16, .f32_chan => .f32, .f64_chan => .f64, .f128_chan => .f128,
        else => .f64,
    };
}

/// 从 AST 类型节点映射到通道类型
fn mapTypeNode(type_node: ?*const ast.TypeNode) ?ScalarChanType {
    if (type_node == null) return null;
    const tn = type_node.?;
    return switch (tn.*) {
        .named => |n| mapNamedTypeToChan(n.name),
        .array => .ref_chan,
        .nullable => .nullable_chan,
        else => null,
    };
}

/// 从类型注解推断 ref_kind（用于方法分派）
fn mapTypeNodeToRefKind(type_node: ?*const ast.TypeNode) ?value.obj_header.RefKind {
    if (type_node == null) return null;
    const tn = type_node.?;
    return switch (tn.*) {
        .array => .array,
        .named => |n| blk: {
            if (std.mem.eql(u8, n.name, "str")) break :blk .str;
            break :blk null;
        },
        else => null,
    };
}

fn mapNamedTypeToChan(name: []const u8) ?ScalarChanType {
    if (std.mem.eql(u8, name, "i8")) return .i8_chan;
    if (std.mem.eql(u8, name, "i16")) return .i16_chan;
    if (std.mem.eql(u8, name, "i32")) return .i32_chan;
    if (std.mem.eql(u8, name, "i64")) return .i64_chan;
    if (std.mem.eql(u8, name, "i128")) return .i128_chan;
    if (std.mem.eql(u8, name, "u8")) return .u8_chan;
    if (std.mem.eql(u8, name, "u16")) return .u16_chan;
    if (std.mem.eql(u8, name, "u32")) return .u32_chan;
    if (std.mem.eql(u8, name, "u64")) return .u64_chan;
    if (std.mem.eql(u8, name, "u128")) return .u128_chan;
    if (std.mem.eql(u8, name, "f16")) return .f16_chan;
    if (std.mem.eql(u8, name, "f32")) return .f32_chan;
    if (std.mem.eql(u8, name, "f64")) return .f64_chan;
    if (std.mem.eql(u8, name, "f128")) return .f128_chan;
    if (std.mem.eql(u8, name, "bool")) return .bool_chan;
    if (std.mem.eql(u8, name, "char")) return .char_chan;
    if (std.mem.eql(u8, name, "str")) return .ref_chan;
    return null;
}

// ── E2: 自由变量分析 ──

/// 递归收集表达式中的自由变量名（标识符引用）
/// 排除 lambda 参数名和局部声明名
fn collectFreeVars(
    expr: *const ast.Expr,
    allocator: std.mem.Allocator,
    out: *std.StringHashMap(void),
) error{OutOfMemory}!void {
    switch (expr.*) {
        .identifier => |id| {
            try out.put(id.name, {});
        },

        .binary => |b| {
            try collectFreeVars(b.left, allocator, out);
            try collectFreeVars(b.right, allocator, out);
        },

        .unary => |u| {
            try collectFreeVars(u.operand, allocator, out);
        },

        .call => |c| {
            try collectFreeVars(c.callee, allocator, out);
            for (c.arguments) |arg| {
                try collectFreeVars(arg, allocator, out);
            }
        },

        .method_call => |mc| {
            try collectFreeVars(mc.object, allocator, out);
            for (mc.arguments) |arg| {
                try collectFreeVars(arg, allocator, out);
            }
        },

        .field_access => |fa| {
            try collectFreeVars(fa.object, allocator, out);
        },

        .safe_access => |sa| {
            try collectFreeVars(sa.object, allocator, out);
        },

        .safe_method_call => |smc| {
            try collectFreeVars(smc.object, allocator, out);
            for (smc.arguments) |arg| {
                try collectFreeVars(arg, allocator, out);
            }
        },

        .non_null_assert => |nn| {
            try collectFreeVars(nn.expr, allocator, out);
        },

        .propagate => |prop| {
            try collectFreeVars(prop.expr, allocator, out);
        },

        .index => |idx| {
            try collectFreeVars(idx.object, allocator, out);
            try collectFreeVars(idx.index, allocator, out);
        },

        .assignment_expr => |assign| {
            try collectFreeVars(assign.target, allocator, out);
            try collectFreeVars(assign.value, allocator, out);
        },

        .compound_assign => |ca| {
            try collectFreeVars(ca.target, allocator, out);
            try collectFreeVars(ca.value, allocator, out);
        },

        .if_expr => |ie| {
            try collectFreeVars(ie.condition, allocator, out);
            try collectFreeVars(ie.then_branch, allocator, out);
            if (ie.else_branch) |eb| try collectFreeVars(eb, allocator, out);
        },

        .block => |blk| {
            for (blk.statements) |stmt| {
                try collectFreeVarsStmt(stmt, allocator, out);
            }
            if (blk.trailing_expr) |te| try collectFreeVars(te, allocator, out);
        },

        .match => |m| {
            try collectFreeVars(m.scrutinee, allocator, out);
            for (m.arms) |arm| {
                // 模式绑定的变量不算自由变量
                try collectFreeVars(arm.body, allocator, out);
                if (arm.guard) |g| try collectFreeVars(g, allocator, out);
            }
        },

        .lambda => |lam| {
            // 嵌套 lambda：排除内层 lambda 的参数
            var inner_params = std.StringHashMap(void).init(allocator);
            defer inner_params.deinit();
            for (lam.params) |p| try inner_params.put(p.name, {});

            var inner_free = std.StringHashMap(void).init(allocator);
            defer inner_free.deinit();
            switch (lam.body) {
                .block => |b| try collectFreeVars(b, allocator, &inner_free),
                .expression => |e| try collectFreeVars(e, allocator, &inner_free),
            }

            // 内层 lambda 的自由变量中，不属于内层参数的是外层的自由变量
            var it = inner_free.iterator();
            while (it.next()) |entry| {
                if (!inner_params.contains(entry.key_ptr.*)) {
                    try out.put(entry.key_ptr.*, {});
                }
            }
        },

        .array_literal => |al| {
            for (al.elements) |elem| {
                try collectFreeVars(elem, allocator, out);
            }
        },

        .record_literal => |rl| {
            for (rl.fields) |field| {
                try collectFreeVars(field.value, allocator, out);
            }
        },

        .record_extend => |re| {
            try collectFreeVars(re.base, allocator, out);
            for (re.updates) |field| {
                try collectFreeVars(field.value, allocator, out);
            }
        },

        .type_cast => |tc| {
            try collectFreeVars(tc.expr, allocator, out);
        },

        .atomic_expr => |ae| {
            try collectFreeVars(ae.value, allocator, out);
        },

        .lazy => |lz| {
            try collectFreeVars(lz.expr, allocator, out);
        },

        .string_interpolation => |si| {
            for (si.parts) |part| {
                switch (part) {
                    .expression => |e| try collectFreeVars(e, allocator, out),
                    .literal => {},
                }
            }
        },

        // 无子表达式的字面量：不产生自由变量
        .int_literal, .float_literal, .bool_literal, .char_literal,
        .string_literal, .null_literal, .unit_literal,
        => {},

        // inline_trait_value 的方法体在轨道内单独编译，不在此收集
        .inline_trait_value => {},

        // select 的通道表达式和分支体可能引用自由变量
        .select => |sel| {
            for (sel.arms) |arm| {
                switch (arm) {
                    .receive => |r| {
                        try collectFreeVars(r.channel_expr, allocator, out);
                        try collectFreeVars(r.body, allocator, out);
                    },
                    .timeout => |t| {
                        try collectFreeVars(t.duration, allocator, out);
                        try collectFreeVars(t.body, allocator, out);
                    },
                }
            }
        },
    }
}

/// 语句中的自由变量收集
fn collectFreeVarsStmt(
    stmt: *const ast.Stmt,
    allocator: std.mem.Allocator,
    out: *std.StringHashMap(void),
) error{OutOfMemory}!void {
    switch (stmt.*) {
        .val_decl => |vd| {
            try collectFreeVars(vd.value, allocator, out);
            // 声明的变量名不算自由变量（在轨道内是局部变量）
            _ = out.remove(vd.name);
        },
        .var_decl => |vd| {
            try collectFreeVars(vd.value, allocator, out);
            _ = out.remove(vd.name);
        },
        .assignment => |assign| {
            try collectFreeVars(assign.target, allocator, out);
            try collectFreeVars(assign.value, allocator, out);
        },
        .field_assignment => |fa| {
            try collectFreeVars(fa.object, allocator, out);
            try collectFreeVars(fa.value, allocator, out);
        },
        .compound_assignment => |ca| {
            try collectFreeVars(ca.target, allocator, out);
            try collectFreeVars(ca.value, allocator, out);
        },
        .expression => |e| {
            try collectFreeVars(e.expr, allocator, out);
        },
        .return_stmt => |rs| {
            if (rs.value) |v| try collectFreeVars(v, allocator, out);
        },
        .defer_stmt => |ds| {
            try collectFreeVars(ds.expr, allocator, out);
        },
        .throw_stmt => |ts| {
            try collectFreeVars(ts.expr, allocator, out);
        },
        .for_stmt => |fs| {
            try collectFreeVars(fs.iterable, allocator, out);
            try collectFreeVars(fs.body, allocator, out);
            _ = out.remove(fs.name);
        },
        .while_stmt => |ws| {
            try collectFreeVars(ws.condition, allocator, out);
            try collectFreeVars(ws.body, allocator, out);
        },
        .loop_stmt => |ls| {
            try collectFreeVars(ls.body, allocator, out);
        },
        .break_stmt, .continue_stmt => {},
    }
}

// ──────────────────────────────────────────────
// 测试
// ──────────────────────────────────────────────

const testing = std.testing;

test "编译简单算术: 1 + 2" {
    // 构造 AST: 1 + 2
    // 由于需要完整 AST 结构，这里仅验证辅助函数
    try testing.expectEqual(IntKind.i32, parseIntKindFromSuffix("i32").?);
    try testing.expectEqual(FloatKind.f64, parseFloatKindFromSuffix("f64").?);
    try testing.expectEqual(ScalarChanType.i32_chan, mapNamedTypeToChan("i32").?);
    try testing.expectEqual(ScalarChanType.bool_chan, mapNamedTypeToChan("bool").?);
}
