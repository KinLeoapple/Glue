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
    /// async 函数/lambda 编译的子图列表
    subgraphs: std.ArrayList(LaminarGraph) = .empty,
    /// async 函数名 → 子图索引（在 compile 中初始化）
    async_func_map: std.StringHashMap(u16) = undefined,

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
            .func_table = std.StringHashMap(*const ast.Decl).init(a),
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

        // 第二遍：扫描所有 async 函数，编译为子图
        for (module.declarations) |decl| {
            switch (decl) {
                .fun_decl => |f| {
                    if (f.is_async) {
                        try self.compileAsyncSubgraph(f);
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
        const idx = self.channel_count;
        self.channel_count += 1;
        try self.channel_metas.append(self.arena.allocator(), .{
            .chan_type = chan_type,
            .elem_width = lamina_mod.chanElemWidth(chan_type),
        });
        // 记录通道归属层级
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
        const a = self.arena.allocator();
        // 固化轨道 lamina 序列（直接写入对应索引，避免嵌套轨道 LIFO 顺序错乱）
        const olams = try a.dupe(Lamina, self.laminas.items);
        self.orbit_laminas_list.items[orbit_idx] = olams;
        // 填充轨道构建信息
        self.orbit_build_infos.items[orbit_idx] = .{
            .output_channel = output_channel,
            .is_cyclic = is_cyclic,
            .continue_channel = continue_channel,
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

    // ── 表达式编译 ──

    fn compileExpr(self: *LaminarCompiler, expr: *const ast.Expr) CompileError!u16 {
        return switch (expr.*) {
            .int_literal => |lit| blk: {
                const value = std.fmt.parseInt(i64, lit.raw, 10) catch 0;
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
                    .const_val = value,
                    .int_kind = kind,
                    .input_count = 0,
                });
                break :blk chan;
            },

            .float_literal => |lit| blk: {
                const value = std.fmt.parseFloat(f64, lit.raw) catch 0;
                const kind: FloatKind = if (lit.suffix) |sfx|
                    parseFloatKindFromSuffix(sfx) orelse .f64
                else
                    .f64;
                const chan_type = lamina_mod.chanTypeFromFloatKind(kind);
                const chan = try self.allocChannel(chan_type);
                const bits: i64 = @bitCast(value);
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
                // `?` 操作符：编译内部表达式（应为 throw_val 或 ref_chan）
                const throw_chan = try self.compileExpr(prop.expr);
                // 发射 throw_propagate 层：如果 throw 是 err，则 halt_throw；否则 unwrap ok 值
                const out_chan = try self.allocChannel(.ref_chan);
                try self.emit(.{
                    .op = .throw_propagate,
                    .inputs = .{ throw_chan, 0, 0 },
                    .output = out_chan,
                    .ref_kind = .throw_val,
                    .input_count = 1,
                });
                break :blk out_chan;
            },

            // 阶段 5: lambda → closure_make（简化：func_idx=0，无捕获）
            .lambda => blk: {
                const out_chan = try self.allocChannel(.ref_chan);
                try self.emit(.{
                    .op = .closure_make,
                    .inputs = .{ 0, 0, 0 },
                    .output = out_chan,
                    .const_val = 0, // func_idx 占位（无函数表）
                    .ref_kind = .closure,
                    .input_count = 0, // 无捕获（简化）
                });
                break :blk out_chan;
            },

            // 阶段 5: inline_trait_value → trait_make（简化：固定 type_tag=0）
            .inline_trait_value => blk: {
                const out_chan = try self.allocChannel(.ref_chan);
                try self.emit(.{
                    .op = .trait_make,
                    .inputs = .{ 0, 0, 0 },
                    .output = out_chan,
                    .const_val = 0, // type_tag 占位
                    .ref_kind = .trait_val,
                    .input_count = 0,
                });
                break :blk out_chan;
            },

            // 阶段 5: match → switch_lamina（简化：单 arm 分派）
            .match => |m| try self.compileMatch(m),

            // 类型转换：type_cast(expr, target_type) → type_cast lamina
            .type_cast => |tc| blk: {
                const src_chan = try self.compileExpr(tc.expr);
                const dst_chan_type = mapTypeNode(tc.target_type) orelse {
                    // 未知目标类型，退化为 unit
                    break :blk try self.allocChannel(.unit_chan);
                };
                const dst_chan = try self.allocChannel(dst_chan_type);
                const dst_tag = lamina_mod.chanTypeToScalarTag(dst_chan_type) orelse {
                    break :blk dst_chan; // null/unit/mask/ref 无标量转换
                };
                try self.emit(.{
                    .op = .type_cast,
                    .inputs = .{ src_chan, 0, 0 },
                    .output = dst_chan,
                    .const_val = @intFromEnum(dst_tag),
                    .input_count = 1,
                });
                break :blk dst_chan;
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
            .bool_chan => return try self.compileBoolBinary(b.op, lhs_chan, rhs_chan),
            .char_chan => return try self.compileCharBinary(b.op, lhs_chan, rhs_chan),
            else => return try self.compileIntBinary(b.op, lhs_chan, rhs_chan, .i64),
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
                    .not => return error.UnsupportedExpr,
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
        // 分配输出通道（then 分支的类型）
        const result_type = self.channel_metas.items[then_result].chan_type;
        const out_chan = try self.allocChannel(result_type);
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

            // 第一个 arm 确定输出通道类型
            if (i == 0) {
                const result_type = self.channel_metas.items[arm_result].chan_type;
                out_chan = try self.allocChannel(result_type);
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
                                .ref_kind = .cell,
                                .input_count = 2,
                            });
                            break :blk val_chan;
                        }
                    }
                    // 非 Cell 变量 — 直接重绑定（val 语义）
                    try self.defineVar(assign.target.identifier.name, val_chan);
                }
                break :blk val_chan;
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

            if (std.mem.eql(u8, fn_name, "println")) {
                // println(arg) → debug_print(arg)
                if (c.arguments.len > 0) {
                    const arg_chan = try self.compileExpr(c.arguments[0]);
                    try self.emit(.{
                        .op = .debug_print,
                        .inputs = .{ arg_chan, 0, 0 },
                        .output = arg_chan,
                        .input_count = 1,
                    });
                }
                return try self.allocChannel(.unit_chan);
            }

            if (std.mem.eql(u8, fn_name, "print")) {
                // print(arg) → debug_print(arg)（阶段1不区分换行）
                if (c.arguments.len > 0) {
                    const arg_chan = try self.compileExpr(c.arguments[0]);
                    try self.emit(.{
                        .op = .debug_print,
                        .inputs = .{ arg_chan, 0, 0 },
                        .output = arg_chan,
                        .input_count = 1,
                    });
                }
                return try self.allocChannel(.unit_chan);
            }

            // 检查是否为 async 函数调用
            if (self.async_func_map.get(fn_name)) |func_idx| {
                // 编译参数通道
                var arg_chans: [3]u16 = .{ 0, 0, 0 };
                const n_args = @min(c.arguments.len, 3);
                for (0..n_args) |i| {
                    arg_chans[i] = try self.compileExpr(c.arguments[i]);
                }
                // async_create：输出 Async 句柄（ref_chan 存 *LfeTask 指针）
                const out_chan = try self.allocChannel(.ref_chan);
                try self.emit(.{
                    .op = .async_create,
                    .inputs = arg_chans,
                    .output = out_chan,
                    .extern_idx = func_idx,
                    .input_count = @intCast(n_args),
                });
                return out_chan;
            }

            // 检查是否为 atomic 构造
            if (std.mem.eql(u8, fn_name, "atomic")) {
                // atomic(value) → atomic_make
                const arg_chan = if (c.arguments.len > 0)
                    try self.compileExpr(c.arguments[0])
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
            }

            // 检查是否为 channel 构造
            if (std.mem.eql(u8, fn_name, "channel")) {
                // channel(capacity) → channel_make
                const cap: i64 = if (c.arguments.len > 0 and c.arguments[0].* == .int_literal) blk: {
                    const lit = c.arguments[0].int_literal;
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
            }
        }

        // 检查是否为已知 Glue 函数（非 async、非内置）
        if (c.callee.* == .identifier) {
            const fn_name = c.callee.identifier.name;
            if (self.func_table.get(fn_name)) |func_decl| {
                return try self.compileFunctionCall(func_decl, c.arguments);
            }
        }

        // 通用函数调用：编译参数，发射 extern_call
        var arg_chans = std.ArrayList(u16).empty;
        defer arg_chans.deinit(self.arena.allocator());
        for (c.arguments) |arg| {
            try arg_chans.append(self.arena.allocator(), try self.compileExpr(arg));
        }

        const out_chan = try self.allocChannel(.i64_chan);
        const first_arg: u16 = if (arg_chans.items.len > 0) arg_chans.items[0] else 0;

        try self.emit(.{
            .op = .extern_call,
            .inputs = .{ first_arg, 0, 0 },
            .output = out_chan,
            .input_count = 1,
        });
        return out_chan;
    }

    // ── 函数调用编译（C2：递归 + 内联）──

    /// 编译对已知 Glue 函数的调用
    /// 递归深度 ≤ 3 层内联为轨道，超过则发射 extern_call
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

        // 递归深度超限：回退到 extern_call
        if (self.recursion_depth >= 3) {
            const out_chan = try self.allocChannel(.i64_chan);
            const first_arg: u16 = if (arguments.len > 0)
                try self.compileExpr(arguments[0])
            else
                0;
            try self.emit(.{
                .op = .extern_call,
                .inputs = .{ first_arg, 0, 0 },
                .output = out_chan,
                .input_count = 1,
            });
            return out_chan;
        }

        // 1. 编译参数到通道（在父层/当前层）
        const arg_chans = try a.alloc(u16, arguments.len);
        for (arguments, 0..) |arg, i| {
            arg_chans[i] = try self.compileExpr(arg);
        }

        // 2. 分配太阳层返回通道 out_chan（父层持有，orbit_hub 的 output）
        const ret_type = if (func_decl.return_type) |rt|
            mapTypeNode(rt) orelse .i64_chan
        else
            .i64_chan;
        const out_chan = try self.allocChannel(ret_type);

        // 3. 创建同步轨道
        const call_orbit = try self.beginOrbit();
        try self.pushScope();

        // 4. 绑定参数：分配轨道内 param_chan，记录 param_mapping（桥接），
        //    不在轨道内 emit 参数 move——参数由 execOrbitHub 在 runOrbit 前复制
        const param_mapping = try a.alloc(ParamBind, func_decl.params.len);
        for (func_decl.params, 0..) |param, i| {
            const chan_type = mapTypeNode(param.type_annotation) orelse .i64_chan;
            const param_chan = try self.allocChannel(chan_type);
            param_mapping[i] = .{
                .src = if (i < arg_chans.len) arg_chans[i] else 0,
                .dst = param_chan,
            };
            try self.defineVar(param.name, param_chan);
        }

        // 5. 分配轨道内返回通道，设置返回上下文
        const ret_chan = try self.allocChannel(ret_type);
        const saved_return_channel = self.current_return_channel;
        self.current_return_channel = ret_chan;
        self.recursion_depth += 1;

        // 6. 编译函数体
        const body_result = try self.compileExpr(func_decl.body);

        // 7. 尾表达式 fallback：move 到返回通道（轨道内，不跨层）
        try self.emit(.{
            .op = .move,
            .inputs = .{ body_result, 0, 0 },
            .output = ret_chan,
            .input_count = 1,
        });

        // 8. 恢复上下文
        self.recursion_depth -= 1;
        self.current_return_channel = saved_return_channel;
        self.popScope();

        // 9. 固化轨道（output_channel = 轨道内 ret_chan）
        try self.endOrbit(call_orbit, ret_chan, false, null);

        // 10. 创建 OrbitHub：param_mapping 桥接参数，output_channel = 太阳层 out_chan
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

    // ── 方法调用编译 ──

    fn compileMethodCall(self: *LaminarCompiler, mc: anytype) CompileError!u16 {
        const obj_chan = try self.compileExpr(mc.object);

        if (std.mem.eql(u8, mc.method, "println")) {
            try self.emit(.{
                .op = .debug_print,
                .inputs = .{ obj_chan, 0, 0 },
                .output = obj_chan,
                .input_count = 1,
            });
            return try self.allocChannel(.unit_chan);
        }

        // async 任务方法
        if (std.mem.eql(u8, mc.method, "await")) {
            // async.await() → async_join
            const out_chan = try self.allocChannel(.i64_chan);
            try self.emit(.{
                .op = .async_join,
                .inputs = .{ obj_chan, 0, 0 },
                .output = out_chan,
                .input_count = 1,
            });
            return out_chan;
        }
        if (std.mem.eql(u8, mc.method, "status")) {
            // async.status() → async_status
            const out_chan = try self.allocChannel(.u8_chan);
            try self.emit(.{
                .op = .async_status,
                .inputs = .{ obj_chan, 0, 0 },
                .output = out_chan,
                .input_count = 1,
            });
            return out_chan;
        }

        // atomic 方法
        if (std.mem.eql(u8, mc.method, "load")) {
            const out_chan = try self.allocChannel(.i64_chan);
            try self.emit(.{
                .op = .atomic_load,
                .inputs = .{ obj_chan, 0, 0 },
                .output = out_chan,
                .input_count = 1,
            });
            return out_chan;
        }
        if (std.mem.eql(u8, mc.method, "store")) {
            // 需要一个参数：新值
            if (mc.arguments.len > 0) {
                const val_chan = try self.compileExpr(mc.arguments[0]);
                const out_chan = try self.allocChannel(.unit_chan);
                try self.emit(.{
                    .op = .atomic_store,
                    .inputs = .{ obj_chan, val_chan, 0 },
                    .output = out_chan,
                    .input_count = 2,
                });
                return out_chan;
            }
            return try self.allocChannel(.unit_chan);
        }
        if (std.mem.eql(u8, mc.method, "swap")) {
            if (mc.arguments.len > 0) {
                const val_chan = try self.compileExpr(mc.arguments[0]);
                const out_chan = try self.allocChannel(.i64_chan);
                try self.emit(.{
                    .op = .atomic_swap,
                    .inputs = .{ obj_chan, val_chan, 0 },
                    .output = out_chan,
                    .input_count = 2,
                });
                return out_chan;
            }
            return try self.allocChannel(.i64_chan);
        }
        if (std.mem.eql(u8, mc.method, "compare_swap")) {
            // compare_swap(expected, desired)
            if (mc.arguments.len >= 2) {
                const exp_chan = try self.compileExpr(mc.arguments[0]);
                const des_chan = try self.compileExpr(mc.arguments[1]);
                const out_chan = try self.allocChannel(.u8_chan);
                try self.emit(.{
                    .op = .atomic_cas,
                    .inputs = .{ obj_chan, exp_chan, des_chan },
                    .output = out_chan,
                    .input_count = 3,
                });
                return out_chan;
            }
            return try self.allocChannel(.u8_chan);
        }

        // channel 方法
        if (std.mem.eql(u8, mc.method, "send")) {
            if (mc.arguments.len > 0) {
                const val_chan = try self.compileExpr(mc.arguments[0]);
                const out_chan = try self.allocChannel(.u8_chan);
                try self.emit(.{
                    .op = .channel_send,
                    .inputs = .{ obj_chan, val_chan, 0 },
                    .output = out_chan,
                    .input_count = 2,
                });
                return out_chan;
            }
            return try self.allocChannel(.u8_chan);
        }
        if (std.mem.eql(u8, mc.method, "recv")) {
            const out_chan = try self.allocChannel(.i64_chan);
            try self.emit(.{
                .op = .channel_recv,
                .inputs = .{ obj_chan, 0, 0 },
                .output = out_chan,
                .input_count = 1,
            });
            return out_chan;
        }
        if (std.mem.eql(u8, mc.method, "tryRecv")) {
            const out_chan = try self.allocChannel(.i64_chan);
            try self.emit(.{
                .op = .channel_try_recv,
                .inputs = .{ obj_chan, 0, 0 },
                .output = out_chan,
                .input_count = 1,
            });
            return out_chan;
        }
        if (std.mem.eql(u8, mc.method, "close")) {
            const out_chan = try self.allocChannel(.unit_chan);
            try self.emit(.{
                .op = .channel_close,
                .inputs = .{ obj_chan, 0, 0 },
                .output = out_chan,
                .input_count = 1,
            });
            return out_chan;
        }
        if (std.mem.eql(u8, mc.method, "sender")) {
            const out_chan = try self.allocChannel(.ref_chan);
            try self.emit(.{
                .op = .channel_get_sender,
                .inputs = .{ obj_chan, 0, 0 },
                .output = out_chan,
                .input_count = 1,
            });
            return out_chan;
        }
        if (std.mem.eql(u8, mc.method, "receiver")) {
            const out_chan = try self.allocChannel(.ref_chan);
            try self.emit(.{
                .op = .channel_get_receiver,
                .inputs = .{ obj_chan, 0, 0 },
                .output = out_chan,
                .input_count = 1,
            });
            return out_chan;
        }

        // 通用方法调用
        const out_chan = try self.allocChannel(.i64_chan);
        try self.emit(.{
            .op = .extern_call,
            .inputs = .{ obj_chan, 0, 0 },
            .output = out_chan,
            .input_count = 1,
        });
        return out_chan;
    }

    // ── 赋值表达式编译 ──

    fn compileAssignment(self: *LaminarCompiler, assign: anytype) CompileError!u16 {
        const val_chan = try self.compileExpr(assign.value);
        if (assign.target.* == .identifier) {
            try self.defineVar(assign.target.identifier.name, val_chan);
        }
        return val_chan;
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
