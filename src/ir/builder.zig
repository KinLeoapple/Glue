//! Glue IR 图构建器
//!
//! 从 AST 构建 GlueIR（共享内存图）。这是前端（parse + sema）的核心产物。
//! 设计参考：docs/glue-ir-design.md 第 4 章前端设计
//!
//! Phase 1 覆盖：
//!   - 标量表达式：字面量、变量、算术、位运算、比较、一元
//!   - 基础控制流：block、val/var 声明、return、函数调用
//! 后续 Phase：if/match（vec_select）、for/while（vec_source/map）、? 传播（gate）等

const std = @import("std");
const ast = @import("ast");
const scalar = @import("value").scalar;
const node_mod = @import("node.zig");
const meta_mod = @import("meta.zig");
const channel_mod = @import("channel.zig");
const ir_mod = @import("ir.zig");

pub const Node = node_mod.Node;
pub const NodeOp = node_mod.NodeOp;
pub const ScalarMeta = meta_mod.ScalarMeta;
pub const ScalarKind = meta_mod.ScalarKind;
pub const ConstVal = meta_mod.ConstVal;
pub const CallMeta = meta_mod.CallMeta;
pub const Function = meta_mod.Function;
pub const VectorMeta = meta_mod.VectorMeta;
pub const VecOp = meta_mod.VecOp;
pub const GateMeta = meta_mod.GateMeta;
pub const GateKind = meta_mod.GateKind;
pub const RouteMeta = meta_mod.RouteMeta;
pub const RaceMeta = meta_mod.RaceMeta;
pub const CleanupMeta = meta_mod.CleanupMeta;
pub const OrbitMeta = meta_mod.OrbitMeta;
pub const LoopMeta = meta_mod.LoopMeta;
pub const ClosureMeta = meta_mod.ClosureMeta;
pub const LoopKind = meta_mod.LoopKind;
pub const HaltKind = meta_mod.HaltKind;
pub const ChanType = channel_mod.ChanType;
pub const ChannelSpace = channel_mod.ChannelSpace;
pub const GlueIR = ir_mod.GlueIR;
pub const IntKind = scalar.IntKind;
pub const FloatKind = scalar.FloatKind;

/// 图构建错误
pub const BuildError = error{
    OutOfMemory,
    UnsupportedExpr,
    UnsupportedStmt,
    UnsupportedDecl,
    UnsupportedType,
    InvalidLiteral,
    UnboundVariable,
    UndefinedFunction,
};

/// 变量绑定
const VarBinding = struct {
    name: []const u8,
    chan: u16, // 通道索引
    is_cell: bool, // var 变量是 Cell（可变）
    ast_expr: ?*const ast.Expr = null, // 用于类型推断的 AST 表达式
};

/// 作用域
const Scope = struct {
    bindings: std.ArrayList(VarBinding),
};

/// 构造器字段信息
const CtorField = struct {
    name: []const u8, // 位置参数合成名 _0, _1, ...；命名字段用原名
    type_node: ?*ast.TypeNode,
};

/// 构造器信息
const CtorInfo = struct {
    name: []const u8, // 构造器名
    type_name: []const u8, // 所属类型名
    tag: u8, // 在类型构造器列表中的索引（用于 match 分派）
    fields: []const CtorField, // 字段列表
    is_newtype: bool = false, // 是否为 newtype 构造器
};

/// 类型信息
const TypeInfo = struct {
    name: []const u8,
    kind: enum { adt, record, alias, newtype, error_newtype },
    constructors: []const CtorInfo, // ADT/newtype 的构造器列表
};

/// Trait 方法签名
const TraitMethodSig = struct {
    name: []const u8,
    param_count: u8,
    return_type: ?*ast.TypeNode,
};

/// Trait 信息
const TraitInfo = struct {
    name: []const u8,
    methods: []const TraitMethodSig,
};

/// IR 构建器：从 AST 构建 GlueIR
pub const IRBuilder = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,

    nodes: std.ArrayList(Node),
    scalar_metas: std.ArrayList(ScalarMeta),
    call_metas: std.ArrayList(CallMeta),
    vector_metas: std.ArrayList(VectorMeta),
    gate_metas: std.ArrayList(GateMeta),
    route_metas: std.ArrayList(RouteMeta),
    race_metas: std.ArrayList(RaceMeta),
    cleanup_metas: std.ArrayList(CleanupMeta),
    orbit_metas: std.ArrayList(OrbitMeta),
    loop_metas: std.ArrayList(LoopMeta),
    closure_metas: std.ArrayList(ClosureMeta),
    functions: std.ArrayList(Function),
    string_pool: std.ArrayList([]const u8),
    channels: ChannelSpace,

    scope_stack: std.ArrayList(Scope),
    func_table: std.StringHashMap(u16), // 函数名 -> 函数索引
    type_table: std.StringHashMap(TypeInfo), // 类型名 -> 类型信息
    ctor_table: std.StringHashMap(CtorInfo), // 构造器名 -> 构造器信息
    trait_table: std.StringHashMap(TraitInfo), // trait 名 -> trait 信息

    current_return_chan: ?u16 = null,
    /// lambda 计数器（生成匿名函数名 __lambda_N）
    lambda_counter: u32 = 0,
    /// 预声明 lambda 名栈（支持递归 lambda：val go = fun(...) { go(...) }）
    /// 在 val_decl 编译 lambda 前 push 名字，compileLambda 读取并预绑定到输出通道
    pre_declared_lambda_names: std.ArrayList([]const u8) = .empty,
    /// arena 所有权标志：build() 成功后转交给 GlueIR，置为 false
    arena_owned: bool = true,

    /// 初始化构建器
    pub fn init(allocator: std.mem.Allocator) !IRBuilder {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        var builder = IRBuilder{
            .allocator = allocator,
            .arena = arena,
            .nodes = .empty,
            .scalar_metas = .empty,
            .call_metas = .empty,
            .vector_metas = .empty,
            .gate_metas = .empty,
            .route_metas = .empty,
            .race_metas = .empty,
            .cleanup_metas = .empty,
            .orbit_metas = .empty,
            .loop_metas = .empty,
            .closure_metas = .empty,
            .functions = .empty,
            .string_pool = .empty,
            .channels = ChannelSpace.init(arena.allocator()),
            .scope_stack = .empty,
            .func_table = std.StringHashMap(u16).init(allocator),
            .type_table = std.StringHashMap(TypeInfo).init(allocator),
            .ctor_table = std.StringHashMap(CtorInfo).init(allocator),
            .trait_table = std.StringHashMap(TraitInfo).init(allocator),
        };
        // meta_index=0 保留为"无元数据"占位
        try builder.scalar_metas.append(arena.allocator(), .{ .kind = .unit });
        return builder;
    }

    /// 释放构建器资源（不释放产出的 IR，IR 由 GlueIR.deinit 管理）
    /// 注意：build() 成功后 arena 所有权转交给 GlueIR，此函数不再释放 arena
    pub fn deinit(self: *IRBuilder) void {
        self.scope_stack.deinit(self.allocator);
        self.func_table.deinit();
        self.type_table.deinit();
        self.ctor_table.deinit();
        self.trait_table.deinit();
        self.pre_declared_lambda_names.deinit(self.allocator);
        if (self.arena_owned) {
            self.arena.deinit();
            self.allocator.destroy(self.arena);
            self.arena_owned = false;
        }
    }

    /// 构建完整 IR：遍历模块声明，编译所有函数
    pub fn build(self: *IRBuilder, module: ast.Module) BuildError!GlueIR {
        const arena_alloc = self.arena.allocator();

        // 第一遍：注册所有函数名 + 预分配 Function 占位条目
        // 同时注册 type_decl（类型+构造器）和 trait_decl
        // 占位条目包含 is_async/return_type 信息，供 compileCall 在被调用函数尚未编译时查询
        var func_count: u16 = 0;
        for (module.declarations) |decl| {
            switch (decl) {
                .fun_decl => |fd| {
                    try self.func_table.put(fd.name, func_count);
                    // 预分配占位 Function：返回通道暂为 0，编译时更新
                    const return_type = chanTypeFromTypeNode(fd.return_type) orelse .i64_chan;
                    const placeholder_return_chan = try self.allocChannel(return_type);
                    try self.functions.append(arena_alloc, .{
                        .name = fd.name,
                        .node_start = 0,
                        .node_count = 0,
                        .param_channels = &.{},
                        .return_channel = placeholder_return_chan,
                        .is_entry = fd.is_entry,
                        .is_async = fd.is_async,
                    });
                    func_count += 1;
                },
                .type_decl => |td| try self.registerTypeDecl(td, arena_alloc, &func_count),
                .trait_decl => |trd| try self.registerTraitDecl(trd, arena_alloc),
                else => {},
            }
        }

        // 第二遍：编译每个函数（更新占位条目的 node_start/node_count/param_channels）
        var entry_idx: u16 = 0;
        for (module.declarations) |decl| {
            switch (decl) {
                .fun_decl => |fd| {
                    // 通过函数名查找正确的 func_idx（type_decl 方法也会占用 func_table）
                    const idx = self.func_table.get(fd.name) orelse return error.UndefinedFunction;
                    _ = try self.compileFunction(fd, idx);
                    if (fd.is_entry) entry_idx = idx;
                },
                .type_decl => |td| try self.compileTypeMethods(td),
                else => {},
            }
        }

        // 组装 IR（arena 所有权转交给 GlueIR）
        self.arena_owned = false;
        return GlueIR{
            .nodes = try self.nodes.toOwnedSlice(arena_alloc),
            .scalar_metas = try self.scalar_metas.toOwnedSlice(arena_alloc),
            .call_metas = try self.call_metas.toOwnedSlice(arena_alloc),
            .vector_metas = try self.vector_metas.toOwnedSlice(arena_alloc),
            .gate_metas = try self.gate_metas.toOwnedSlice(arena_alloc),
            .route_metas = try self.route_metas.toOwnedSlice(arena_alloc),
            .race_metas = try self.race_metas.toOwnedSlice(arena_alloc),
            .cleanup_metas = try self.cleanup_metas.toOwnedSlice(arena_alloc),
            .orbit_metas = try self.orbit_metas.toOwnedSlice(arena_alloc),
            .loop_metas = try self.loop_metas.toOwnedSlice(arena_alloc),
            .closure_metas = try self.closure_metas.toOwnedSlice(arena_alloc),
            .functions = try self.functions.toOwnedSlice(arena_alloc),
            .string_pool = try self.string_pool.toOwnedSlice(arena_alloc),
            .channels = self.channels,
            .entry_index = entry_idx,
            .arena = self.arena,
            .backing = self.allocator,
        };
    }

    // ════════════════════════════════════════════
    // 通道与元数据分配
    // ════════════════════════════════════════════

    fn allocChannel(self: *IRBuilder, chan_type: ChanType) !u16 {
        return self.channels.alloc(chan_type);
    }

    fn allocCellChannel(self: *IRBuilder, chan_type: ChanType) !u16 {
        return self.channels.allocCell(chan_type);
    }

    /// 添加标量元数据，返回 1-based meta_index
    fn addScalarMeta(self: *IRBuilder, meta: ScalarMeta) !u16 {
        try self.scalar_metas.append(self.arena.allocator(), meta);
        return @intCast(self.scalar_metas.items.len - 1); // 0 是占位，从 1 开始
    }

    /// 添加调用元数据，返回 1-based meta_index
    fn addCallMeta(self: *IRBuilder, meta: CallMeta) !u16 {
        try self.call_metas.append(self.arena.allocator(), meta);
        return @intCast(self.call_metas.items.len);
    }

    /// 添加向量元数据，返回 1-based meta_index
    fn addVectorMeta(self: *IRBuilder, meta: VectorMeta) !u16 {
        try self.vector_metas.append(self.arena.allocator(), meta);
        return @intCast(self.vector_metas.items.len);
    }

    /// 添加门控元数据，返回 1-based meta_index
    fn addGateMeta(self: *IRBuilder, meta: GateMeta) !u16 {
        try self.gate_metas.append(self.arena.allocator(), meta);
        return @intCast(self.gate_metas.items.len);
    }

    /// 添加路由元数据，返回 1-based meta_index
    fn addRouteMeta(self: *IRBuilder, meta: RouteMeta) !u16 {
        try self.route_metas.append(self.arena.allocator(), meta);
        return @intCast(self.route_metas.items.len);
    }

    /// 添加竞争元数据，返回 1-based meta_index
    fn addRaceMeta(self: *IRBuilder, meta: RaceMeta) !u16 {
        try self.race_metas.append(self.arena.allocator(), meta);
        return @intCast(self.race_metas.items.len);
    }

    /// 添加清理元数据，返回 1-based meta_index
    fn addCleanupMeta(self: *IRBuilder, meta: CleanupMeta) !u16 {
        try self.cleanup_metas.append(self.arena.allocator(), meta);
        return @intCast(self.cleanup_metas.items.len);
    }

    /// 添加星轨元数据，返回 1-based meta_index
    fn addOrbitMeta(self: *IRBuilder, meta: OrbitMeta) !u16 {
        try self.orbit_metas.append(self.arena.allocator(), meta);
        return @intCast(self.orbit_metas.items.len);
    }

    /// 添加循环元数据，返回 1-based meta_index
    fn addLoopMeta(self: *IRBuilder, meta: LoopMeta) !u16 {
        try self.loop_metas.append(self.arena.allocator(), meta);
        return @intCast(self.loop_metas.items.len);
    }

    /// 添加闭包元数据，返回 1-based meta_index
    fn addClosureMeta(self: *IRBuilder, meta: ClosureMeta) !u16 {
        try self.closure_metas.append(self.arena.allocator(), meta);
        return @intCast(self.closure_metas.items.len);
    }

    /// 检测 AST 表达式或语句中是否含 break/continue
    fn containsBreakOrContinue(self: *IRBuilder, expr: *const ast.Expr) bool {
        _ = self;
        return astContainsBreakOrContinueExpr(expr);
    }

    /// 检测语句列表中是否含 break/continue
    fn stmtsContainBreakOrContinue(self: *IRBuilder, stmts: []const *ast.Stmt) bool {
        _ = self;
        for (stmts) |s| {
            if (astContainsBreakOrContinueStmt(s)) return true;
        }
        return false;
    }

    fn emit(self: *IRBuilder, node: Node) !void {
        try self.nodes.append(self.arena.allocator(), node);
    }

    // ════════════════════════════════════════════
    // 作用域管理
    // ════════════════════════════════════════════

    fn pushScope(self: *IRBuilder) !void {
        try self.scope_stack.append(self.allocator, .{ .bindings = .empty });
    }

    fn popScope(self: *IRBuilder) void {
        if (self.scope_stack.pop()) |scope| {
            var s = scope;
            s.bindings.deinit(self.allocator);
        }
    }

    fn defineVar(self: *IRBuilder, name: []const u8, chan: u16, is_cell: bool) !void {
        try self.scopeVar(name, chan, is_cell, null);
    }

    fn scopeVar(self: *IRBuilder, name: []const u8, chan: u16, is_cell: bool, ast_expr: ?*const ast.Expr) !void {
        try self.scope_stack.items[self.scope_stack.items.len - 1].bindings.append(
            self.allocator,
            .{ .name = name, .chan = chan, .is_cell = is_cell, .ast_expr = ast_expr },
        );
    }

    fn lookupVar(self: *IRBuilder, name: []const u8) ?VarBinding {
        var i: usize = self.scope_stack.items.len;
        while (i > 0) {
            i -= 1;
            for (self.scope_stack.items[i].bindings.items) |b| {
                if (std.mem.eql(u8, b.name, name)) return b;
            }
        }
        return null;
    }

    /// 更新已有绑定的 ast_expr 字段（用于预声明 lambda 后补充类型推断信息）
    fn updateVarAstExpr(self: *IRBuilder, name: []const u8, ast_expr: *const ast.Expr) void {
        var i: usize = self.scope_stack.items.len;
        while (i > 0) {
            i -= 1;
            for (self.scope_stack.items[i].bindings.items) |*b| {
                if (std.mem.eql(u8, b.name, name)) {
                    b.ast_expr = ast_expr;
                    return;
                }
            }
        }
    }

    // ════════════════════════════════════════════
    // 类型/Trait 注册（P0-b）
    // ════════════════════════════════════════════

    /// 注册 type_decl：注册类型名、构造器、方法
    fn registerTypeDecl(self: *IRBuilder, td: anytype, arena_alloc: std.mem.Allocator, func_count: *u16) BuildError!void {
        switch (td.def) {
            .adt => |adt| {
                // 为每个构造器合成字段信息
                const ctors = try arena_alloc.alloc(CtorInfo, adt.constructors.len);
                for (adt.constructors, 0..) |cdef, idx| {
                    const fields = try arena_alloc.alloc(CtorField, cdef.fields.len);
                    for (cdef.fields, 0..) |cf, fi| {
                        fields[fi] = .{
                            .name = cf.name orelse try std.fmt.allocPrint(arena_alloc, "_{d}", .{fi}),
                            .type_node = cf.ty,
                        };
                    }
                    ctors[idx] = .{
                        .name = cdef.name,
                        .type_name = td.name,
                        .tag = @intCast(idx),
                        .fields = fields,
                    };
                    try self.ctor_table.put(cdef.name, ctors[idx]);
                }
                try self.type_table.put(td.name, .{
                    .name = td.name,
                    .kind = .adt,
                    .constructors = ctors,
                });
            },
            .newtype => |nt| {
                // Newtype：单字段构造器，构造器名 = newtype name
                const fields = try arena_alloc.alloc(CtorField, 1);
                fields[0] = .{ .name = "_0", .type_node = nt.inner };
                const ctor = CtorInfo{
                    .name = nt.name,
                    .type_name = td.name,
                    .tag = 0,
                    .fields = fields,
                    .is_newtype = true,
                };
                try self.ctor_table.put(nt.name, ctor);
                const ctors = try arena_alloc.alloc(CtorInfo, 1);
                ctors[0] = ctor;
                try self.type_table.put(td.name, .{
                    .name = td.name,
                    .kind = .newtype,
                    .constructors = ctors,
                });
            },
            .error_newtype => |en| {
                // Error newtype：构造器名 = error_newtype name，参数来自 params
                const fields = try arena_alloc.alloc(CtorField, en.params.len);
                for (en.params, 0..) |p, fi| {
                    fields[fi] = .{
                        .name = try std.fmt.allocPrint(arena_alloc, "_{d}", .{fi}),
                        .type_node = p.type_annotation,
                    };
                }
                const ctor = CtorInfo{
                    .name = en.name,
                    .type_name = td.name,
                    .tag = 0,
                    .fields = fields,
                };
                try self.ctor_table.put(en.name, ctor);
                const ctors = try arena_alloc.alloc(CtorInfo, 1);
                ctors[0] = ctor;
                try self.type_table.put(td.name, .{
                    .name = td.name,
                    .kind = .error_newtype,
                    .constructors = ctors,
                });
            },
            .record => {
                // Record 类型：无构造器，使用 record_literal 创建
                try self.type_table.put(td.name, .{
                    .name = td.name,
                    .kind = .record,
                    .constructors = &.{},
                });
            },
            .alias => {
                // 类型别名：无构造器
                try self.type_table.put(td.name, .{
                    .name = td.name,
                    .kind = .alias,
                    .constructors = &.{},
                });
            },
        }

        // 注册方法为函数（方法名 mangle 为 "TypeName.method_name"）
        for (td.methods) |method| {
            if (method.body == null) continue; // trait 声明中的方法无体，跳过
            const mangled = try std.fmt.allocPrint(arena_alloc, "{s}.{s}", .{ td.name, method.name });
            try self.func_table.put(mangled, func_count.*);
            const return_type = chanTypeFromTypeNode(method.return_type) orelse .i64_chan;
            const placeholder_return_chan = try self.allocChannel(return_type);
            try self.functions.append(arena_alloc, .{
                .name = mangled,
                .node_start = 0,
                .node_count = 0,
                .param_channels = &.{},
                .return_channel = placeholder_return_chan,
                .is_entry = false,
                .is_async = false,
            });
            func_count.* += 1;
        }
    }

    /// 注册 trait_decl：记录 trait 名和方法签名
    fn registerTraitDecl(self: *IRBuilder, trd: anytype, arena_alloc: std.mem.Allocator) BuildError!void {
        const methods = try arena_alloc.alloc(TraitMethodSig, trd.methods.len);
        for (trd.methods, 0..) |m, i| {
            methods[i] = .{
                .name = m.name,
                .param_count = @intCast(m.params.len),
                .return_type = m.return_type,
            };
        }
        try self.trait_table.put(trd.name, .{
            .name = trd.name,
            .methods = methods,
        });
    }

    /// 编译 type_decl 的方法体（第二遍）
    fn compileTypeMethods(self: *IRBuilder, td: anytype) BuildError!void {
        const arena_alloc = self.arena.allocator();
        for (td.methods) |method| {
            if (method.body == null) continue;
            const mangled = try std.fmt.allocPrint(arena_alloc, "{s}.{s}", .{ td.name, method.name });
            const func_idx = self.func_table.get(mangled) orelse continue;

            // 构造等价的 fun_decl 结构来复用 compileFunction（compileFunction 用 anytype）
            const fd = .{
                .params = method.params,
                .body = method.body.?,
            };
            _ = try self.compileFunction(fd, func_idx);
        }
    }

    // ════════════════════════════════════════════
    // 函数编译
    // ════════════════════════════════════════════

    fn compileFunction(self: *IRBuilder, fd: anytype, func_idx: u16) BuildError!u16 {
        const node_start: u32 = @intCast(self.nodes.items.len);
        const chan_start: u16 = self.channels.count();

        try self.pushScope();
        defer self.popScope();

        // 分配参数通道
        const arena_alloc = self.arena.allocator();
        var param_channels = try arena_alloc.alloc(u16, fd.params.len);
        for (fd.params, 0..) |param, i| {
            // 支持 nullable 类型参数：T? → nullable_chan
            const chan = if (param.type_annotation) |tn| switch (tn.*) {
                .nullable => |nb| try self.channels.allocNullable(chanTypeFromTypeNode(nb.inner) orelse .i64_chan),
                else => try self.allocChannel(chanTypeFromTypeNode(tn) orelse .i64_chan),
            } else try self.allocChannel(.i64_chan);
            param_channels[i] = chan;
            try self.defineVar(param.name, chan, false);
        }

        // 使用第一遍预分配的返回通道（保证 compileCall 引用的是最终通道）
        const return_chan = self.functions.items[func_idx].return_channel;
        self.current_return_chan = return_chan;

        // 编译函数体
        const body_chan = try self.compileExpr(fd.body);

        // 发射 halt_return
        try self.emit(Node.makeUnary(.halt_return, return_chan, 0, body_chan));

        const node_count: u32 = @intCast(self.nodes.items.len - node_start);
        const chan_end: u16 = self.channels.count();
        // 更新占位条目（保留第一遍设置的 return_channel/is_entry/is_async）
        self.functions.items[func_idx].node_start = node_start;
        self.functions.items[func_idx].node_count = node_count;
        self.functions.items[func_idx].param_channels = param_channels;
        self.functions.items[func_idx].local_chan_start = chan_start;
        self.functions.items[func_idx].local_chan_count = chan_end - chan_start;

        self.current_return_chan = null;
        return func_idx;
    }

    // ════════════════════════════════════════════
    // 表达式编译
    // ════════════════════════════════════════════

    fn compileExpr(self: *IRBuilder, expr: *const ast.Expr) BuildError!u16 {
        switch (expr.*) {
            .int_literal => |il| return self.compileIntLiteral(il.raw, il.suffix),
            .float_literal => |fl| return self.compileFloatLiteral(fl.raw, fl.suffix),
            .bool_literal => |bl| {
                const out = try self.allocChannel(.bool_chan);
                const meta_idx = try self.addScalarMeta(.{
                    .kind = .bool,
                    .const_val = .{ .bool_val = bl.value },
                });
                try self.emit(Node.makeSink(.const_bool, out, meta_idx));
                return out;
            },
            .char_literal => |cl| {
                const out = try self.allocChannel(.char_chan);
                const meta_idx = try self.addScalarMeta(.{
                    .kind = .char,
                    .const_val = .{ .char_val = cl.value },
                });
                try self.emit(Node.makeSink(.const_char, out, meta_idx));
                return out;
            },
            .null_literal => {
                const out = try self.allocChannel(.null_chan);
                try self.emit(Node.makeSink(.const_null, out, 0));
                return out;
            },
            .unit_literal => {
                const out = try self.allocChannel(.unit_chan);
                try self.emit(Node.makeSink(.const_unit, out, 0));
                return out;
            },
            .string_literal => |sl| {
                const out = try self.allocChannel(.ref_chan);
                const str_idx = self.addString(sl.value);
                const meta_idx = try self.addScalarMeta(.{ .kind = .str, .const_val = .{ .int_val = @intCast(str_idx) } });
                try self.emit(Node.makeSink(.const_str, out, meta_idx));
                return out;
            },
            .array_literal => |al| {
                // 编译所有元素，然后创建数组
                // Phase 2.5 简化：array_make 接收长度，然后逐个 array_set
                const elem_count = al.elements.len;
                // 长度常量
                const len_chan = try self.allocChannel(.i64_chan);
                const len_meta = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64, .const_val = .{ .int_val = @intCast(elem_count) } });
                try self.emit(Node.makeSink(.const_i, len_chan, len_meta));
                // 创建数组
                const arr_chan = try self.allocChannel(.ref_chan);
                try self.emit(Node.makeUnary(.array_make, arr_chan, 0, len_chan));
                // 逐个设置元素
                for (al.elements, 0..) |elem_expr, i| {
                    const elem_chan = try self.compileExpr(elem_expr);
                    const idx_chan = try self.allocChannel(.i64_chan);
                    const idx_meta = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64, .const_val = .{ .int_val = @intCast(i) } });
                    try self.emit(Node.makeSink(.const_i, idx_chan, idx_meta));
                    // array_set(arr, idx, value) — 使用 makeTernary
                    try self.emit(Node.makeTernary(.array_set, arr_chan, 0, arr_chan, idx_chan, elem_chan));
                }
                return arr_chan;
            },
            .identifier => |id| {
                // 先查变量绑定
                if (self.lookupVar(id.name)) |binding| return binding.chan;
                // 再查构造器表：无参构造器如 Leaf 可直接作为 identifier 引用
                if (self.ctor_table.get(id.name)) |ctor| {
                    if (ctor.fields.len == 0) {
                        return try self.compileConstructorCall(ctor, &.{});
                    }
                }
                return error.UnboundVariable;
            },
            .binary => |b| return self.compileBinary(b.op, b.left, b.right),
            .unary => |u| return self.compileUnary(u.op, u.operand),
            .block => |blk| return self.compileBlock(blk.statements, blk.trailing_expr),
            .call => |c| return self.compileCall(c.callee, c.arguments),
            .if_expr => |ie| return self.compileIf(ie),
            .propagate => |p| return self.compilePropagate(p.expr),
            .select => |s| return self.compileSelect(s.arms),
            .type_cast => |tc| return self.compileTypeCast(tc),
            .record_literal => |rl| return self.compileRecordLiteral(rl.fields),
            .record_extend => |re| return self.compileRecordExtend(re.base, re.updates),
            .field_access => |fa| return self.compileFieldAccess(fa.object, fa.field),
            .index => |idx| return self.compileIndex(idx.object, idx.index),
            .string_interpolation => |si| return self.compileStringInterpolation(si.parts),
            .non_null_assert => |nn| return self.compileNonNullAssert(nn.expr),
            .safe_access => |sa| return self.compileSafeAccess(sa.object, sa.field),
            .method_call => |mc| return self.compileMethodCall(mc.object, mc.method, mc.arguments, false),
            .safe_method_call => |mc| return self.compileMethodCall(mc.object, mc.method, mc.arguments, true),
            .lambda => |lam| return self.compileLambda(lam),
            .match => |m| return self.compileMatch(m.scrutinee, m.arms),
            .assignment_expr => |a| return self.compileAssignmentExpr(a.target, a.value),
            .compound_assign => |ca| return self.compileCompoundAssignExpr(ca.op, ca.target, ca.value),
            .atomic_expr => |ae| return self.compileAtomicExpr(ae.value),
            .lazy => |lz| return self.compileLazyExpr(lz.expr),
            .spawn_expr => |se| return self.compileSpawnExpr(se.expr),
            .inline_trait_value => |itv| return self.compileInlineTraitValue(itv.methods),
        }
    }

    /// 编译整数字面量
    fn compileIntLiteral(self: *IRBuilder, raw: []const u8, suffix: ?[]const u8) BuildError!u16 {
        const int_kind = intKindFromSuffix(suffix) orelse .i64;
        const chan_type = ChanType.fromIntKind(int_kind);

        // 解析整数值（过滤下划线）
        var clean_buf: [64]u8 = undefined;
        const clean = filterDigits(raw, &clean_buf);

        // 检测进制前缀：0x/0X=十六进制, 0o/0O=八进制, 0b/0B=二进制
        const base: u8 = blk: {
            if (clean.len >= 2 and clean[0] == '0') {
                switch (clean[1]) {
                    'x', 'X' => break :blk 16,
                    'o', 'O' => break :blk 8,
                    'b', 'B' => break :blk 2,
                    else => {},
                }
            }
            break :blk 10;
        };
        const digits = if (base != 10) clean[2..] else clean;

        const value: i128 = std.fmt.parseInt(i128, digits, base) catch return error.InvalidLiteral;

        const out = try self.allocChannel(chan_type);
        const meta_idx = try self.addScalarMeta(.{
            .kind = .int,
            .int_kind = int_kind,
            .const_val = .{ .int_val = value },
        });
        try self.emit(Node.makeSink(.const_i, out, meta_idx));
        return out;
    }

    /// 编译浮点字面量
    fn compileFloatLiteral(self: *IRBuilder, raw: []const u8, suffix: ?[]const u8) BuildError!u16 {
        const float_kind = floatKindFromSuffix(suffix) orelse .f64;
        const chan_type = ChanType.fromFloatKind(float_kind);

        const value: f64 = std.fmt.parseFloat(f64, raw) catch return error.InvalidLiteral;
        const bits: u64 = @bitCast(value);

        const out = try self.allocChannel(chan_type);
        const meta_idx = try self.addScalarMeta(.{
            .kind = .float,
            .float_kind = float_kind,
            .const_val = .{ .float_val = bits }, // f64 位模式存入 u128
        });
        try self.emit(Node.makeSink(.const_f, out, meta_idx));
        return out;
    }

    /// 编译二元运算
    fn compileBinary(self: *IRBuilder, op: ast.BinaryOp, left: *ast.Expr, right: *ast.Expr) BuildError!u16 {
        // Elvis 操作符 (??) 特殊处理：编译为 nullable_unwrap_or
        if (op == .elvis) {
            return self.compileElvis(left, right);
        }

        // Range 操作符 (.. / ..=) 特殊处理：创建数组
        if (op == .range or op == .range_inclusive) {
            return self.compileRangeExpr(left, right, op == .range_inclusive);
        }

        const left_chan = try self.compileExpr(left);
        return self.compileBinaryOpWithChan(op, left_chan, right);
    }

    /// 编译 range 表达式：start..end 或 start..=end → array
    fn compileRangeExpr(self: *IRBuilder, left: *const ast.Expr, right: *const ast.Expr, inclusive: bool) BuildError!u16 {
        const start_chan = try self.compileExpr(left);
        const end_chan = try self.compileExpr(right);

        // 计算长度：end - start (或 end - start + 1 if inclusive)
        const diff_chan = try self.allocChannel(.i64_chan);
        const meta_idx = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64 });
        try self.emit(Node.makeBinary(.int_sub, diff_chan, meta_idx, end_chan, start_chan));

        var len_chan = diff_chan;
        if (inclusive) {
            const one_chan = try self.allocChannel(.i64_chan);
            const one_meta = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64, .const_val = .{ .int_val = 1 } });
            try self.emit(Node.makeSink(.const_i, one_chan, one_meta));
            const incl_len = try self.allocChannel(.i64_chan);
            try self.emit(Node.makeBinary(.int_add, incl_len, meta_idx, diff_chan, one_chan));
            len_chan = incl_len;
        }

        // 创建数组
        const arr_chan = try self.allocChannel(.ref_chan);
        try self.emit(Node.makeUnary(.array_make, arr_chan, 0, len_chan));

        // 使用 vec_source + vec_sink 填充数组
        // 简化：直接返回空数组（长度已设置），元素通过 vec_source 填充
        // 完整实现需要 vec_source 从 start 到 end 生成值
        return arr_chan;
    }

    /// 编译二元运算（左操作数已编译为通道）
    fn compileBinaryOpWithChan(self: *IRBuilder, op: ast.BinaryOp, left_chan: u16, right: *ast.Expr) BuildError!u16 {
        if (op == .elvis) return error.UnsupportedExpr;

        const right_chan = try self.compileExpr(right);
        const left_meta = self.channels.get(left_chan);
        const result_type = binaryResultType(op, left_meta.chan_type);
        const out = try self.allocChannel(result_type);

        const node_op = try binaryOpToNodeOp(op, left_meta.chan_type);
        const kind: ScalarKind = if (result_type.isInt()) .int else if (result_type.isFloat()) .float else if (result_type == .ref_chan) .ref else .bool;
        const meta_idx = try self.addScalarMeta(.{
            .kind = kind,
            .int_kind = result_type.toIntKind() orelse .i64,
            .float_kind = result_type.toFloatKind() orelse .f64,
        });

        try self.emit(Node.makeBinary(node_op, out, meta_idx, left_chan, right_chan));
        return out;
    }

    /// 编译一元运算
    fn compileUnary(self: *IRBuilder, op: ast.UnaryOp, operand: *ast.Expr) BuildError!u16 {
        const operand_chan = try self.compileExpr(operand);
        const operand_meta = self.channels.get(operand_chan);
        const result_type = operand_meta.chan_type;
        const out = try self.allocChannel(result_type);

        const node_op = try unaryOpToNodeOp(op, result_type);
        const kind: ScalarKind = if (result_type.isInt()) .int else if (result_type.isFloat()) .float else .bool;
        const meta_idx = try self.addScalarMeta(.{
            .kind = kind,
            .int_kind = result_type.toIntKind() orelse .i64,
            .float_kind = result_type.toFloatKind() orelse .f64,
        });

        try self.emit(Node.makeUnary(node_op, out, meta_idx, operand_chan));
        return out;
    }

    /// 编译 if 表达式（惰性分支：then/else 作为子图，由 route_dispatch 按条件执行）
    fn compileIf(self: *IRBuilder, ie: anytype) BuildError!u16 {
        const cond_chan = try self.compileExpr(ie.condition);

        // 条件转 winner 索引：bool cast 为 i64（true=1, false=0）
        // arm 0 = else, arm 1 = then → true→1→then, false→0→else
        const winner_chan = try self.allocChannel(.i64_chan);
        const cast_meta_idx = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64 });
        try self.emit(Node.makeUnary(.cast, winner_chan, cast_meta_idx, cond_chan));

        // 编译 else/then 为子图（惰性求值，由 route_dispatch 按条件执行）
        // 注意：子图必须至少有一个节点，否则 route_dispatch 无法读取 body 输出
        // 如果表达式编译后没有发射节点（如纯 identifier），补一个 load 节点

        // arm 0 = else 子图
        const else_start: u32 = @intCast(self.nodes.items.len);
        const else_body_chan = if (ie.else_branch) |eb| try self.compileExpr(eb) else blk: {
            const ch = try self.allocChannel(.unit_chan);
            try self.emit(Node.makeSink(.const_unit, ch, 0));
            break :blk ch;
        };
        if (self.nodes.items.len == else_start) {
            // 子图为空（纯 identifier 等），补 load 节点
            const load_chan = try self.allocChannel(self.channels.get(else_body_chan).chan_type);
            try self.emit(Node.makeUnary(.load, load_chan, 0, else_body_chan));
        }
        const else_len: u32 = @intCast(self.nodes.items.len - else_start);

        // arm 1 = then 子图
        const then_start: u32 = @intCast(self.nodes.items.len);
        const then_body_chan = try self.compileExpr(ie.then_branch);
        if (self.nodes.items.len == then_start) {
            const load_chan = try self.allocChannel(self.channels.get(then_body_chan).chan_type);
            try self.emit(Node.makeUnary(.load, load_chan, 0, then_body_chan));
        }
        const then_len: u32 = @intCast(self.nodes.items.len - then_start);

        // 复制到 arena 分配的 slice
        const arena_alloc = self.arena.allocator();
        const body_starts = try arena_alloc.alloc(u32, 2);
        const body_lens = try arena_alloc.alloc(u32, 2);
        body_starts[0] = else_start;
        body_lens[0] = else_len;
        body_starts[1] = then_start;
        body_lens[1] = then_len;

        // route_dispatch 按 winner 索引执行对应子图
        // 结果类型继承 then 分支（用子图最后一个节点的 output，而非第一个）
        const then_type = self.channels.get(self.nodes.items[then_start + then_len - 1].output).chan_type;
        const result_chan = try self.allocChannel(then_type);
        const route_meta_idx = try self.addRouteMeta(.{
            .trait_id = 0,
            .method_id = 0,
            .target_count = 2,
            .body_starts = body_starts,
            .body_lens = body_lens,
        });
        try self.emit(Node.makeUnary(.route_dispatch, result_chan, route_meta_idx, winner_chan));
        return result_chan;
    }

    /// 编译类型转换（type_cast）
    /// safe=false: i32(big) — 不安全转换，wrap/饱和
    /// safe=true:  i32(x)?  — 安全转换，越界抛出错误（? 传播）
    fn compileTypeCast(self: *IRBuilder, tc: anytype) BuildError!u16 {
        const src_chan = try self.compileExpr(tc.expr);
        const dst_chan_type = chanTypeFromTypeNode(tc.target_type) orelse return error.UnsupportedType;
        const out = try self.allocChannel(dst_chan_type);

        // 构造目标类型的 ScalarMeta
        const kind: ScalarKind = if (dst_chan_type.isInt()) .int else if (dst_chan_type.isFloat()) .float else if (dst_chan_type == .bool_chan) .bool else if (dst_chan_type == .char_chan) .char else .ref;
        const meta_idx = try self.addScalarMeta(.{
            .kind = kind,
            .int_kind = dst_chan_type.toIntKind() orelse .i64,
            .float_kind = dst_chan_type.toFloatKind() orelse .f64,
        });

        const op: NodeOp = if (tc.safe) .cast_safe else .cast;
        try self.emit(Node.makeUnary(op, out, meta_idx, src_chan));
        return out;
    }

    /// 编译记录字面量：{ field1: val1, field2: val2 }
    /// → record_make + 逐个 record_set
    fn compileRecordLiteral(self: *IRBuilder, fields: []ast.RecordFieldExpr) BuildError!u16 {
        const rec_chan = try self.allocChannel(.ref_chan);
        // type_name 暂为空（sema 后提供）
        const type_name_idx = self.addString("");
        const meta_idx = try self.addScalarMeta(.{ .kind = .str, .const_val = .{ .int_val = @intCast(type_name_idx) } });
        try self.emit(Node.makeSink(.record_make, rec_chan, meta_idx));
        for (fields) |field| {
            const val_chan = try self.compileExpr(field.value);
            const field_name_idx = self.addString(field.name);
            const field_meta_idx = try self.addScalarMeta(.{ .kind = .str, .const_val = .{ .int_val = @intCast(field_name_idx) } });
            try self.emit(Node.makeBinary(.record_set, rec_chan, field_meta_idx, rec_chan, val_chan));
        }
        return rec_chan;
    }

    /// 编译记录扩展：(...base, field: value, ...)
    /// → record_clone(base) → record_set(new_rec, field, value) ...
    fn compileRecordExtend(self: *IRBuilder, base: *ast.Expr, updates: []ast.RecordFieldExpr) BuildError!u16 {
        const base_chan = try self.compileExpr(base);
        // 克隆 base 记录
        const new_chan = try self.allocChannel(.ref_chan);
        try self.emit(Node.makeUnary(.record_clone, new_chan, 0, base_chan));
        // 应用更新字段
        for (updates) |field| {
            const val_chan = try self.compileExpr(field.value);
            const field_name_idx = self.addString(field.name);
            const field_meta_idx = try self.addScalarMeta(.{ .kind = .str, .const_val = .{ .int_val = @intCast(field_name_idx) } });
            try self.emit(Node.makeBinary(.record_set, new_chan, field_meta_idx, new_chan, val_chan));
        }
        return new_chan;
    }

    /// 编译赋值表达式：target = value（作为表达式，返回 value）
    fn compileAssignmentExpr(self: *IRBuilder, target: *ast.Expr, value: *ast.Expr) BuildError!u16 {
        const value_chan = try self.compileExpr(value);
        switch (target.*) {
            .identifier => |id| {
                const binding = self.lookupVar(id.name) orelse return error.UnboundVariable;
                try self.emit(Node.makeUnary(.store, binding.chan, 0, value_chan));
            },
            else => return error.UnsupportedExpr,
        }
        return value_chan;
    }

    /// 编译复合赋值表达式：target op= value（作为表达式，返回结果）
    fn compileCompoundAssignExpr(self: *IRBuilder, op: ast.CompoundAssignOp, target: *ast.Expr, value: *ast.Expr) BuildError!u16 {
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
        const result_chan = try self.compileBinary(bin_op, target, value);
        switch (target.*) {
            .identifier => |id| {
                const binding = self.lookupVar(id.name) orelse return error.UnboundVariable;
                try self.emit(Node.makeUnary(.store, binding.chan, 0, result_chan));
            },
            else => return error.UnsupportedExpr,
        }
        return result_chan;
    }

    /// 编译字段访问：obj.field
    /// → record_get(obj, field_name)
    fn compileFieldAccess(self: *IRBuilder, object: *ast.Expr, field: []const u8) BuildError!u16 {
        const obj_chan = try self.compileExpr(object);
        const field_name_idx = self.addString(field);
        const meta_idx = try self.addScalarMeta(.{ .kind = .str, .const_val = .{ .int_val = @intCast(field_name_idx) } });
        // 尝试从 AST 推断字段类型，无 sema 时的实用方案
        // 无法推断时默认 i64_chan（保持向后兼容，整数字段最常见）
        const chan_type = self.inferFieldType(object, field) orelse .i64_chan;
        const out = try self.allocChannel(chan_type);
        try self.emit(Node.makeUnary(.record_get, out, meta_idx, obj_chan));
        return out;
    }

    /// 从 AST 推断字段类型（无 sema 时的简易类型推导）
    /// 通过回溯对象表达式找到 record_literal/record_extend，再查字段值类型
    fn inferFieldType(self: *IRBuilder, object: *ast.Expr, field: []const u8) ?ChanType {
        // 如果是 identifier，查找其定义
        const obj_expr = switch (object.*) {
            .identifier => |id| blk: {
                if (self.lookupVar(id.name)) |binding| {
                    if (binding.ast_expr) |e| break :blk e;
                }
                break :blk null;
            },
            else => object,
        } orelse return null;

        switch (obj_expr.*) {
            .record_literal => |rl| {
                for (rl.fields) |f| {
                    if (std.mem.eql(u8, f.name, field)) {
                        return self.inferChanTypeFromExpr(f.value);
                    }
                }
            },
            .record_extend => |re| {
                // 先查 updates
                for (re.updates) |f| {
                    if (std.mem.eql(u8, f.name, field)) {
                        return self.inferChanTypeFromExpr(f.value);
                    }
                }
                // 再查 base
                return self.inferFieldType(re.base, field);
            },
            else => {},
        }
        return null;
    }

    /// 从表达式推断通道类型
    fn inferChanTypeFromExpr(self: *IRBuilder, expr: *ast.Expr) ?ChanType {
        switch (expr.*) {
            .int_literal => |il| {
                const int_kind = intKindFromSuffix(il.suffix) orelse .i64;
                return ChanType.fromIntKind(int_kind);
            },
            .float_literal => |fl| {
                const float_kind = floatKindFromSuffix(fl.suffix) orelse .f64;
                return ChanType.fromFloatKind(float_kind);
            },
            .bool_literal => return .bool_chan,
            .char_literal => return .char_chan,
            .string_literal, .string_interpolation => return .ref_chan,
            .array_literal => return .ref_chan,
            .record_literal, .record_extend => return .ref_chan,
            .null_literal => return .null_chan,
            .unit_literal => return .unit_chan,
            .identifier => |id| {
                if (self.lookupVar(id.name)) |binding| {
                    return self.channels.get(binding.chan).chan_type;
                }
                return null;
            },
            else => return null,
        }
    }

    /// 编译索引访问：obj[index]
    /// 数组 → array_get，字符串 → string_index
    fn compileIndex(self: *IRBuilder, object: *ast.Expr, index: *ast.Expr) BuildError!u16 {
        const obj_chan = try self.compileExpr(object);
        const idx_chan = try self.compileExpr(index);
        // 通过 AST 节点类型推断（sema 后改为精确类型推导）
        const is_string = switch (object.*) {
            .string_literal, .string_interpolation => true,
            else => false,
        };
        if (is_string) {
            const out = try self.allocChannel(.char_chan);
            try self.emit(Node.makeBinary(.string_index, out, 0, obj_chan, idx_chan));
            return out;
        }
        // 默认数组索引
        const out = try self.allocChannel(.i64_chan);
        try self.emit(Node.makeBinary(.array_get, out, 0, obj_chan, idx_chan));
        return out;
    }

    /// 编译字符串插值："...${expr}..."
    /// → 逐段 string_concat 链
    fn compileStringInterpolation(self: *IRBuilder, parts: []ast.InterpolationPart) BuildError!u16 {
        if (parts.len == 0) {
            // 空插值 → 空字符串
            const out = try self.allocChannel(.ref_chan);
            const str_idx = self.addString("");
            const meta_idx = try self.addScalarMeta(.{ .kind = .str, .const_val = .{ .int_val = @intCast(str_idx) } });
            try self.emit(Node.makeSink(.const_str, out, meta_idx));
            return out;
        }
        // 第一段
        var current_chan: u16 = switch (parts[0]) {
            .literal => |s| blk: {
                const out = try self.allocChannel(.ref_chan);
                const str_idx = self.addString(s);
                const meta_idx = try self.addScalarMeta(.{ .kind = .str, .const_val = .{ .int_val = @intCast(str_idx) } });
                try self.emit(Node.makeSink(.const_str, out, meta_idx));
                break :blk out;
            },
            .expression => |e| try self.compileExpr(e),
        };
        // 后续段逐个 concat
        for (parts[1..]) |part| {
            const next_chan: u16 = switch (part) {
                .literal => |s| blk: {
                    const out = try self.allocChannel(.ref_chan);
                    const str_idx = self.addString(s);
                    const meta_idx = try self.addScalarMeta(.{ .kind = .str, .const_val = .{ .int_val = @intCast(str_idx) } });
                    try self.emit(Node.makeSink(.const_str, out, meta_idx));
                    break :blk out;
                },
                .expression => |e| try self.compileExpr(e),
            };
            const out = try self.allocChannel(.ref_chan);
            const meta_idx = try self.addScalarMeta(.{ .kind = .ref });
            try self.emit(Node.makeBinary(.string_concat, out, meta_idx, current_chan, next_chan));
            current_chan = out;
        }
        return current_chan;
    }

    /// 编译函数调用
    fn compileCall(self: *IRBuilder, callee: *ast.Expr, arguments: []*ast.Expr) BuildError!u16 {
        // 只支持直接函数名调用
        const func_name = switch (callee.*) {
            .identifier => |id| id.name,
            else => return error.UnsupportedExpr,
        };

        // 内置函数：print / println
        if (std.mem.eql(u8, func_name, "print") or std.mem.eql(u8, func_name, "println")) {
            if (arguments.len != 1) return error.UnsupportedExpr;
            const arg_chan = try self.compileExpr(arguments[0]);
            const out = try self.allocChannel(.unit_chan);
            const op: NodeOp = if (std.mem.eql(u8, func_name, "println")) .builtin_println else .builtin_print;
            try self.emit(Node.makeUnary(op, out, 0, arg_chan));
            return out;
        }

        // 内置函数：eprint / eprintln（stderr 输出）
        if (std.mem.eql(u8, func_name, "eprint") or std.mem.eql(u8, func_name, "eprintln")) {
            if (arguments.len != 1) return error.UnsupportedExpr;
            const arg_chan = try self.compileExpr(arguments[0]);
            const out = try self.allocChannel(.unit_chan);
            const op: NodeOp = if (std.mem.eql(u8, func_name, "eprintln")) .builtin_eprintln else .builtin_eprint;
            try self.emit(Node.makeUnary(op, out, 0, arg_chan));
            return out;
        }

        // 内置函数：scan / scanln（stdin 读取）
        if (std.mem.eql(u8, func_name, "scan") or std.mem.eql(u8, func_name, "scanln")) {
            const out = try self.allocChannel(.ref_chan);
            const op: NodeOp = if (std.mem.eql(u8, func_name, "scanln")) .builtin_scanln else .builtin_scan;
            try self.emit(Node.makeSink(op, out, 0));
            return out;
        }

        // 内置函数：type(x) → 运行时类型名
        if (std.mem.eql(u8, func_name, "type")) {
            if (arguments.len != 1) return error.UnsupportedExpr;
            const arg_chan = try self.compileExpr(arguments[0]);
            const out = try self.allocChannel(.ref_chan);
            try self.emit(Node.makeUnary(.builtin_type, out, 0, arg_chan));
            return out;
        }

        // 内置函数：Panic(msg) → 触发 panic
        if (std.mem.eql(u8, func_name, "Panic")) {
            const out = try self.allocChannel(.unit_chan);
            if (arguments.len == 0) {
                try self.emit(Node.makeSink(.builtin_panic, out, 0));
            } else {
                // 有消息参数：先打印再 panic
                const arg_chan = try self.compileExpr(arguments[0]);
                try self.emit(Node.makeUnary(.builtin_eprint, try self.allocChannel(.unit_chan), 0, arg_chan));
                try self.emit(Node.makeSink(.builtin_panic, out, 0));
            }
            return out;
        }

        // 内置构造器：Ok(value) → 构造 ThrowValue(ok)
        if (std.mem.eql(u8, func_name, "Ok")) {
            if (arguments.len != 1) return error.UnsupportedExpr;
            const arg_chan = try self.compileExpr(arguments[0]);
            const out = try self.allocChannel(.ref_chan);
            try self.emit(Node.makeUnary(.builtin_ok, out, 0, arg_chan));
            return out;
        }

        // 内置构造器：Error(msg) → 构造 ThrowValue(err) + ErrorValue
        if (std.mem.eql(u8, func_name, "Error")) {
            if (arguments.len != 1) return error.UnsupportedExpr;
            const arg_chan = try self.compileExpr(arguments[0]);
            const out = try self.allocChannel(.ref_chan);
            try self.emit(Node.makeUnary(.builtin_error, out, 0, arg_chan));
            return out;
        }

        // 内置函数：eq(a, b) → 结构相等比较
        if (std.mem.eql(u8, func_name, "eq")) {
            if (arguments.len != 2) return error.UnsupportedExpr;
            const a_chan = try self.compileExpr(arguments[0]);
            const b_chan = try self.compileExpr(arguments[1]);
            const out = try self.allocChannel(.bool_chan);
            try self.emit(Node.makeBinary(.builtin_eq, out, 0, a_chan, b_chan));
            return out;
        }

        // 内置函数：str(x) → 转字符串
        if (std.mem.eql(u8, func_name, "str")) {
            if (arguments.len != 1) return error.UnsupportedExpr;
            const arg_chan = try self.compileExpr(arguments[0]);
            const out = try self.allocChannel(.ref_chan);
            try self.emit(Node.makeUnary(.builtin_str, out, 0, arg_chan));
            return out;
        }

        // 构造器调用：Node(5, Leaf, Leaf) → record_make + record_set __tag + 各字段
        if (self.ctor_table.get(func_name)) |ctor| {
            return try self.compileConstructorCall(ctor, arguments);
        }

        const func_idx = self.func_table.get(func_name) orelse {
            // 不在 func_table 中：检查是否为变量（lambda 调用）
            if (self.lookupVar(func_name)) |binding| {
                return try self.compileCallIndirect(binding.chan, arguments);
            }
            return error.UndefinedFunction;
        };

        // 编译参数
        const arena_alloc = self.arena.allocator();
        var arg_chans = try arena_alloc.alloc(u16, arguments.len);
        for (arguments, 0..) |arg, i| {
            arg_chans[i] = try self.compileExpr(arg);
        }

        const func = self.functions.items[func_idx];

        // async 函数：发射 orbit_async_create 返回 AsyncHandle（不自动 await）
        // 用户需显式调用 .await() 获取结果，.status() 查询状态
        if (func.is_async) {
            return try self.emitOrbitCreate(func_idx, arg_chans, func);
        }

        // 普通函数：发射 call 节点
        const out = try self.allocChannel(self.channels.get(func.return_channel).chan_type);
        const call_meta_idx = try self.addCallMeta(.{
            .func_index = func_idx,
            .arg_count = @intCast(arguments.len),
        });

        var inputs: [4]u16 = .{ 0, 0, 0, 0 };
        for (arg_chans, 0..) |ch, i| {
            if (i < 4) inputs[i] = ch;
        }
        try self.emit(Node{
            .op = .call,
            .input_count = @intCast(@min(arguments.len, 4)),
            .output = out,
            .meta_index = call_meta_idx,
            .inputs = inputs,
        });
        return out;
    }

    /// 编译构造器调用：Ctor(args...) → record_make(type_name) + record_set(__tag, tag) + record_set(field, val)...
    /// ADT 值用 record 表示，__tag 字段存储构造器索引（用于 match 分派）
    fn compileConstructorCall(self: *IRBuilder, ctor: CtorInfo, arguments: []*ast.Expr) BuildError!u16 {
        // Newtype 构造器：在无 sema 时仍用 record 表示（保持字段访问兼容性）
        // 当 sema 接入后，可改用 newtype_wrap 节点
        const rec_chan = try self.allocChannel(.ref_chan);
        // record_make：meta 存储类型名
        const type_name_idx = self.addString(ctor.type_name);
        const make_meta = try self.addScalarMeta(.{ .kind = .str, .const_val = .{ .int_val = @intCast(type_name_idx) } });
        try self.emit(Node.makeSink(.record_make, rec_chan, make_meta));

        // 设置 __tag 字段（构造器索引，用于 match 分派）
        const tag_chan = try self.allocChannel(.i64_chan);
        const tag_meta = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64, .const_val = .{ .int_val = ctor.tag } });
        try self.emit(Node.makeSink(.const_i, tag_chan, tag_meta));
        const tag_field_idx = self.addString("__tag");
        const tag_field_meta = try self.addScalarMeta(.{ .kind = .str, .const_val = .{ .int_val = @intCast(tag_field_idx) } });
        try self.emit(Node.makeBinary(.record_set, rec_chan, tag_field_meta, rec_chan, tag_chan));

        // 设置各字段
        const arg_count = @min(arguments.len, ctor.fields.len);
        for (0..arg_count) |i| {
            const val_chan = try self.compileExpr(arguments[i]);
            const field_name_idx = self.addString(ctor.fields[i].name);
            const field_meta = try self.addScalarMeta(.{ .kind = .str, .const_val = .{ .int_val = @intCast(field_name_idx) } });
            try self.emit(Node.makeBinary(.record_set, rec_chan, field_meta, rec_chan, val_chan));
        }
        return rec_chan;
    }

    // ════════════════════════════════════════════
    // match 表达式编译（P0-c）
    // ════════════════════════════════════════════

    /// 编译 match 表达式：match scrutinee { arm1 => body1, ... }
    /// 策略：转换为嵌套 if-else 链，每个 arm 用 route_dispatch 选择
    fn compileMatch(self: *IRBuilder, scrutinee: *ast.Expr, arms: []const ast.MatchArm) BuildError!u16 {
        const scrutinee_chan = try self.compileExpr(scrutinee);
        return try self.compileMatchArms(scrutinee_chan, arms, 0);
    }

    /// 递归编译 match arms：当前 arm + 剩余 arms（else 分支）
    fn compileMatchArms(self: *IRBuilder, scrutinee_chan: u16, arms: []const ast.MatchArm, start_idx: usize) BuildError!u16 {
        if (start_idx >= arms.len) {
            // 无匹配 arm：返回 unit（实际应由 wildcard 兜底）
            const out = try self.allocChannel(.unit_chan);
            try self.emit(Node.makeSink(.const_unit, out, 0));
            return out;
        }

        const arm = arms[start_idx];
        const arena_alloc = self.arena.allocator();

        // push scope for pattern variables（check 和 then body 共享）
        try self.pushScope();

        // 编译 pattern check → cond_chan（bool），同时绑定模式变量
        const pat_cond_chan = try self.compilePatternCheck(scrutinee_chan, arm.pattern);

        // 处理 guard：cond = pattern_match AND guard
        const final_cond_chan = if (arm.guard) |guard| blk: {
            const guard_chan = try self.compileExpr(guard);
            const and_chan = try self.allocChannel(.bool_chan);
            const meta_idx = try self.addScalarMeta(.{ .kind = .bool });
            try self.emit(Node.makeBinary(.bool_and, and_chan, meta_idx, pat_cond_chan, guard_chan));
            break :blk and_chan;
        } else pat_cond_chan;

        // arm 1 = then 子图（pattern 变量在作用域内）
        const then_start: u32 = @intCast(self.nodes.items.len);
        const body_chan = try self.compileExpr(arm.body);
        if (self.nodes.items.len == then_start) {
            const load_chan = try self.allocChannel(self.channels.get(body_chan).chan_type);
            try self.emit(Node.makeUnary(.load, load_chan, 0, body_chan));
        }
        const then_len: u32 = @intCast(self.nodes.items.len - then_start);

        // pop scope（pattern 变量不再按名可见）
        self.popScope();

        // arm 0 = else 子图（剩余 arms，无 pattern 变量）
        const else_start: u32 = @intCast(self.nodes.items.len);
        const else_chan = try self.compileMatchArms(scrutinee_chan, arms, start_idx + 1);
        if (self.nodes.items.len == else_start) {
            const load_chan = try self.allocChannel(self.channels.get(else_chan).chan_type);
            try self.emit(Node.makeUnary(.load, load_chan, 0, else_chan));
        }
        const else_len: u32 = @intCast(self.nodes.items.len - else_start);

        // winner: bool → i64（true=1→then, false=0→else）
        const winner_chan = try self.allocChannel(.i64_chan);
        const cast_meta = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64 });
        try self.emit(Node.makeUnary(.cast, winner_chan, cast_meta, final_cond_chan));

        // 结果类型继承 then 分支
        const then_type = self.channels.get(self.nodes.items[then_start + then_len - 1].output).chan_type;
        const result_chan = try self.allocChannel(then_type);

        const body_starts = try arena_alloc.alloc(u32, 2);
        const body_lens = try arena_alloc.alloc(u32, 2);
        body_starts[0] = else_start;
        body_lens[0] = else_len;
        body_starts[1] = then_start;
        body_lens[1] = then_len;

        const route_meta_idx = try self.addRouteMeta(.{
            .trait_id = 0,
            .method_id = 0,
            .target_count = 2,
            .body_starts = body_starts,
            .body_lens = body_lens,
        });
        try self.emit(Node.makeUnary(.route_dispatch, result_chan, route_meta_idx, winner_chan));
        return result_chan;
    }

    /// 编译模式检查：返回 bool 通道（是否匹配），同时绑定模式变量到作用域
    fn compilePatternCheck(self: *IRBuilder, scrutinee_chan: u16, pattern: *const ast.Pattern) BuildError!u16 {
        switch (pattern.*) {
            .wildcard => {
                return try self.emitConstBool(true);
            },
            .variable => |v| {
                // 绑定变量到 scrutinee
                try self.defineVar(v.name, scrutinee_chan, false);
                return try self.emitConstBool(true);
            },
            .literal => |lit| {
                return try self.compileLiteralPattern(scrutinee_chan, lit);
            },
            .constructor => |c| {
                return try self.compileConstructorPattern(scrutinee_chan, c.name, c.patterns);
            },
            .record => |r| {
                return try self.compileRecordPattern(scrutinee_chan, r.fields);
            },
            .or_pattern => |op| {
                // left OR right（变量绑定在两侧都发生，应绑定同名变量）
                const left_chan = try self.compilePatternCheck(scrutinee_chan, op.left);
                const right_chan = try self.compilePatternCheck(scrutinee_chan, op.right);
                const out = try self.allocChannel(.bool_chan);
                const meta = try self.addScalarMeta(.{ .kind = .bool });
                try self.emit(Node.makeBinary(.bool_or, out, meta, left_chan, right_chan));
                return out;
            },
            .guard => |g| {
                // pattern AND condition
                const pat_chan = try self.compilePatternCheck(scrutinee_chan, g.pattern);
                const cond_chan = try self.compileExpr(g.condition);
                const out = try self.allocChannel(.bool_chan);
                const meta = try self.addScalarMeta(.{ .kind = .bool });
                try self.emit(Node.makeBinary(.bool_and, out, meta, pat_chan, cond_chan));
                return out;
            },
        }
    }

    /// 发射 const_bool 节点
    fn emitConstBool(self: *IRBuilder, val: bool) BuildError!u16 {
        const out = try self.allocChannel(.bool_chan);
        const meta = try self.addScalarMeta(.{ .kind = .bool, .const_val = .{ .bool_val = val } });
        try self.emit(Node.makeSink(.const_bool, out, meta));
        return out;
    }

    /// 编译字面量模式：scrutinee == literal
    fn compileLiteralPattern(self: *IRBuilder, scrutinee_chan: u16, lit: ast.PatternLiteral) BuildError!u16 {
        switch (lit) {
            .int => |raw| {
                const lit_chan = try self.compileIntLiteral(raw, null);
                return try self.emitCmpEq(scrutinee_chan, lit_chan);
            },
            .float => |raw| {
                const lit_chan = try self.compileFloatLiteral(raw, null);
                return try self.emitCmpEq(scrutinee_chan, lit_chan);
            },
            .bool => |b| {
                const lit_chan = try self.emitConstBool(b);
                return try self.emitCmpEq(scrutinee_chan, lit_chan);
            },
            .char => |c| {
                const lit_chan = try self.allocChannel(.char_chan);
                const meta = try self.addScalarMeta(.{ .kind = .char, .const_val = .{ .char_val = c } });
                try self.emit(Node.makeSink(.const_char, lit_chan, meta));
                return try self.emitCmpEq(scrutinee_chan, lit_chan);
            },
            .string => |s| {
                const lit_chan = try self.allocChannel(.ref_chan);
                const str_idx = self.addString(s);
                const meta = try self.addScalarMeta(.{ .kind = .str, .const_val = .{ .int_val = @intCast(str_idx) } });
                try self.emit(Node.makeSink(.const_str, lit_chan, meta));
                return try self.emitCmpEq(scrutinee_chan, lit_chan);
            },
            .null => {
                // null 检查：nullable_is_null（仅对 nullable_chan 有效）
                const out = try self.allocChannel(.bool_chan);
                try self.emit(Node.makeUnary(.nullable_is_null, out, 0, scrutinee_chan));
                return out;
            },
        }
    }

    /// 发射 cmp_eq 节点：left == right → mask_chan
    fn emitCmpEq(self: *IRBuilder, left_chan: u16, right_chan: u16) BuildError!u16 {
        const out = try self.allocChannel(.mask_chan);
        const meta = try self.addScalarMeta(.{ .kind = .bool });
        try self.emit(Node.makeBinary(.cmp_eq, out, meta, left_chan, right_chan));
        return out;
    }

    /// 编译构造器模式：Ctor(sub_patterns...)
    /// 检查 __tag == ctor.tag，然后递归检查各字段子模式
    fn compileConstructorPattern(self: *IRBuilder, scrutinee_chan: u16, ctor_name: []const u8, sub_patterns: []*ast.Pattern) BuildError!u16 {
        // 内置构造器模式：Ok(...) / Error(...) — ThrowValue 解构
        if (std.mem.eql(u8, ctor_name, "Ok")) {
            // gate_check → is_ok
            const is_ok_chan = try self.allocChannel(.bool_chan);
            try self.emit(Node.makeUnary(.gate_check, is_ok_chan, 0, scrutinee_chan));
            if (sub_patterns.len == 0) return is_ok_chan;
            // gate_get_ok → 绑定到子模式
            const ok_val_chan = try self.allocChannel(.ref_chan);
            try self.emit(Node.makeUnary(.gate_get_ok, ok_val_chan, 0, scrutinee_chan));
            const sub_check = try self.compilePatternCheck(ok_val_chan, sub_patterns[0]);
            const and_chan = try self.allocChannel(.bool_chan);
            const meta = try self.addScalarMeta(.{ .kind = .bool });
            try self.emit(Node.makeBinary(.bool_and, and_chan, meta, is_ok_chan, sub_check));
            return and_chan;
        }
        if (std.mem.eql(u8, ctor_name, "Error")) {
            // gate_check → is_ok, 然后 not is_ok → is_err
            const is_ok_chan = try self.allocChannel(.bool_chan);
            try self.emit(Node.makeUnary(.gate_check, is_ok_chan, 0, scrutinee_chan));
            const is_err_chan = try self.allocChannel(.bool_chan);
            const not_meta = try self.addScalarMeta(.{ .kind = .bool });
            try self.emit(Node.makeUnary(.bool_not, is_err_chan, not_meta, is_ok_chan));
            if (sub_patterns.len == 0) return is_err_chan;
            // gate_get_err → 绑定到子模式
            const err_val_chan = try self.allocChannel(.ref_chan);
            try self.emit(Node.makeUnary(.gate_get_err, err_val_chan, 0, scrutinee_chan));
            const sub_check = try self.compilePatternCheck(err_val_chan, sub_patterns[0]);
            const and_chan = try self.allocChannel(.bool_chan);
            const meta = try self.addScalarMeta(.{ .kind = .bool });
            try self.emit(Node.makeBinary(.bool_and, and_chan, meta, is_err_chan, sub_check));
            return and_chan;
        }

        const ctor = self.ctor_table.get(ctor_name) orelse return error.UndefinedFunction;
        const arena_alloc = self.arena.allocator();

        // 读取 __tag 字段
        const tag_field_idx = self.addString("__tag");
        const tag_field_meta = try self.addScalarMeta(.{ .kind = .str, .const_val = .{ .int_val = @intCast(tag_field_idx) } });
        const tag_chan = try self.allocChannel(.i64_chan);
        try self.emit(Node.makeUnary(.record_get, tag_chan, tag_field_meta, scrutinee_chan));

        // 期望的 tag 值
        const expected_tag_chan = try self.allocChannel(.i64_chan);
        const expected_tag_meta = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64, .const_val = .{ .int_val = ctor.tag } });
        try self.emit(Node.makeSink(.const_i, expected_tag_chan, expected_tag_meta));

        // 比较 tag → tag_cond
        const tag_cond = try self.emitCmpEq(tag_chan, expected_tag_chan);

        // 无子模式：直接返回 tag 检查结果（不需要读字段）
        const sub_count = @min(sub_patterns.len, ctor.fields.len);
        if (sub_count == 0) return tag_cond;

        // 有子模式：字段读取必须在 tag 匹配时才执行，否则 record_get 会因字段不存在而失败
        // 用 route_dispatch 条件执行（与 compileIf 相同的子图模式）
        const winner_chan = try self.allocChannel(.i64_chan);
        const cast_meta = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64 });
        try self.emit(Node.makeUnary(.cast, winner_chan, cast_meta, tag_cond));

        // arm 0 = else 子图（tag 不匹配 → false）
        const else_start: u32 = @intCast(self.nodes.items.len);
        const false_chan = try self.emitConstBool(false);
        if (self.nodes.items.len == else_start) {
            const load_chan = try self.allocChannel(.bool_chan);
            try self.emit(Node.makeUnary(.load, load_chan, 0, false_chan));
        }
        const else_len: u32 = @intCast(self.nodes.items.len - else_start);

        // arm 1 = then 子图（tag 匹配 → 读字段，检查子模式）
        const then_start: u32 = @intCast(self.nodes.items.len);
        var result_chan = try self.emitConstBool(true);
        for (0..sub_count) |i| {
            // 读取字段值
            const field_name = ctor.fields[i].name;
            const field_idx = self.addString(field_name);
            const field_meta = try self.addScalarMeta(.{ .kind = .str, .const_val = .{ .int_val = @intCast(field_idx) } });
            // 字段类型：用 type_node 推导，默认 ref_chan（ADT 值为堆引用）
            const field_chan_type = chanTypeFromTypeNode(ctor.fields[i].type_node) orelse .ref_chan;
            const field_chan = try self.allocChannel(field_chan_type);
            try self.emit(Node.makeUnary(.record_get, field_chan, field_meta, scrutinee_chan));

            // 递归检查子模式（同时绑定模式变量）
            const sub_check_chan = try self.compilePatternCheck(field_chan, sub_patterns[i]);

            // AND 到当前结果
            const and_chan = try self.allocChannel(.bool_chan);
            const and_meta = try self.addScalarMeta(.{ .kind = .bool });
            try self.emit(Node.makeBinary(.bool_and, and_chan, and_meta, result_chan, sub_check_chan));
            result_chan = and_chan;
        }
        if (self.nodes.items.len == then_start) {
            const load_chan = try self.allocChannel(.bool_chan);
            try self.emit(Node.makeUnary(.load, load_chan, 0, result_chan));
        }
        const then_len: u32 = @intCast(self.nodes.items.len - then_start);

        // route_dispatch 按 winner 索引执行对应子图
        const body_starts = try arena_alloc.alloc(u32, 2);
        const body_lens = try arena_alloc.alloc(u32, 2);
        body_starts[0] = else_start;
        body_lens[0] = else_len;
        body_starts[1] = then_start;
        body_lens[1] = then_len;

        const result_type = self.channels.get(self.nodes.items[then_start + then_len - 1].output).chan_type;
        const result_out = try self.allocChannel(result_type);
        const route_meta_idx = try self.addRouteMeta(.{
            .trait_id = 0,
            .method_id = 0,
            .target_count = 2,
            .body_starts = body_starts,
            .body_lens = body_lens,
        });
        try self.emit(Node.makeUnary(.route_dispatch, result_out, route_meta_idx, winner_chan));
        return result_out;
    }

    /// 编译记录模式：(field1: pat1, field2: pat2, ...)
    fn compileRecordPattern(self: *IRBuilder, scrutinee_chan: u16, fields: []const ast.PatternRecordField) BuildError!u16 {
        if (fields.len == 0) return try self.emitConstBool(true);

        var result_chan: ?u16 = null;
        for (fields) |field| {
            const field_idx = self.addString(field.name);
            const field_meta = try self.addScalarMeta(.{ .kind = .str, .const_val = .{ .int_val = @intCast(field_idx) } });
            const field_chan = try self.allocChannel(.i64_chan);
            try self.emit(Node.makeUnary(.record_get, field_chan, field_meta, scrutinee_chan));

            const sub_check = try self.compilePatternCheck(field_chan, field.pattern);

            if (result_chan) |rc| {
                const and_chan = try self.allocChannel(.bool_chan);
                const and_meta = try self.addScalarMeta(.{ .kind = .bool });
                try self.emit(Node.makeBinary(.bool_and, and_chan, and_meta, rc, sub_check));
                result_chan = and_chan;
            } else {
                result_chan = sub_check;
            }
        }
        return result_chan.?;
    }

    // ════════════════════════════════════════════
    // 星轨编译（async/spawn，Phase 5）
    // ════════════════════════════════════════════

    /// 发射 orbit_async_create 节点：创建异步轨道，返回 handle 通道
    fn emitOrbitCreate(self: *IRBuilder, func_idx: u16, arg_chans: []const u16, func: Function) BuildError!u16 {
        // handle 通道：ref_chan 存储轨道句柄
        const handle_chan = try self.allocChannel(.ref_chan);
        const result_type = self.channels.get(func.return_channel).chan_type;

        const orbit_meta_idx = try self.addOrbitMeta(.{
            .func_index = func_idx,
            .arg_count = @intCast(arg_chans.len),
            .result_type = result_type,
            .is_spawn = false,
        });

        var inputs: [4]u16 = .{ 0, 0, 0, 0 };
        for (arg_chans, 0..) |ch, i| {
            if (i < 4) inputs[i] = ch;
        }
        try self.emit(Node{
            .op = .orbit_async_create,
            .input_count = @intCast(@min(arg_chans.len, 4)),
            .output = handle_chan,
            .meta_index = orbit_meta_idx,
            .inputs = inputs,
        });
        return handle_chan;
    }

    /// 发射 orbit_async_join 节点：等待轨道完成，返回结果通道
    pub fn emitOrbitJoin(self: *IRBuilder, handle_chan: u16, orbit_meta_idx: u16) BuildError!u16 {
        const orbit_meta = self.orbit_metas.items[orbit_meta_idx - 1];
        const result_chan = try self.allocChannel(orbit_meta.result_type);
        try self.emit(Node.makeUnary(.orbit_async_join, result_chan, orbit_meta_idx, handle_chan));
        return result_chan;
    }

    /// 发射 orbit_chan_send 节点：向轨道通道发送值
    pub fn emitOrbitSend(self: *IRBuilder, handle_chan: u16, val_chan: u16) BuildError!u16 {
        const out = try self.allocChannel(.unit_chan);
        try self.emit(Node.makeBinary(.orbit_chan_send, out, 0, handle_chan, val_chan));
        return out;
    }

    /// 发射 orbit_chan_recv 节点：从轨道通道接收值（阻塞）
    pub fn emitOrbitRecv(self: *IRBuilder, handle_chan: u16, result_type: ChanType) BuildError!u16 {
        const out = try self.allocChannel(result_type);
        try self.emit(Node.makeUnary(.orbit_chan_recv, out, 0, handle_chan));
        return out;
    }

    /// 发射 orbit_chan_try_recv 节点：非阻塞接收，返回 nullable
    pub fn emitOrbitTryRecv(self: *IRBuilder, handle_chan: u16, inner_type: ChanType) BuildError!u16 {
        const out = try self.allocChannel(.nullable_chan);
        _ = inner_type;
        try self.emit(Node.makeUnary(.orbit_chan_try_recv, out, 0, handle_chan));
        return out;
    }

    // ════════════════════════════════════════════
    // 语句编译
    // ════════════════════════════════════════════

    fn compileBlock(self: *IRBuilder, statements: []*ast.Stmt, trailing_expr: ?*ast.Expr) BuildError!u16 {
        try self.pushScope();
        defer self.popScope();

        var last_stmt_chan: ?u16 = null;
        for (statements) |stmt| {
            last_stmt_chan = try self.compileStmt(stmt);
        }

        if (trailing_expr) |te| {
            return self.compileExpr(te);
        }
        // 无尾表达式：如果最后一条语句产生了值（for/while），使用它
        if (last_stmt_chan) |ch| return ch;
        // 否则返回 unit
        const out = try self.allocChannel(.unit_chan);
        try self.emit(Node.makeSink(.const_unit, out, 0));
        return out;
    }

    fn compileStmt(self: *IRBuilder, stmt: *const ast.Stmt) BuildError!?u16 {
        switch (stmt.*) {
            .val_decl => |vd| {
                // 对于 lambda 值，预声明名字以支持递归引用
                if (vd.value.* == .lambda) {
                    self.pre_declared_lambda_names.append(self.allocator, vd.name) catch return error.OutOfMemory;
                    const chan = try self.compileExpr(vd.value);
                    _ = self.pre_declared_lambda_names.pop();
                    // lambda 编译时已在 compileLambda 中预声明了名字，
                    // 但仍需确保 binding 存储了 ast_expr（用于类型推断）
                    // 查找已有 binding 并更新 ast_expr
                    self.updateVarAstExpr(vd.name, vd.value);
                    _ = chan;
                } else {
                    const chan = try self.compileExpr(vd.value);
                    try self.scopeVar(vd.name, chan, false, vd.value);
                }
            },
            .var_decl => |vd| {
                const value_chan = try self.compileExpr(vd.value);
                const value_meta = self.channels.get(value_chan);
                const cell_chan = try self.allocCellChannel(value_meta.chan_type);
                try self.emit(Node.makeUnary(.load, cell_chan, 0, value_chan));
                try self.scopeVar(vd.name, cell_chan, true, vd.value);
            },
            .assignment => |as| {
                switch (as.target.*) {
                    .identifier => |id| {
                        const binding = self.lookupVar(id.name) orelse return error.UnboundVariable;
                        const value_chan = try self.compileExpr(as.value);
                        try self.emit(Node.makeUnary(.store, binding.chan, 0, value_chan));
                    },
                    .field_access => |fa| {
                        // obj.field = value → record_set(obj, field_idx, value)
                        const obj_chan = try self.compileExpr(fa.object);
                        const value_chan = try self.compileExpr(as.value);
                        const field_idx_meta = try self.addScalarMeta(.{ .kind = .ref, .const_val = .{ .int_val = self.addString(fa.field) } });
                        try self.emit(Node.makeBinary(.record_set, obj_chan, field_idx_meta, obj_chan, value_chan));
                    },
                    .index => |idx| {
                        // arr[i] = value → array_set(arr, idx, value)
                        const obj_chan = try self.compileExpr(idx.object);
                        const idx_chan = try self.compileExpr(idx.index);
                        const value_chan = try self.compileExpr(as.value);
                        try self.emit(Node.makeTernary(.array_set, obj_chan, 0, obj_chan, idx_chan, value_chan));
                    },
                    else => return error.UnsupportedExpr,
                }
            },
            .compound_assignment => |ca| {
                switch (ca.target.*) {
                    .identifier => |id| {
                        const binding = self.lookupVar(id.name) orelse return error.UnboundVariable;
                        const bin_op: ast.BinaryOp = switch (ca.op) {
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
                        const result_chan = try self.compileBinary(bin_op, ca.target, ca.value);
                        try self.emit(Node.makeUnary(.store, binding.chan, 0, result_chan));
                    },
                    .field_access => |fa| {
                        // obj.field op= value → record_get + op + record_set
                        const obj_chan = try self.compileExpr(fa.object);
                        const old_val_chan = try self.compileFieldAccess(fa.object, fa.field);
                        const bin_op: ast.BinaryOp = switch (ca.op) {
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
                        const result_chan = try self.compileBinaryOpWithChan(bin_op, old_val_chan, ca.value);
                        const field_idx_meta = try self.addScalarMeta(.{ .kind = .ref, .const_val = .{ .int_val = self.addString(fa.field) } });
                        try self.emit(Node.makeBinary(.record_set, obj_chan, field_idx_meta, obj_chan, result_chan));
                    },
                    .index => |idx| {
                        // arr[i] op= value → array_get + op + array_set
                        const obj_chan = try self.compileExpr(idx.object);
                        const idx_chan = try self.compileExpr(idx.index);
                        const old_val_chan = try self.allocChannel(.ref_chan);
                        try self.emit(Node.makeBinary(.array_get, old_val_chan, 0, obj_chan, idx_chan));
                        const bin_op: ast.BinaryOp = switch (ca.op) {
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
                        const result_chan = try self.compileBinaryOpWithChan(bin_op, old_val_chan, ca.value);
                        try self.emit(Node.makeTernary(.array_set, obj_chan, 0, obj_chan, idx_chan, result_chan));
                    },
                    else => return error.UnsupportedExpr,
                }
            },
            .expression => |es| {
                _ = try self.compileExpr(es.expr);
            },
            .return_stmt => |rs| {
                const ret_chan = self.current_return_chan orelse return error.UnsupportedStmt;
                const value_chan = if (rs.value) |v| try self.compileExpr(v) else blk: {
                    const ch = try self.allocChannel(.unit_chan);
                    try self.emit(Node.makeSink(.const_unit, ch, 0));
                    break :blk ch;
                };
                try self.emit(Node.makeUnary(.halt_return, ret_chan, 0, value_chan));
            },
            .for_stmt => |fs| return try self.compileFor(fs),
            .while_stmt => |ws| return try self.compileWhile(ws),
            .loop_stmt => |ls| return try self.compileLoop(ls),
            .break_stmt => {
                const out = try self.allocChannel(.unit_chan);
                try self.emit(Node.makeSink(.halt_break, out, 0));
                return out;
            },
            .continue_stmt => {
                const out = try self.allocChannel(.unit_chan);
                try self.emit(Node.makeSink(.halt_continue, out, 0));
                return out;
            },
            .defer_stmt => |ds| try self.compileDefer(ds),
            .throw_stmt => |ts| try self.compileThrow(ts),
            .field_assignment => |fa| {
                const obj_chan = try self.compileExpr(fa.object);
                const val_chan = try self.compileExpr(fa.value);
                const field_idx = self.addString(fa.field);
                const out = try self.allocChannel(.unit_chan);
                try self.emit(Node.makeBinary(.record_set, out, @intCast(field_idx), obj_chan, val_chan));
            },
        }
        return null;
    }

    // ════════════════════════════════════════════
    // 辅助函数
    // ════════════════════════════════════════════

    fn addString(self: *IRBuilder, s: []const u8) usize {
        const idx = self.string_pool.items.len;
        self.string_pool.append(self.arena.allocator(), s) catch {};
        return idx;
    }

    // ════════════════════════════════════════════
    // 向量编译（Phase 2）
    // ════════════════════════════════════════════

    /// 编译 for 循环为向量 op
    ///
    /// 支持形式：
    ///   for i in start..end { body }  → vec_source(range) |> vec_map(body) |> vec_sink
    ///   for i in array { body }       → vec_source(array) |> vec_map(body) |> vec_sink
    ///
    /// dispatch 从 O(N) 降为 O(1)：1 次 vec_source + 1 次 vec_map + 1 次 vec_sink
    fn compileFor(self: *IRBuilder, fs: anytype) BuildError!u16 {
        // 含 break/continue 时回退到标量循环
        if (self.containsBreakOrContinue(fs.body)) {
            return try self.compileForScalar(fs);
        }

        // 编译 iterable → vec_source 节点
        const src_vec_chan = try self.compileVecSource(fs.iterable);

        // 记录循环体起始位置
        const body_start: u32 = @intCast(self.nodes.items.len);

        // 在新作用域中编译循环体，绑定循环变量
        try self.pushScope();
        defer self.popScope();
        // 循环变量绑定到 vec_source 的元素通道
        try self.defineVar(fs.name, src_vec_chan, false);

        // 编译循环体（结果通道由 body 子图的最后一个节点决定）
        _ = try self.compileExpr(fs.body);

        const body_len: u32 = @intCast(self.nodes.items.len - body_start);

        // 发射 vec_map 节点（引用循环体子图）
        const map_meta_idx = try self.addVectorMeta(.{
            .inner_op = .const_i, // 占位，实际由 body_start/body_len 决定
            .body_start = body_start,
            .body_len = body_len,
            .elem_type = self.channels.get(src_vec_chan).chan_type,
        });

        const map_out = try self.allocChannel(self.channels.get(src_vec_chan).chan_type);
        try self.emit(Node.makeUnary(.vec_map, map_out, map_meta_idx, src_vec_chan));

        // 发射 vec_sink 节点（取最后一个元素作为 for 表达式的值）
        const sink_meta_idx = try self.addVectorMeta(.{
            .vec_op = .sink_last,
            .elem_type = self.channels.get(src_vec_chan).chan_type,
        });
        const sink_out = try self.allocChannel(self.channels.get(src_vec_chan).chan_type);
        try self.emit(Node.makeUnary(.vec_sink, sink_out, sink_meta_idx, map_out));

        return sink_out;
    }

    /// 编译 while 循环
    ///
    /// while cond { body } → vec_source(repeat) |> vec_take_while(cond) |> vec_sink
    /// Phase 2 简化实现：发射条件检查 + 循环体作为子图
    fn compileWhile(self: *IRBuilder, ws: anytype) BuildError!u16 {
        // 含 break/continue 时回退到标量循环
        if (self.containsBreakOrContinue(ws.body) or self.containsBreakOrContinue(ws.condition)) {
            return try self.compileWhileScalar(ws);
        }

        // while 循环长度未知，使用 vec_take_while 语义
        const body_start: u32 = @intCast(self.nodes.items.len);

        // 编译条件（在新作用域中）
        try self.pushScope();
        defer self.popScope();

        const cond_chan = try self.compileExpr(ws.condition);
        _ = try self.compileExpr(ws.body);

        const body_len: u32 = @intCast(self.nodes.items.len - body_start);

        // 发射 vec_take_while 节点
        const meta_idx = try self.addVectorMeta(.{
            .body_start = body_start,
            .body_len = body_len,
            .elem_type = .bool_chan,
        });
        const out = try self.allocChannel(.bool_chan);
        try self.emit(Node.makeUnary(.vec_take_while, out, meta_idx, cond_chan));

        // sink：返回迭代次数
        const sink_meta_idx = try self.addVectorMeta(.{
            .vec_op = .sink_count,
            .elem_type = .bool_chan,
        });
        const sink_out = try self.allocChannel(.i64_chan);
        try self.emit(Node.makeUnary(.vec_sink, sink_out, sink_meta_idx, out));

        return sink_out;
    }

    /// 编译 loop { body } 无限循环（含 break 退出）
    fn compileLoop(self: *IRBuilder, ls: anytype) BuildError!u16 {
        const body_start: u32 = @intCast(self.nodes.items.len);

        try self.pushScope();
        defer self.popScope();
        _ = try self.compileExpr(ls.body);
        const body_len: u32 = @intCast(self.nodes.items.len - body_start);

        const out = try self.allocChannel(.i64_chan);
        const meta_idx = try self.addLoopMeta(.{
            .body_start = body_start,
            .body_len = body_len,
            .loop_kind = .loop,
        });
        try self.emit(Node.makeSink(.scalar_loop, out, meta_idx));
        return out;
    }

    /// 标量 for 循环（含 break/continue）
    fn compileForScalar(self: *IRBuilder, fs: anytype) BuildError!u16 {
        // 编译 iterable → 向量通道
        const src_vec_chan = try self.compileVecSource(fs.iterable);
        const elem_type = self.channels.get(src_vec_chan).chan_type;

        const body_start: u32 = @intCast(self.nodes.items.len);

        try self.pushScope();
        defer self.popScope();
        // 循环变量绑定到向量元素通道（engine 执行时 pin 到当前元素）
        const iter_chan = try self.allocChannel(elem_type);
        try self.defineVar(fs.name, iter_chan, false);
        _ = try self.compileExpr(fs.body);
        const body_len: u32 = @intCast(self.nodes.items.len - body_start);

        const out = try self.allocChannel(.i64_chan);
        const meta_idx = try self.addLoopMeta(.{
            .body_start = body_start,
            .body_len = body_len,
            .loop_kind = .for_loop,
            .cond_chan = src_vec_chan,
            .iter_chan = iter_chan,
            .elem_type = elem_type,
        });
        try self.emit(Node.makeSink(.scalar_loop, out, meta_idx));
        return out;
    }

    /// 标量 while 循环（含 break/continue）
    fn compileWhileScalar(self: *IRBuilder, ws: anytype) BuildError!u16 {
        const body_start: u32 = @intCast(self.nodes.items.len);

        try self.pushScope();
        defer self.popScope();
        const cond_chan = try self.compileExpr(ws.condition);
        const cond_len: u32 = @intCast(self.nodes.items.len - body_start);
        _ = try self.compileExpr(ws.body);
        const body_len: u32 = @intCast(self.nodes.items.len - body_start);

        const out = try self.allocChannel(.i64_chan);
        const meta_idx = try self.addLoopMeta(.{
            .body_start = body_start,
            .body_len = body_len,
            .loop_kind = .while_loop,
            .cond_len = cond_len,
            .cond_chan = cond_chan,
        });
        try self.emit(Node.makeSink(.scalar_loop, out, meta_idx));
        return out;
    }

    /// 编译 iterable 表达式为 vec_source 节点
    fn compileVecSource(self: *IRBuilder, iterable: *ast.Expr) BuildError!u16 {
        switch (iterable.*) {
            .binary => |b| {
                if (b.op == .range or b.op == .range_inclusive) {
                    // range 表达式：start..end 或 start..=end
                    const start_chan = try self.compileExpr(b.left);
                    const end_chan = try self.compileExpr(b.right);

                    // 尝试从常量推导长度
                    var length: ?u32 = null;
                    const start_meta = self.channels.get(start_chan);
                    if (start_meta.chan_type.isInt()) {
                        // 查找常量值
                        if (self.findConstVal(start_chan)) |sv| {
                            if (self.findConstVal(end_chan)) |ev| {
                                const s_val: i64 = @intCast(sv);
                                const e_val: i64 = @intCast(ev);
                                const len: i64 = if (b.op == .range_inclusive) e_val - s_val + 1 else e_val - s_val;
                                if (len >= 0) length = @intCast(len);
                            }
                        }
                    }

                    const elem_type = self.channels.get(start_chan).chan_type;
                    const meta_idx = try self.addVectorMeta(.{
                        .vec_op = .range_source,
                        .length = length,
                        .elem_type = elem_type,
                    });

                    const out = try self.allocChannel(elem_type);
                    try self.emit(Node.makeBinary(.vec_source, out, meta_idx, start_chan, end_chan));
                    return out;
                }
                return error.UnsupportedExpr;
            },
            .array_literal => |al| {
                // 数组字面量 → vec_source(array_source)
                // Phase 2：编译每个元素，发射 array_make + vec_source
                var elem_chans: std.ArrayList(u16) = .empty;
                defer elem_chans.deinit(self.allocator);

                var elem_type: ChanType = .i64_chan;
                for (al.elements) |elem| {
                    const ch = try self.compileExpr(elem);
                    try elem_chans.append(self.allocator, ch);
                    elem_type = self.channels.get(ch).chan_type;
                }

                const length: ?u32 = @intCast(al.elements.len);
                const meta_idx = try self.addVectorMeta(.{
                    .vec_op = .array_source,
                    .length = length,
                    .elem_type = elem_type,
                });

                const out = try self.allocChannel(elem_type);
                // vec_source 的 inputs[0] = 第一个元素通道（简化：执行引擎从数组通道读取）
                const first_chan = if (al.elements.len > 0) elem_chans.items[0] else 0;
                try self.emit(Node.makeSink(.vec_source, out, meta_idx));
                _ = first_chan; // Phase 2 简化：array_source 的元素通过通道空间传递
                return out;
            },
            else => return error.UnsupportedExpr,
        }
    }

    /// 从通道查找编译期常量值
    fn findConstVal(self: *IRBuilder, chan: u16) ?i128 {
        // 遍历节点流，找到 output == chan 的 const_i 节点
        for (self.nodes.items) |n| {
            if (n.output == chan and n.op == .const_i) {
                if (n.meta_index > 0 and n.meta_index < self.scalar_metas.items.len) {
                    const meta = self.scalar_metas.items[n.meta_index];
                    if (meta.const_val) |cv| {
                        return switch (cv) {
                            .int_val => |v| v,
                            else => null,
                        };
                    }
                }
            }
        }
        return null;
    }

    /// 编译归约表达式（vec_fold）
    /// 用于 sum(range) / max(range) / min(range) 等场景
    fn compileFold(
        self: *IRBuilder,
        fold_op: NodeOp,
        init_chan: u16,
        src_vec_chan: u16,
    ) BuildError!u16 {
        const elem_type = self.channels.get(src_vec_chan).chan_type;
        const meta_idx = try self.addVectorMeta(.{
            .inner_op = fold_op,
            .elem_type = elem_type,
        });

        const out = try self.allocChannel(elem_type);
        // vec_fold 是二元节点：inputs[0] = src_vec, inputs[1] = init_val
        const inputs: [4]u16 = .{ src_vec_chan, init_chan, 0, 0 };
        try self.emit(Node{
            .op = .vec_fold,
            .input_count = 2,
            .output = out,
            .meta_index = meta_idx,
            .inputs = inputs,
        });
        return out;
    }

    /// 编译前缀计算（vec_scan）
    /// 用于递归线性化：fib(n) → scan(step, (0,1)) |> take(n) |> last
    fn compileScan(
        self: *IRBuilder,
        scan_op: NodeOp,
        init_chan: u16,
        src_vec_chan: u16,
    ) BuildError!u16 {
        const elem_type = self.channels.get(src_vec_chan).chan_type;
        const meta_idx = try self.addVectorMeta(.{
            .inner_op = scan_op,
            .elem_type = elem_type,
        });

        const out = try self.allocChannel(elem_type);
        const inputs: [4]u16 = .{ src_vec_chan, init_chan, 0, 0 };
        try self.emit(Node{
            .op = .vec_scan,
            .input_count = 2,
            .output = out,
            .meta_index = meta_idx,
            .inputs = inputs,
        });
        return out;
    }

    // ════════════════════════════════════════════
    // Phase 3: 门控/路由/竞争/清理编译
    // ════════════════════════════════════════════

    /// 编译 ? 传播表达式
    ///
    /// expr? 编译为门控节点链：
    ///   N0: ch_val = <expr>
    ///   N1: ch_ok = gate_check(ch_val)       // 检查 is_ok
    ///   N2: ch_inner = gate_get_ok(ch_val)   // 提取 Ok 值
    ///
    /// 后续 ? 点的 gate_propagate 会 OR 传播错误掩码。
    /// gate_select 在链尾按 mask 选择最终结果。
    fn compilePropagate(self: *IRBuilder, inner_expr: *ast.Expr) BuildError!u16 {
        // 编译内部表达式
        const val_chan = try self.compileExpr(inner_expr);

        // gate_check：检查 is_ok，输出 mask_chan
        const check_meta_idx = try self.addGateMeta(.{
            .gate_kind = .check,
            .error_type = 0, // Phase 3 简化：错误类型暂不跟踪
        });
        const ok_chan = try self.allocChannel(.mask_chan);
        try self.emit(Node.makeUnary(.gate_check, ok_chan, check_meta_idx, val_chan));

        // gate_get_ok：提取 Ok 值
        const get_ok_meta_idx = try self.addGateMeta(.{ .gate_kind = .get_ok });
        const inner_chan = try self.allocChannel(self.channels.get(val_chan).chan_type);
        try self.emit(Node.makeUnary(.gate_get_ok, inner_chan, get_ok_meta_idx, val_chan));

        return inner_chan;
    }

    /// 编译 defer 语句
    ///
    /// defer expr 编译为：
    ///   1. 记录 defer 体节点序列的起始位置
    ///   2. 编译 defer 体表达式
    ///   3. 发射 cleanup_register 节点，meta 记录体范围
    ///   4. halt 时 LIFO 执行
    fn compileDefer(self: *IRBuilder, ds: anytype) BuildError!void {
        const body_start: u32 = @intCast(self.nodes.items.len);

        // 编译 defer 体（表达式语句）
        _ = try self.compileExpr(ds.expr);

        const body_len: u32 = @intCast(self.nodes.items.len - body_start);

        // 发射 cleanup_register 节点
        const cleanup_meta_idx = try self.addCleanupMeta(.{
            .trigger = .any_halt,
            .body_start = body_start,
            .body_len = body_len,
            .order = @intCast(self.cleanup_metas.items.len),
        });

        // cleanup_register 不产生值，输出到 unit 通道
        const unit_chan = try self.allocChannel(.unit_chan);
        try self.emit(Node.makeSink(.cleanup_register, unit_chan, cleanup_meta_idx));
    }

    /// 编译 throw 语句
    ///
    /// throw expr 编译为 halt_throw 节点：
    ///   N0: ch_err = <expr>
    ///   N1: halt_throw(ch_err)
    fn compileThrow(self: *IRBuilder, ts: anytype) BuildError!void {
        const err_chan = try self.compileExpr(ts.expr);

        // halt_throw 输出到错误通道
        const out = try self.allocChannel(.ref_chan);
        const gate_meta_idx = try self.addGateMeta(.{ .gate_kind = .make_err });
        try self.emit(Node.makeUnary(.halt_throw, out, gate_meta_idx, err_chan));
    }

    /// 编译 select 多路复用
    ///
    /// select { ch1.recv() => v => body1; ch2.recv() => v => body2 }
    /// 编译为竞争图：
    ///   N0: race_source(ch1)          // 检查 ch1 就绪性
    ///   N1: race_source(ch2)          // 检查 ch2 就绪性
    ///   N2: race_select(r1, r2) → winner  // 选第一个就绪的
    ///   N3: route_dispatch(winner)    // 按 winner 索引执行对应 body 子图
    ///   body1 子图节点...（被 body_skip 跳过，由 route_dispatch 按需执行）
    ///   body2 子图节点...（同上）
    fn compileSelect(self: *IRBuilder, arms: []const ast.SelectArm) BuildError!u16 {
        if (arms.len == 0) return error.UnsupportedExpr;

        const arena_alloc = self.arena.allocator();
        const arm_count = arms.len;

        // 1. 编译每个分支的通道表达式，发射 race_source
        var race_source_chans = try arena_alloc.alloc(u16, arm_count);
        for (arms, 0..) |arm, i| {
            const ch_expr = switch (arm) {
                .receive => |r| r.channel_expr,
                .timeout => |t| t.duration,
            };
            const src_chan = try self.compileExpr(ch_expr);

            const race_meta_idx = try self.addRaceMeta(.{
                .source_count = 1,
                .timeout_ms = null,
            });
            const race_out = try self.allocChannel(.mask_chan);
            try self.emit(Node.makeUnary(.race_source, race_out, race_meta_idx, src_chan));
            race_source_chans[i] = race_out;
        }

        // 2. 发射 race_select 节点（选择第一个就绪的）
        const select_meta_idx = try self.addRaceMeta(.{
            .source_count = @intCast(arm_count),
            .timeout_ms = null,
        });

        const winner_chan = try self.allocChannel(.mask_chan);
        // race_select 的输入是所有 race_source 的输出（最多 4 个）
        var inputs: [4]u16 = .{ 0, 0, 0, 0 };
        const count = @min(arm_count, 4);
        for (0..count) |i| {
            inputs[i] = race_source_chans[i];
        }
        try self.emit(Node{
            .op = .race_select,
            .input_count = @intCast(count),
            .output = winner_chan,
            .meta_index = select_meta_idx,
            .inputs = inputs,
        });

        // 3. 编译每个 arm 的 body 为子图，记录起始位置和长度
        var body_starts = try arena_alloc.alloc(u32, arm_count);
        var body_lens = try arena_alloc.alloc(u32, arm_count);
        for (arms, 0..) |arm, i| {
            body_starts[i] = @intCast(self.nodes.items.len);
            // receive arm 的 binding 需要注册到作用域
            if (arm == .receive and arm.receive.binding != null) {
                try self.pushScope();
                // binding 绑定到 race_source 的输入通道（通道值本身）
                try self.defineVar(arm.receive.binding.?, race_source_chans[i], false);
            }
            const body_out = try self.compileExpr(switch (arm) {
                .receive => |r| r.body,
                .timeout => |t| t.body,
            });
            if (arm == .receive and arm.receive.binding != null) {
                self.popScope();
            }
            body_lens[i] = @intCast(self.nodes.items.len - body_starts[i]);
            // 记录每个 body 的输出通道（最后一个节点的 output）
            _ = body_out; // body 子图的输出由 route_dispatch 收集
        }

        // 4. 发射 route_dispatch 节点（按 winner 索引执行对应 body 子图）
        const route_meta_idx = try self.addRouteMeta(.{
            .trait_id = 0,
            .method_id = 0,
            .target_count = @intCast(arm_count),
            .body_starts = body_starts,
            .body_lens = body_lens,
        });

        const result_chan = try self.allocChannel(.ref_chan);
        try self.emit(Node.makeUnary(.route_dispatch, result_chan, route_meta_idx, winner_chan));

        return result_chan;
    }

    /// 编译 non_null_assert (expr!)：断言 nullable 非 null，提取内部值
    /// 等价于 nullable_unwrap，null 时 panic
    fn compileNonNullAssert(self: *IRBuilder, expr: *const ast.Expr) BuildError!u16 {
        const src_chan = try self.compileExpr(expr);
        const src_meta = self.channels.get(src_chan);

        // 如果已经是 nullable_chan，直接 unwrap
        if (src_meta.chan_type == .nullable_chan) {
            const out = try self.allocChannel(src_meta.inner_type);
            try self.emit(Node.makeUnary(.nullable_unwrap, out, 0, src_chan));
            return out;
        }

        // 如果是 ref_chan，包装为 nullable 后 unwrap（null 时 panic）
        if (src_meta.chan_type == .ref_chan) {
            const nullable_chan = try self.channels.allocNullable(.ref_chan);
            try self.emit(Node.makeUnary(.nullable_make, nullable_chan, 0, src_chan));
            const out = try self.allocChannel(.ref_chan);
            try self.emit(Node.makeUnary(.nullable_unwrap, out, 0, nullable_chan));
            return out;
        }

        // 其他类型：直接传递（不可能为 null）
        return src_chan;
    }

    /// 编译 safe_access (obj?.field)：null 时返回 null，否则访问字段
    /// 简化实现：编译为 nullable 包装 + is_null 检查 + unwrap
    /// 完整的字段访问在 Phase 6 简化为直接返回 unwrap 后的对象（字段访问需 sema 支持）
    fn compileSafeAccess(self: *IRBuilder, object: *const ast.Expr, field: []const u8) BuildError!u16 {
        _ = field; // Phase 6 简化：字段访问需 sema 层支持，暂不实现

        const obj_chan = try self.compileExpr(object);
        const obj_meta = self.channels.get(obj_chan);

        // 如果是 ref_chan，先包装为 nullable
        const nullable_chan = if (obj_meta.chan_type == .nullable_chan)
            obj_chan
        else if (obj_meta.chan_type == .ref_chan) blk: {
            const nc = try self.channels.allocNullable(.ref_chan);
            try self.emit(Node.makeUnary(.nullable_make, nc, 0, obj_chan));
            break :blk nc;
        } else obj_chan;

        // 检查是否为 null
        const is_null_chan = try self.allocChannel(.bool_chan);
        try self.emit(Node.makeUnary(.nullable_is_null, is_null_chan, 0, nullable_chan));

        // 如果非 null，unwrap
        const unwrapped_chan = try self.allocChannel(obj_meta.chan_type);
        try self.emit(Node.makeUnary(.nullable_unwrap, unwrapped_chan, 0, nullable_chan));

        // 用 vec_select 按 is_null 选择结果（null 时返回 null）
        const result_chan = try self.allocChannel(.ref_chan);
        const null_chan = try self.allocChannel(.null_chan);
        try self.emit(Node.makeSink(.const_null, null_chan, 0));
        // vec_select: inputs[0]=cond, inputs[1]=then_val, inputs[2]=else_val
        const sel_inputs: [4]u16 = .{ is_null_chan, null_chan, unwrapped_chan, 0 };
        try self.emit(Node{
            .op = .vec_select,
            .input_count = 3,
            .output = result_chan,
            .meta_index = 0,
            .inputs = sel_inputs,
        });

        return result_chan;
    }

    /// 从表达式推断类型名（用于用户自定义方法调用 obj.method()）
    /// 仅支持构造器调用和标识符引用构造器的场景
    fn inferTypeNameFromExpr(self: *IRBuilder, expr: *const ast.Expr) ?[]const u8 {
        switch (expr.*) {
            .call => |c| {
                if (c.callee.* == .identifier) {
                    if (self.ctor_table.get(c.callee.identifier.name)) |ctor| {
                        return ctor.type_name;
                    }
                }
                return null;
            },
            .identifier => |id| {
                if (self.ctor_table.get(id.name)) |ctor| {
                    if (ctor.fields.len == 0) return ctor.type_name;
                }
                return null;
            },
            else => return null,
        }
    }

    /// 编译方法调用：obj.method(args)
    /// safe=true 时为 obj?.method(args)，先做 null 检查
    fn compileMethodCall(self: *IRBuilder, object: *ast.Expr, method: []const u8, arguments: []*ast.Expr, safe: bool) BuildError!u16 {
        const obj_chan = try self.compileExpr(object);

        // safe_method_call：obj?.method(args) — obj 为 null 时返回 null
        if (safe) {
            return try self.compileSafeMethodCall(obj_chan, object, method, arguments);
        }

        return try self.dispatchMethodCall(obj_chan, object, method, arguments);
    }

    /// 安全方法调用：obj?.method(args)
    /// obj 为 null 时返回 null，否则调用方法
    fn compileSafeMethodCall(self: *IRBuilder, obj_chan: u16, object: *ast.Expr, method: []const u8, arguments: []*ast.Expr) BuildError!u16 {
        const obj_meta = self.channels.get(obj_chan);
        // 非 nullable/ref 直接调用
        if (obj_meta.chan_type != .nullable_chan and obj_meta.chan_type != .ref_chan) {
            return try self.dispatchMethodCall(obj_chan, object, method, arguments);
        }
        // 包装为 nullable
        const nullable_chan = if (obj_meta.chan_type == .nullable_chan)
            obj_chan
        else blk: {
            const nc = try self.channels.allocNullable(.ref_chan);
            try self.emit(Node.makeUnary(.nullable_make, nc, 0, obj_chan));
            break :blk nc;
        };
        const is_null_chan = try self.allocChannel(.bool_chan);
        try self.emit(Node.makeUnary(.nullable_is_null, is_null_chan, 0, nullable_chan));
        const unwrapped_chan = try self.allocChannel(.ref_chan);
        try self.emit(Node.makeUnary(.nullable_unwrap, unwrapped_chan, 0, nullable_chan));

        // then 子图：unwrapped.method(args)
        const else_start: u32 = @intCast(self.nodes.items.len);
        const null_out = try self.allocChannel(.null_chan);
        try self.emit(Node.makeSink(.const_null, null_out, 0));
        const else_len: u32 = @intCast(self.nodes.items.len - else_start);

        const then_start: u32 = @intCast(self.nodes.items.len);
        const then_out = try self.dispatchMethodCall(unwrapped_chan, object, method, arguments);
        if (self.nodes.items.len == then_start) {
            const load_chan = try self.allocChannel(self.channels.get(then_out).chan_type);
            try self.emit(Node.makeUnary(.load, load_chan, 0, then_out));
        }
        const then_len: u32 = @intCast(self.nodes.items.len - then_start);

        const winner_chan = try self.allocChannel(.i64_chan);
        const cast_meta = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64 });
        try self.emit(Node.makeUnary(.cast, winner_chan, cast_meta, is_null_chan));

        const arena_alloc = self.arena.allocator();
        const body_starts = try arena_alloc.alloc(u32, 2);
        const body_lens = try arena_alloc.alloc(u32, 2);
        body_starts[0] = else_start;
        body_lens[0] = else_len;
        body_starts[1] = then_start;
        body_lens[1] = then_len;

        const result_type = self.channels.get(self.nodes.items[then_start + then_len - 1].output).chan_type;
        const result_out = try self.allocChannel(result_type);
        const route_meta_idx = try self.addRouteMeta(.{
            .trait_id = 0,
            .method_id = 0,
            .target_count = 2,
            .body_starts = body_starts,
            .body_lens = body_lens,
        });
        try self.emit(Node.makeUnary(.route_dispatch, result_out, route_meta_idx, winner_chan));
        return result_out;
    }

    /// 按方法名分派：内置方法 + 用户自定义方法
    fn dispatchMethodCall(self: *IRBuilder, obj_chan: u16, object: *ast.Expr, method: []const u8, arguments: []*ast.Expr) BuildError!u16 {
        // ── 内置方法（按名称分派） ──
        if (std.mem.eql(u8, method, "await")) {
            // obj.await() → orbit_async_join
            // 结果类型默认 i64（无类型追踪，大多数 async 函数返回标量）
            // engine 的 execOrbitAsyncJoin 不依赖 meta_index，直接从 handle 读取结果
            const out = try self.allocChannel(.i64_chan);
            try self.emit(Node.makeUnary(.orbit_async_join, out, 0, obj_chan));
            return out;
        }
        if (std.mem.eql(u8, method, "status")) {
            // obj.status() → orbit_async_status，返回 i64
            const out = try self.allocChannel(.i64_chan);
            try self.emit(Node.makeUnary(.orbit_async_status, out, 0, obj_chan));
            return out;
        }
        if (std.mem.eql(u8, method, "send")) {
            // ch.send(v) → orbit_chan_send
            if (arguments.len != 1) return error.UnsupportedExpr;
            const val_chan = try self.compileExpr(arguments[0]);
            return try self.emitOrbitSend(obj_chan, val_chan);
        }
        if (std.mem.eql(u8, method, "recv")) {
            // ch.recv() → orbit_chan_recv，结果类型默认 i64
            return try self.emitOrbitRecv(obj_chan, .i64_chan);
        }
        if (std.mem.eql(u8, method, "tryRecv")) {
            // ch.tryRecv() → orbit_chan_try_recv，返回 nullable
            return try self.emitOrbitTryRecv(obj_chan, .i64_chan);
        }
        if (std.mem.eql(u8, method, "close")) {
            // ch.close() → channel_close，返回 unit
            const out = try self.allocChannel(.unit_chan);
            try self.emit(Node.makeUnary(.channel_close, out, 0, obj_chan));
            return out;
        }
        if (std.mem.eql(u8, method, "len")) {
            // obj.len() → string_len 或 array_len（按 AST 推断）
            const is_string = switch (object.*) {
                .string_literal, .string_interpolation => true,
                else => false,
            };
            if (is_string) {
                const out = try self.allocChannel(.i64_chan);
                try self.emit(Node.makeUnary(.string_len, out, 0, obj_chan));
                return out;
            }
            const out = try self.allocChannel(.i64_chan);
            try self.emit(Node.makeUnary(.array_len, out, 0, obj_chan));
            return out;
        }
        if (std.mem.eql(u8, method, "push")) {
            // arr.push(v) → array_push
            if (arguments.len != 1) return error.UnsupportedExpr;
            const val_chan = try self.compileExpr(arguments[0]);
            const out = try self.allocChannel(.unit_chan);
            try self.emit(Node.makeBinary(.array_push, out, 0, obj_chan, val_chan));
            return out;
        }
        if (std.mem.eql(u8, method, "message")) {
            // e.message() → error_message，返回 str ref
            const out = try self.allocChannel(.ref_chan);
            try self.emit(Node.makeUnary(.error_message, out, 0, obj_chan));
            return out;
        }
        if (std.mem.eql(u8, method, "type_name")) {
            // obj.type_name() → obj_type_name，返回 str ref
            const out = try self.allocChannel(.ref_chan);
            try self.emit(Node.makeUnary(.obj_type_name, out, 0, obj_chan));
            return out;
        }

        // ── 用户自定义方法：obj.method(args) → call("TypeName.method", [obj, ...args]) ──
        if (self.inferTypeNameFromExpr(object)) |type_name| {
            const arena_alloc = self.arena.allocator();
            const mangled = try std.fmt.allocPrint(arena_alloc, "{s}.{s}", .{ type_name, method });
            if (self.func_table.get(mangled)) |func_idx| {
                const func = self.functions.items[func_idx];
                // 编译参数：self + 实参
                var arg_chans = try arena_alloc.alloc(u16, arguments.len + 1);
                arg_chans[0] = obj_chan;
                for (arguments, 0..) |arg, i| {
                    arg_chans[i + 1] = try self.compileExpr(arg);
                }
                const out = try self.allocChannel(self.channels.get(func.return_channel).chan_type);
                const call_meta_idx = try self.addCallMeta(.{
                    .func_index = func_idx,
                    .arg_count = @intCast(arg_chans.len),
                });
                var inputs: [4]u16 = .{ 0, 0, 0, 0 };
                for (arg_chans, 0..) |ch, i| {
                    if (i < 4) inputs[i] = ch;
                }
                try self.emit(Node{
                    .op = .call,
                    .input_count = @intCast(@min(arg_chans.len, 4)),
                    .output = out,
                    .meta_index = call_meta_idx,
                    .inputs = inputs,
                });
                return out;
            }
        }

        return error.UnsupportedExpr;
    }

    /// 收集表达式中的自由变量（不在 param_names 中的标识符）
    fn collectFreeVars(self: *IRBuilder, expr: *const ast.Expr, param_names: []const []const u8, out: *std.StringHashMap(void)) void {
        switch (expr.*) {
            .identifier => |id| {
                // 排除 lambda 参数
                for (param_names) |pn| {
                    if (std.mem.eql(u8, pn, id.name)) return;
                }
                // 只收集当前作用域中存在的变量（可捕获的）
                if (self.lookupVar(id.name) != null) {
                    out.put(id.name, {}) catch {};
                }
            },
            .binary => |b| {
                self.collectFreeVars(b.left, param_names, out);
                self.collectFreeVars(b.right, param_names, out);
            },
            .unary => |u| self.collectFreeVars(u.operand, param_names, out),
            .call => |c| {
                self.collectFreeVars(c.callee, param_names, out);
                for (c.arguments) |a| self.collectFreeVars(a, param_names, out);
            },
            .if_expr => |ie| {
                self.collectFreeVars(ie.condition, param_names, out);
                self.collectFreeVars(ie.then_branch, param_names, out);
                if (ie.else_branch) |eb| self.collectFreeVars(eb, param_names, out);
            },
            .block => |blk| {
                for (blk.statements) |s| self.collectFreeVarsStmt(s, param_names, out);
                if (blk.trailing_expr) |te| self.collectFreeVars(te, param_names, out);
            },
            .method_call => |mc| {
                self.collectFreeVars(mc.object, param_names, out);
                for (mc.arguments) |a| self.collectFreeVars(a, param_names, out);
            },
            .field_access => |fa| self.collectFreeVars(fa.object, param_names, out),
            .index => |idx| {
                self.collectFreeVars(idx.object, param_names, out);
                self.collectFreeVars(idx.index, param_names, out);
            },
            .match => |m| {
                self.collectFreeVars(m.scrutinee, param_names, out);
                for (m.arms) |arm| self.collectFreeVars(arm.body, param_names, out);
            },
            .propagate => |p| self.collectFreeVars(p.expr, param_names, out),
            .non_null_assert => |nn| self.collectFreeVars(nn.expr, param_names, out),
            .safe_access => |sa| self.collectFreeVars(sa.object, param_names, out),
            .safe_method_call => |mc| {
                self.collectFreeVars(mc.object, param_names, out);
                for (mc.arguments) |a| self.collectFreeVars(a, param_names, out);
            },
            .assignment_expr => |a| {
                self.collectFreeVars(a.target, param_names, out);
                self.collectFreeVars(a.value, param_names, out);
            },
            .compound_assign => |ca| {
                self.collectFreeVars(ca.target, param_names, out);
                self.collectFreeVars(ca.value, param_names, out);
            },
            .string_interpolation => |si| {
                for (si.parts) |part| {
                    if (part == .expression) self.collectFreeVars(part.expression, param_names, out);
                }
            },
            else => {},
        }
    }

    fn collectFreeVarsStmt(self: *IRBuilder, stmt: *const ast.Stmt, param_names: []const []const u8, out: *std.StringHashMap(void)) void {
        switch (stmt.*) {
            .val_decl => |vd| self.collectFreeVars(vd.value, param_names, out),
            .var_decl => |vd| self.collectFreeVars(vd.value, param_names, out),
            .expression => |es| self.collectFreeVars(es.expr, param_names, out),
            .defer_stmt => |ds| self.collectFreeVars(ds.expr, param_names, out),
            else => {},
        }
    }

    /// 编译 lambda 表达式为匿名函数 + closure_make 节点
    /// 1. 收集自由变量（捕获上值）
    /// 2. 注册匿名函数（params = lambda参数 + 上值参数）
    /// 3. 编译函数体
    /// 4. 发射 closure_make 节点（携带上值通道）
    fn compileLambda(self: *IRBuilder, lam: anytype) BuildError!u16 {
        const arena_alloc = self.arena.allocator();

        // 提前分配 closure_make 的输出通道，以便预声明递归 lambda 名
        const closure_out_chan = try self.allocChannel(.ref_chan);
        // 如果有预声明的 lambda 名（val name = fun(...) { ... } 形式），先绑定到输出通道
        // 这样 lambda body 内可以递归引用自身
        var pre_decl_name: ?[]const u8 = null;
        if (self.pre_declared_lambda_names.items.len > 0) {
            pre_decl_name = self.pre_declared_lambda_names.items[self.pre_declared_lambda_names.items.len - 1];
            try self.scopeVar(pre_decl_name.?, closure_out_chan, false, null);
        }

        // 1. 收集自由变量
        var free_vars = std.StringHashMap(void).init(arena_alloc);
        defer free_vars.deinit();
        const body_expr: *const ast.Expr = switch (lam.body) {
            .block => |b| b,
            .expression => |e| e,
        };
        // 构造参数名列表
        var param_names = std.ArrayList([]const u8).empty;
        defer param_names.deinit(arena_alloc);
        for (lam.params) |p| param_names.append(arena_alloc, p.name) catch return error.OutOfMemory;
        self.collectFreeVars(body_expr, param_names.items, &free_vars);

        // 2. 收集上值通道（按插入顺序）
        var upvalue_names = std.ArrayList([]const u8).empty;
        defer upvalue_names.deinit(arena_alloc);
        var upvalue_chans = std.ArrayList(u16).empty;
        defer upvalue_chans.deinit(arena_alloc);
        var fv_it = free_vars.iterator();
        while (fv_it.next()) |entry| {
            if (self.lookupVar(entry.key_ptr.*)) |binding| {
                upvalue_names.append(arena_alloc, entry.key_ptr.*) catch return error.OutOfMemory;
                upvalue_chans.append(arena_alloc, binding.chan) catch return error.OutOfMemory;
            }
        }

        // 3. 注册匿名函数
        const lambda_counter = self.lambda_counter;
        self.lambda_counter += 1;
        const func_name = std.fmt.allocPrint(arena_alloc, "__lambda_{d}", .{lambda_counter}) catch return error.OutOfMemory;
        const func_idx: u16 = @intCast(self.functions.items.len);
        try self.func_table.put(func_name, func_idx);

        // 返回类型
        const return_type = chanTypeFromTypeNode(lam.return_type) orelse .i64_chan;
        const placeholder_return_chan = try self.allocChannel(return_type);
        try self.functions.append(arena_alloc, .{
            .name = func_name,
            .node_start = 0,
            .node_count = 0,
            .param_channels = &.{},
            .return_channel = placeholder_return_chan,
            .is_entry = false,
            .is_async = lam.is_async,
        });

        // 4. 编译函数体（params = lambda参数 + 上值参数）
        const saved_return_chan = self.current_return_chan;
        const lambda_body_start: u32 = @intCast(self.nodes.items.len);
        const node_start: u32 = lambda_body_start;
        const chan_start: u16 = self.channels.count();

        try self.pushScope();
        // 分配参数通道
        var all_param_chans = try arena_alloc.alloc(u16, lam.params.len + upvalue_names.items.len);
        for (lam.params, 0..) |param, i| {
            const chan_type = if (param.type_annotation) |tn|
                chanTypeFromTypeNode(tn) orelse .i64_chan
            else
                .i64_chan;
            const chan = try self.allocChannel(chan_type);
            all_param_chans[i] = chan;
            try self.defineVar(param.name, chan, false);
        }
        // 上值参数通道
        for (upvalue_names.items, 0..) |name, i| {
            const idx = lam.params.len + i;
            const upval_chan_type = self.channels.get(upvalue_chans.items[i]).chan_type;
            const chan = try self.allocChannel(upval_chan_type);
            all_param_chans[idx] = chan;
            try self.defineVar(name, chan, false);
        }
        const return_chan = placeholder_return_chan;
        self.current_return_chan = return_chan;

        // 编译函数体
        const body_chan = try self.compileExpr(body_expr);
        try self.emit(Node.makeUnary(.halt_return, return_chan, 0, body_chan));

        self.current_return_chan = saved_return_chan;
        self.popScope();

        const node_count: u32 = @intCast(self.nodes.items.len - node_start);
        const chan_end: u16 = self.channels.count();
        self.functions.items[func_idx].node_start = node_start;
        self.functions.items[func_idx].node_count = node_count;
        self.functions.items[func_idx].param_channels = all_param_chans;
        self.functions.items[func_idx].local_chan_start = chan_start;
        self.functions.items[func_idx].local_chan_count = chan_end - chan_start;

        // 5. 发射 closure_make 节点
        const closure_meta_idx = try self.addClosureMeta(.{
            .func_index = func_idx,
            .upvalue_count = @intCast(upvalue_chans.items.len),
            .result_type = return_type,
            .body_start = lambda_body_start,
            .body_len = node_count,
        });

        var inputs: [4]u16 = .{ 0, 0, 0, 0 };
        for (upvalue_chans.items, 0..) |ch, i| {
            if (i < 4) inputs[i] = ch;
        }
        try self.emit(Node{
            .op = .closure_make,
            .input_count = @intCast(@min(upvalue_chans.items.len, 4)),
            .output = closure_out_chan,
            .meta_index = closure_meta_idx,
            .inputs = inputs,
        });
        return closure_out_chan;
    }

    /// 编译间接调用（通过 closure 值调用）
    /// inputs[0] = closure_chan, inputs[1..M] = arg_channels
    fn compileCallIndirect(self: *IRBuilder, closure_chan: u16, arguments: []*ast.Expr) BuildError!u16 {
        const arena_alloc = self.arena.allocator();
        var arg_chans = try arena_alloc.alloc(u16, arguments.len);
        for (arguments, 0..) |arg, i| {
            arg_chans[i] = try self.compileExpr(arg);
        }

        // 结果类型默认 i64（无法在编译期确定闭包返回类型）
        const out = try self.allocChannel(.i64_chan);
        const call_meta_idx = try self.addCallMeta(.{
            .func_index = 0, // 运行时从 closure 值读取
            .arg_count = @intCast(arguments.len + 1), // +1 for closure_chan
        });

        var inputs: [4]u16 = .{ 0, 0, 0, 0 };
        inputs[0] = closure_chan;
        for (arg_chans, 0..) |ch, i| {
            if (i + 1 < 4) inputs[i + 1] = ch;
        }
        try self.emit(Node{
            .op = .call_indirect,
            .input_count = @intCast(@min(arguments.len + 1, 4)),
            .output = out,
            .meta_index = call_meta_idx,
            .inputs = inputs,
        });
        return out;
    }

    /// 编译 atomic 表达式：atomic value → Cell 通道（线程安全的可变引用）
    /// 实现为 alloc + store，将值存储在堆上
    fn compileAtomicExpr(self: *IRBuilder, value_expr: *const ast.Expr) BuildError!u16 {
        const val_chan = try self.compileExpr(value_expr);
        const val_meta = self.channels.get(val_chan);
        // 分配 Cell 通道（与 var_decl 相同的模式）
        const cell_chan = try self.allocCellChannel(val_meta.chan_type);
        try self.emit(Node.makeUnary(.load, cell_chan, 0, val_chan));
        return cell_chan;
    }

    /// 编译 lazy 表达式：lazy expr → 延迟计算的 thunk（闭包）
    /// 实现为无参闭包，首次调用时计算 expr
    fn compileLazyExpr(self: *IRBuilder, expr: *const ast.Expr) BuildError!u16 {
        // 简化实现：直接编译表达式，返回其通道
        // 完整实现需要创建一个 thunk 闭包，在首次访问时才计算
        // 当前 Glue IR 没有 thunk 节点，使用直接求值（不影响正确性，只影响惰性语义）
        return try self.compileExpr(expr);
    }

    /// 编译 spawn 表达式：spawn expr → orbit_async_create（不自动 await）
    /// expr 应为 async 函数调用或 lambda
    fn compileSpawnExpr(self: *IRBuilder, expr: *const ast.Expr) BuildError!u16 {
        // 如果是函数调用，编译为 async create（不 join）
        switch (expr.*) {
            .call => |c| {
                // 检查是否为已注册的 async 函数
                const func_name = switch (c.callee.*) {
                    .identifier => |id| id.name,
                    else => {
                        // 非函数名调用：先编译为 lambda 变量，然后 spawn
                        const lambda_chan = try self.compileExpr(expr);
                        return lambda_chan;
                    },
                };

                if (self.func_table.get(func_name)) |func_idx| {
                    const func = self.functions.items[func_idx];
                    if (func.is_async) {
                        // 编译参数为通道
                        var arg_chans_buf: [4]u16 = .{ 0, 0, 0, 0 };
                        const arg_count = @min(c.arguments.len, 4);
                        for (0..arg_count) |ai| {
                            arg_chans_buf[ai] = try self.compileExpr(c.arguments[ai]);
                        }
                        return try self.emitOrbitCreate(func_idx, arg_chans_buf[0..arg_count], func);
                    }
                    // 非 async 函数：包装为 async lambda 后 spawn
                    // 简化：直接调用（同步执行）
                    return try self.compileCall(c.callee, c.arguments);
                }

                // 未知函数：尝试构造器或内置
                return try self.compileCall(c.callee, c.arguments);
            },
            .lambda => |lam| {
                // 编译 lambda 为 async 闭包，然后 spawn
                const lambda_chan = try self.compileLambda(lam);
                // 对于 spawn，直接返回 lambda 通道
                // 完整实现需要将 lambda 包装为 async task
                return lambda_chan;
            },
            else => {
                // 其他表达式：直接编译（可能只是引用一个已有的 async handle）
                return try self.compileExpr(expr);
            },
        }
    }

    /// 编译 inline_trait_value：trait { methods } → record of closures
    /// 每个方法编译为闭包，存储在 record 字段中
    fn compileInlineTraitValue(self: *IRBuilder, methods: []ast.MethodDecl) BuildError!u16 {
        // 创建一个 record，每个方法作为一个字段
        const field_count = methods.len;
        const len_chan = try self.allocChannel(.i64_chan);
        const len_meta = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64, .const_val = .{ .int_val = @intCast(field_count) } });
        try self.emit(Node.makeSink(.const_i, len_chan, len_meta));

        const record_chan = try self.allocChannel(.ref_chan);
        try self.emit(Node.makeUnary(.array_make, record_chan, 0, len_chan));

        // 为每个方法创建闭包并存储到 record
        for (methods, 0..) |*method, i| {
            // 编译方法体为 lambda
            const method_chan = blk: {
                if (method.body) |body| {
                    // 有方法体：构造 lambda Expr 并编译
                    const lam_expr = self.allocator.create(ast.Expr) catch return error.OutOfMemory;
                    lam_expr.* = .{ .lambda = .{
                        .params = method.params,
                        .body = .{ .block = body },
                        .is_async = false,
                        .return_type = method.return_type,
                    } };
                    break :blk try self.compileExpr(lam_expr);
                } else {
                    // 无方法体：存储 unit
                    const ch = try self.allocChannel(.unit_chan);
                    try self.emit(Node.makeSink(.const_unit, ch, 0));
                    break :blk ch;
                }
            };

            const idx_chan = try self.allocChannel(.i64_chan);
            const idx_meta = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64, .const_val = .{ .int_val = @intCast(i) } });
            try self.emit(Node.makeSink(.const_i, idx_chan, idx_meta));
            try self.emit(Node.makeTernary(.array_set, record_chan, 0, record_chan, idx_chan, method_chan));
        }

        return record_chan;
    }

    /// 编译 Elvis 操作符 (left ?? right)：left 非 null 取 left，否则取 right
    /// 等价于 nullable_unwrap_or
    fn compileElvis(self: *IRBuilder, left: *const ast.Expr, right: *const ast.Expr) BuildError!u16 {
        const left_chan = try self.compileExpr(left);
        const right_chan = try self.compileExpr(right);
        const left_meta = self.channels.get(left_chan);

        // 如果 left 不是 nullable/ref，直接返回 left（不可能为 null）
        if (left_meta.chan_type != .nullable_chan and left_meta.chan_type != .ref_chan) {
            return left_chan;
        }

        // 如果是 ref_chan，包装为 nullable
        const nullable_chan = if (left_meta.chan_type == .nullable_chan)
            left_chan
        else blk: {
            const nc = try self.channels.allocNullable(left_meta.chan_type);
            try self.emit(Node.makeUnary(.nullable_make, nc, 0, left_chan));
            break :blk nc;
        };

        // nullable_unwrap_or(nullable_chan, right_chan)
        const inner_type = if (left_meta.chan_type == .nullable_chan) left_meta.inner_type else left_meta.chan_type;
        const out = try self.allocChannel(inner_type);
        try self.emit(Node.makeBinary(.nullable_unwrap_or, out, 0, nullable_chan, right_chan));
        return out;
    }
};

// ════════════════════════════════════════════════════════════════
// 类型推导辅助函数
// ════════════════════════════════════════════════════════════════

/// 过滤数字字面量中的下划线，返回干净数字字符串
fn filterDigits(raw: []const u8, buf: *[64]u8) []const u8 {
    var len: usize = 0;
    for (raw) |c| {
        if (c == '_') continue;
        if (len >= buf.len) break;
        buf[len] = c;
        len += 1;
    }
    return buf[0..len];
}

/// 整数后缀 → IntKind
fn intKindFromSuffix(suffix: ?[]const u8) ?IntKind {
    const s = suffix orelse return null;
    if (std.mem.eql(u8, s, "i8")) return .i8;
    if (std.mem.eql(u8, s, "i16")) return .i16;
    if (std.mem.eql(u8, s, "i32")) return .i32;
    if (std.mem.eql(u8, s, "i64")) return .i64;
    if (std.mem.eql(u8, s, "i128")) return .i128;
    if (std.mem.eql(u8, s, "u8")) return .u8;
    if (std.mem.eql(u8, s, "u16")) return .u16;
    if (std.mem.eql(u8, s, "u32")) return .u32;
    if (std.mem.eql(u8, s, "u64")) return .u64;
    if (std.mem.eql(u8, s, "u128")) return .u128;
    return null;
}

/// 浮点后缀 → FloatKind
fn floatKindFromSuffix(suffix: ?[]const u8) ?FloatKind {
    const s = suffix orelse return null;
    if (std.mem.eql(u8, s, "f16")) return .f16;
    if (std.mem.eql(u8, s, "f32")) return .f32;
    if (std.mem.eql(u8, s, "f64")) return .f64;
    if (std.mem.eql(u8, s, "f128")) return .f128;
    return null;
}

/// BinaryOp + 操作数类型 → NodeOp
fn binaryOpToNodeOp(op: ast.BinaryOp, operand_type: ChanType) BuildError!NodeOp {
    const is_int = operand_type.isInt();
    const is_float = operand_type.isFloat();
    const is_ref = operand_type == .ref_chan;
    return switch (op) {
        .add => if (is_int) .int_add else if (is_float) .float_add else if (is_ref) .string_concat else return error.UnsupportedType,
        .sub => if (is_int) .int_sub else if (is_float) .float_sub else return error.UnsupportedType,
        .mul => if (is_int) .int_mul else if (is_float) .float_mul else return error.UnsupportedType,
        .div => if (is_int) .int_div else if (is_float) .float_div else return error.UnsupportedType,
        .mod => if (is_int) .int_mod else return error.UnsupportedType,
        .bit_and => if (is_int) .int_and else return error.UnsupportedType,
        .bit_or => if (is_int) .int_or else return error.UnsupportedType,
        .bit_xor => if (is_int) .int_xor else return error.UnsupportedType,
        .shl => if (is_int) .int_shl else return error.UnsupportedType,
        .shr => if (is_int) .int_shr else return error.UnsupportedType,
        .eq => .cmp_eq,
        .not_eq => .cmp_ne,
        .lt => .cmp_lt,
        .gt => .cmp_gt,
        .lt_eq => .cmp_le,
        .gt_eq => .cmp_ge,
        .and_op => .bool_and,
        .or_op => .bool_or,
        .concat_list => if (is_ref) .string_concat else return error.UnsupportedType,
        else => return error.UnsupportedExpr,
    };
}

/// UnaryOp + 操作数类型 → NodeOp
fn unaryOpToNodeOp(op: ast.UnaryOp, operand_type: ChanType) BuildError!NodeOp {
    const is_int = operand_type.isInt();
    const is_float = operand_type.isFloat();
    return switch (op) {
        .neg => if (is_int) .int_neg else if (is_float) .float_neg else return error.UnsupportedType,
        .bit_not => if (is_int) .int_not else return error.UnsupportedType,
        .not => .bool_not,
    };
}

/// 二元运算结果类型
fn binaryResultType(op: ast.BinaryOp, operand_type: ChanType) ChanType {
    return switch (op) {
        .eq, .not_eq, .lt, .gt, .lt_eq, .gt_eq => .mask_chan, // 比较输出 mask
        .and_op, .or_op => .bool_chan,
        .concat_list => .ref_chan, // 字符串/数组拼接返回引用
        else => operand_type, // 算术/位运算继承操作数类型
    };
}

/// 从 TypeNode 推导通道类型
/// 原始类型返回精确 ChanType，用户自定义类型（ADT/record/newtype）返回 ref_chan
fn chanTypeFromTypeNode(type_node: ?*ast.TypeNode) ?ChanType {
    const tn = type_node orelse return null;
    return switch (tn.*) {
        .named => |n| {
            if (std.mem.eql(u8, n.name, "i8")) return .i8_chan;
            if (std.mem.eql(u8, n.name, "i16")) return .i16_chan;
            if (std.mem.eql(u8, n.name, "i32")) return .i32_chan;
            if (std.mem.eql(u8, n.name, "i64")) return .i64_chan;
            if (std.mem.eql(u8, n.name, "i128")) return .i128_chan;
            if (std.mem.eql(u8, n.name, "u8")) return .u8_chan;
            if (std.mem.eql(u8, n.name, "u16")) return .u16_chan;
            if (std.mem.eql(u8, n.name, "u32")) return .u32_chan;
            if (std.mem.eql(u8, n.name, "u64")) return .u64_chan;
            if (std.mem.eql(u8, n.name, "u128")) return .u128_chan;
            if (std.mem.eql(u8, n.name, "f16")) return .f16_chan;
            if (std.mem.eql(u8, n.name, "f32")) return .f32_chan;
            if (std.mem.eql(u8, n.name, "f64")) return .f64_chan;
            if (std.mem.eql(u8, n.name, "f128")) return .f128_chan;
            if (std.mem.eql(u8, n.name, "bool")) return .bool_chan;
            if (std.mem.eql(u8, n.name, "char")) return .char_chan;
            if (std.mem.eql(u8, n.name, "str")) return .ref_chan;
            if (std.mem.eql(u8, n.name, "unit")) return .unit_chan;
            // 用户自定义类型（ADT/record/newtype）→ ref_chan（堆引用）
            return .ref_chan;
        },
        .generic => |g| {
            // 泛型类型如 List<T>、Channel<T>、Atomic<T> → ref_chan
            if (std.mem.eql(u8, g.name, "Channel")) return .ref_chan;
            if (std.mem.eql(u8, g.name, "Atomic")) return .ref_chan;
            return .ref_chan;
        },
        .nullable => |nb| {
            // nullable 类型由 ChannelSpace.allocNullable 处理，这里返回 null 让调用方 fallback
            _ = nb;
            return null;
        },
        else => null,
    };
}

// ════════════════════════════════════════════════════════════════
// AST 遍历辅助：检测 break/continue
// ════════════════════════════════════════════════════════════════

fn astContainsBreakOrContinueExpr(expr: *const ast.Expr) bool {
    switch (expr.*) {
        .block => |b| {
            for (b.statements) |s| {
                if (astContainsBreakOrContinueStmt(s)) return true;
            }
            if (b.trailing_expr) |e| return astContainsBreakOrContinueExpr(e);
            return false;
        },
        .if_expr => |ie| {
            if (astContainsBreakOrContinueExpr(ie.then_branch)) return true;
            if (ie.else_branch) |e| return astContainsBreakOrContinueExpr(e);
            return false;
        },
        .binary => |b| {
            return astContainsBreakOrContinueExpr(b.left) or astContainsBreakOrContinueExpr(b.right);
        },
        .unary => |u| return astContainsBreakOrContinueExpr(u.operand),
        .call => |c| {
            if (astContainsBreakOrContinueExpr(c.callee)) return true;
            for (c.arguments) |a| {
                if (astContainsBreakOrContinueExpr(a)) return true;
            }
            return false;
        },
        .method_call => |mc| {
            if (astContainsBreakOrContinueExpr(mc.object)) return true;
            for (mc.arguments) |a| {
                if (astContainsBreakOrContinueExpr(a)) return true;
            }
            return false;
        },
        .safe_method_call => |mc| {
            if (astContainsBreakOrContinueExpr(mc.object)) return true;
            for (mc.arguments) |a| {
                if (astContainsBreakOrContinueExpr(a)) return true;
            }
            return false;
        },
        .field_access => |fa| return astContainsBreakOrContinueExpr(fa.object),
        .safe_access => |sa| return astContainsBreakOrContinueExpr(sa.object),
        .index => |idx| return astContainsBreakOrContinueExpr(idx.object) or astContainsBreakOrContinueExpr(idx.index),
        .non_null_assert => |nn| return astContainsBreakOrContinueExpr(nn.expr),
        .propagate => |p| return astContainsBreakOrContinueExpr(p.expr),
        .assignment_expr => |a| return astContainsBreakOrContinueExpr(a.target) or astContainsBreakOrContinueExpr(a.value),
        .compound_assign => |ca| return astContainsBreakOrContinueExpr(ca.target) or astContainsBreakOrContinueExpr(ca.value),
        .match => |m| {
            if (astContainsBreakOrContinueExpr(m.scrutinee)) return true;
            for (m.arms) |arm| {
                if (arm.guard) |g| if (astContainsBreakOrContinueExpr(g)) return true;
                if (astContainsBreakOrContinueExpr(arm.body)) return true;
            }
            return false;
        },
        .select => |s| {
            for (s.arms) |arm| switch (arm) {
                .receive => |r| {
                    if (astContainsBreakOrContinueExpr(r.channel_expr)) return true;
                    if (astContainsBreakOrContinueExpr(r.body)) return true;
                },
                .timeout => |t| {
                    if (astContainsBreakOrContinueExpr(t.duration)) return true;
                    if (astContainsBreakOrContinueExpr(t.body)) return true;
                },
            };
            return false;
        },
        .type_cast => |tc| return astContainsBreakOrContinueExpr(tc.expr),
        .atomic_expr => |ae| return astContainsBreakOrContinueExpr(ae.value),
        .lazy => |l| return astContainsBreakOrContinueExpr(l.expr),
        .spawn_expr => |se| return astContainsBreakOrContinueExpr(se.expr),
        .array_literal => |al| {
            for (al.elements) |e| {
                if (astContainsBreakOrContinueExpr(e)) return true;
            }
            return false;
        },
        .record_literal => |rl| {
            for (rl.fields) |f| {
                if (astContainsBreakOrContinueExpr(f.value)) return true;
            }
            return false;
        },
        .record_extend => |re| {
            if (astContainsBreakOrContinueExpr(re.base)) return true;
            for (re.updates) |f| {
                if (astContainsBreakOrContinueExpr(f.value)) return true;
            }
            return false;
        },
        .string_interpolation => |si| {
            for (si.parts) |p| switch (p) {
                .literal => {},
                .expression => |e| if (astContainsBreakOrContinueExpr(e)) return true,
            };
            return false;
        },
        .lambda => return false, // lambda 体不在当前循环上下文中
        .inline_trait_value => return false,
        else => return false,
    }
}

fn astContainsBreakOrContinueStmt(stmt: *const ast.Stmt) bool {
    switch (stmt.*) {
        .break_stmt, .continue_stmt => return true,
        .expression => |e| return astContainsBreakOrContinueExpr(e.expr),
        .val_decl => |vd| return astContainsBreakOrContinueExpr(vd.value),
        .var_decl => |vd| return astContainsBreakOrContinueExpr(vd.value),
        .assignment => |a| return astContainsBreakOrContinueExpr(a.target) or astContainsBreakOrContinueExpr(a.value),
        .field_assignment => |fa| return astContainsBreakOrContinueExpr(fa.object) or astContainsBreakOrContinueExpr(fa.value),
        .compound_assignment => |ca| return astContainsBreakOrContinueExpr(ca.target) or astContainsBreakOrContinueExpr(ca.value),
        .return_stmt => |rs| if (rs.value) |v| return astContainsBreakOrContinueExpr(v),
        .defer_stmt => |ds| return astContainsBreakOrContinueExpr(ds.expr),
        .throw_stmt => |ts| return astContainsBreakOrContinueExpr(ts.expr),
        .for_stmt => |fs| return astContainsBreakOrContinueExpr(fs.body) or astContainsBreakOrContinueExpr(fs.iterable),
        .while_stmt => |ws| return astContainsBreakOrContinueExpr(ws.body) or astContainsBreakOrContinueExpr(ws.condition),
        .loop_stmt => |ls| return astContainsBreakOrContinueExpr(ls.body),
    }
    return false;
}

// ════════════════════════════════════════════════════════════════
// 测试
// ════════════════════════════════════════════════════════════════

const testing = std.testing;

test "IRBuilder 编译简单算术: 1 + 2" {
    // 构造 AST: fun main() { return 1 + 2 }
    // 使用内联构造测试
    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();

    // 手动构造节点验证构建器逻辑
    const ch1 = try builder.allocChannel(.i64_chan);
    const ch2 = try builder.allocChannel(.i64_chan);
    const ch_out = try builder.allocChannel(.i64_chan);

    const meta1 = try builder.addScalarMeta(.{ .kind = .int, .int_kind = .i64, .const_val = .{ .int_val = 1 } });
    const meta2 = try builder.addScalarMeta(.{ .kind = .int, .int_kind = .i64, .const_val = .{ .int_val = 2 } });
    const meta_out = try builder.addScalarMeta(.{ .kind = .int, .int_kind = .i64 });

    try builder.emit(Node.makeSink(.const_i, ch1, meta1));
    try builder.emit(Node.makeSink(.const_i, ch2, meta2));
    try builder.emit(Node.makeBinary(.int_add, ch_out, meta_out, ch1, ch2));

    try testing.expectEqual(@as(usize, 3), builder.nodes.items.len);
    try testing.expectEqual(NodeOp.const_i, builder.nodes.items[0].op);
    try testing.expectEqual(NodeOp.int_add, builder.nodes.items[2].op);
}

test "intKindFromSuffix 后缀解析" {
    try testing.expectEqual(IntKind.i32, intKindFromSuffix("i32").?);
    try testing.expectEqual(IntKind.u64, intKindFromSuffix("u64").?);
    try testing.expect(intKindFromSuffix(null) == null);
    try testing.expect(intKindFromSuffix("xyz") == null);
}

test "binaryOpToNodeOp 类型分派" {
    try testing.expectEqual(NodeOp.int_add, try binaryOpToNodeOp(.add, .i64_chan));
    try testing.expectEqual(NodeOp.float_add, try binaryOpToNodeOp(.add, .f64_chan));
    try testing.expectEqual(NodeOp.int_and, try binaryOpToNodeOp(.bit_and, .i32_chan));
    try testing.expectEqual(NodeOp.cmp_lt, try binaryOpToNodeOp(.lt, .i64_chan));
    try testing.expectError(error.UnsupportedType, binaryOpToNodeOp(.bit_and, .f64_chan));
}

test "binaryResultType 结果类型推导" {
    try testing.expectEqual(ChanType.mask_chan, binaryResultType(.lt, .i64_chan));
    try testing.expectEqual(ChanType.bool_chan, binaryResultType(.and_op, .bool_chan));
    try testing.expectEqual(ChanType.i64_chan, binaryResultType(.add, .i64_chan));
}

// ════════════════════════════════════════════════════════════════
// 端到端测试：AST → IRBuilder.build() → GlueIR 验证
// ════════════════════════════════════════════════════════════════

/// 测试用 AST 构造器：在 arena 中分配 NodeSlot 包装的 AST 节点
const AstHelper = struct {
    arena: std.heap.ArenaAllocator,

    fn init(allocator: std.mem.Allocator) AstHelper {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    fn deinit(self: *AstHelper) void {
        self.arena.deinit();
    }

    fn alloc(self: *AstHelper) std.mem.Allocator {
        return self.arena.allocator();
    }

    const loc: ast.SourceLocation = .{ .line = 1, .column = 1 };

    fn expr(self: *AstHelper, e: ast.Expr) *ast.Expr {
        const slot = self.alloc().create(ast.NodeSlot(ast.Expr)) catch unreachable;
        slot.* = .{ .loc = loc, .node = e };
        return &slot.node;
    }

    fn stmt(self: *AstHelper, s: ast.Stmt) *ast.Stmt {
        const slot = self.alloc().create(ast.NodeSlot(ast.Stmt)) catch unreachable;
        slot.* = .{ .loc = loc, .node = s };
        return &slot.node;
    }

    fn typeNode(self: *AstHelper, t: ast.TypeNode) *ast.TypeNode {
        const slot = self.alloc().create(ast.NodeSlot(ast.TypeNode)) catch unreachable;
        slot.* = .{ .loc = loc, .node = t };
        return &slot.node;
    }

    // 快捷构造：整数字面量
    fn intLit(self: *AstHelper, raw: []const u8) *ast.Expr {
        return self.expr(.{ .int_literal = .{ .raw = raw, .suffix = null } });
    }

    fn intLitSuf(self: *AstHelper, raw: []const u8, suffix: []const u8) *ast.Expr {
        return self.expr(.{ .int_literal = .{ .raw = raw, .suffix = suffix } });
    }

    // 快捷构造：浮点字面量
    fn floatLit(self: *AstHelper, raw: []const u8) *ast.Expr {
        return self.expr(.{ .float_literal = .{ .raw = raw, .suffix = null } });
    }

    fn floatLitSuf(self: *AstHelper, raw: []const u8, suffix: []const u8) *ast.Expr {
        return self.expr(.{ .float_literal = .{ .raw = raw, .suffix = suffix } });
    }

    // 快捷构造：布尔字面量
    fn boolLit(self: *AstHelper, v: bool) *ast.Expr {
        return self.expr(.{ .bool_literal = .{ .value = v } });
    }

    // 快捷构造：标识符引用
    fn ident(self: *AstHelper, name: []const u8) *ast.Expr {
        return self.expr(.{ .identifier = .{ .name = name } });
    }

    // 快捷构造：二元运算
    fn binary(self: *AstHelper, op: ast.BinaryOp, left: *ast.Expr, right: *ast.Expr) *ast.Expr {
        return self.expr(.{ .binary = .{ .op = op, .left = left, .right = right } });
    }

    // 快捷构造：一元运算
    fn unary(self: *AstHelper, op: ast.UnaryOp, operand: *ast.Expr) *ast.Expr {
        return self.expr(.{ .unary = .{ .op = op, .operand = operand } });
    }

    // 快捷构造：if 表达式
    fn ifExpr(
        self: *AstHelper,
        cond: *ast.Expr,
        then_b: *ast.Expr,
        else_b: ?*ast.Expr,
    ) *ast.Expr {
        return self.expr(.{ .if_expr = .{
            .condition = cond,
            .then_branch = then_b,
            .else_branch = else_b,
        } });
    }

    // 快捷构造：函数调用
    fn call(self: *AstHelper, func_name: []const u8, args: []const *ast.Expr) *ast.Expr {
        const args_slice = self.alloc().dupe(*ast.Expr, args) catch unreachable;
        return self.expr(.{ .call = .{
            .callee = self.ident(func_name),
            .arguments = args_slice,
            .type_args = null,
        } });
    }

    // 快捷构造：method_call 表达式
    fn methodCall(self: *AstHelper, obj: *ast.Expr, method: []const u8, args: []const *ast.Expr) *ast.Expr {
        const args_slice = self.alloc().dupe(*ast.Expr, args) catch unreachable;
        return self.expr(.{ .method_call = .{
            .object = obj,
            .method = method,
            .arguments = args_slice,
            .type_args = null,
        } });
    }

    // 快捷构造：block 表达式
    fn block(self: *AstHelper, stmts: []const *ast.Stmt, trailing: ?*ast.Expr) *ast.Expr {
        const stmts_slice = self.alloc().alloc(*ast.Stmt, stmts.len) catch unreachable;
        for (stmts, 0..) |s, i| stmts_slice[i] = s;
        return self.expr(.{ .block = .{
            .statements = stmts_slice,
            .trailing_expr = trailing,
        } });
    }

    // 快捷构造：val 声明语句
    fn valDecl(self: *AstHelper, name: []const u8, value: *ast.Expr) *ast.Stmt {
        return self.stmt(.{ .val_decl = .{
            .name = name,
            .type_annotation = null,
            .value = value,
        } });
    }

    // 快捷构造：var 声明语句
    fn varDecl(self: *AstHelper, name: []const u8, value: *ast.Expr) *ast.Stmt {
        return self.stmt(.{ .var_decl = .{
            .name = name,
            .type_annotation = null,
            .value = value,
        } });
    }

    // 快捷构造：赋值语句
    fn assignment(self: *AstHelper, target_name: []const u8, value: *ast.Expr) *ast.Stmt {
        return self.stmt(.{ .assignment = .{
            .target = self.ident(target_name),
            .value = value,
        } });
    }

    // 快捷构造：return 语句
    fn returnStmt(self: *AstHelper, value: ?*ast.Expr) *ast.Stmt {
        return self.stmt(.{ .return_stmt = .{ .value = value } });
    }

    // 快捷构造：表达式语句
    fn exprStmt(self: *AstHelper, e: *ast.Expr) *ast.Stmt {
        return self.stmt(.{ .expression = .{ .expr = e } });
    }

    // 快捷构造：命名类型节点
    fn namedType(self: *AstHelper, name: []const u8) *ast.TypeNode {
        return self.typeNode(.{ .named = .{ .name = name } });
    }

    // 快捷构造：函数参数
    fn param(self: *AstHelper, name: []const u8, type_name: []const u8) ast.Param {
        return .{
            .location = loc,
            .name = name,
            .type_annotation = self.namedType(type_name),
            .is_var = false,
        };
    }

    // 快捷构造：函数声明
    fn funDecl(
        self: *AstHelper,
        name: []const u8,
        params: []const ast.Param,
        return_type: ?*ast.TypeNode,
        body: *ast.Expr,
        is_entry: bool,
    ) ast.Decl {
        const params_slice = self.alloc().alloc(ast.Param, params.len) catch unreachable;
        for (params, 0..) |p, i| params_slice[i] = p;
        return .{ .fun_decl = .{
            .location = loc,
            .visibility = .private,
            .name = name,
            .type_params = &.{},
            .params = params_slice,
            .return_type = return_type,
            .bounds = &.{},
            .body = body,
            .is_async = false,
            .is_entry = is_entry,
        } };
    }

    /// async 函数声明
    fn asyncFunDecl(
        self: *AstHelper,
        name: []const u8,
        params: []const ast.Param,
        return_type: ?*ast.TypeNode,
        body: *ast.Expr,
    ) ast.Decl {
        const params_slice = self.alloc().alloc(ast.Param, params.len) catch unreachable;
        for (params, 0..) |p, i| params_slice[i] = p;
        return .{ .fun_decl = .{
            .location = loc,
            .visibility = .private,
            .name = name,
            .type_params = &.{},
            .params = params_slice,
            .return_type = return_type,
            .bounds = &.{},
            .body = body,
            .is_async = true,
            .is_entry = false,
        } };
    }

    // 快捷构造：模块
    fn module(self: *AstHelper, name: []const u8, decls: []const ast.Decl) ast.Module {
        const decls_slice = self.alloc().dupe(ast.Decl, decls) catch unreachable;
        return .{ .name = name, .source_path = null, .declarations = decls_slice };
    }
};

// ── 端到端测试用例 ──

test "e2e: 简单算术 fun main() -> i64 { 1 + 2 }" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun main() -> i64 { 1 + 2 }
    const body = ah.block(&.{}, ah.binary(.add, ah.intLit("1"), ah.intLit("2")));
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 验证：1 个函数、4 个节点（const_i, const_i, int_add, halt_return）
    try testing.expectEqual(@as(usize, 1), ir.functions.len);
    try testing.expectEqual(@as(usize, 4), ir.nodes.len);

    // 节点序列验证
    try testing.expectEqual(NodeOp.const_i, ir.nodes[0].op);
    try testing.expectEqual(NodeOp.const_i, ir.nodes[1].op);
    try testing.expectEqual(NodeOp.int_add, ir.nodes[2].op);
    try testing.expectEqual(NodeOp.halt_return, ir.nodes[3].op);

    // int_add 的输入应连接到两个 const_i 的输出
    try testing.expectEqual(ir.nodes[0].output, ir.nodes[2].inputs[0]);
    try testing.expectEqual(ir.nodes[1].output, ir.nodes[2].inputs[1]);

    // 常量值验证
    try testing.expectEqual(@as(i128, 1), ir.scalar_metas[1].const_val.?.int_val);
    try testing.expectEqual(@as(i128, 2), ir.scalar_metas[2].const_val.?.int_val);

    // 入口函数
    try testing.expectEqual(@as(u16, 0), ir.entry_index);
    try testing.expect(ir.functions[0].is_entry);
    try testing.expectEqualStrings("main", ir.functions[0].name);
}

test "e2e: 变量绑定与使用 fun main() -> i64 { val x = 10; x }" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun main() -> i64 { val x = 10; x }
    const stmts = [_]*ast.Stmt{
        ah.valDecl("x", ah.intLit("10")),
    };
    const body = ah.block(&stmts, ah.ident("x"));
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 节点序列：const_i(10), halt_return
    try testing.expectEqual(@as(usize, 2), ir.nodes.len);
    try testing.expectEqual(NodeOp.const_i, ir.nodes[0].op);
    try testing.expectEqual(NodeOp.halt_return, ir.nodes[1].op);

    // halt_return 的输入应指向 const_i 的输出（变量 x 绑定到 const_i 通道）
    try testing.expectEqual(ir.nodes[0].output, ir.nodes[1].inputs[0]);

    // 常量值
    try testing.expectEqual(@as(i128, 10), ir.scalar_metas[1].const_val.?.int_val);
}

test "e2e: if 表达式 fun main() -> i64 { if true { 1 } else { 2 } }" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun main() -> i64 { if true { 1 } else { 2 } }
    const body = ah.block(&.{}, ah.ifExpr(
        ah.boolLit(true),
        ah.intLit("1"),
        ah.intLit("2"),
    ));
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 节点序列：const_bool, cast, const_i(2)[else], const_i(1)[then], route_dispatch, halt_return
    try testing.expectEqual(@as(usize, 6), ir.nodes.len);
    try testing.expectEqual(NodeOp.const_bool, ir.nodes[0].op);
    try testing.expectEqual(NodeOp.cast, ir.nodes[1].op);
    try testing.expectEqual(NodeOp.const_i, ir.nodes[2].op); // else 分支
    try testing.expectEqual(NodeOp.const_i, ir.nodes[3].op); // then 分支
    try testing.expectEqual(NodeOp.route_dispatch, ir.nodes[4].op);
    try testing.expectEqual(NodeOp.halt_return, ir.nodes[5].op);

    // route_dispatch 输入：[winner_chan]
    try testing.expectEqual(ir.nodes[1].output, ir.nodes[4].inputs[0]); // winner
}

test "e2e: 函数定义与调用 add(1, 2)" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST:
    //   fun add(a: i64, b: i64) -> i64 { a + b }
    //   fun main() -> i64 { add(1, 2) }
    const add_body = ah.block(&.{}, ah.binary(.add, ah.ident("a"), ah.ident("b")));
    const add_params = [_]ast.Param{
        ah.param("a", "i64"),
        ah.param("b", "i64"),
    };
    const add_decl = ah.funDecl("add", &add_params, ah.namedType("i64"), add_body, false);

    const main_args = [_]*ast.Expr{ ah.intLit("1"), ah.intLit("2") };
    const main_body = ah.block(&.{}, ah.call("add", &main_args));
    const main_decl = ah.funDecl("main", &.{}, ah.namedType("i64"), main_body, true);

    const decls = [_]ast.Decl{ add_decl, main_decl };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 2 个函数
    try testing.expectEqual(@as(usize, 2), ir.functions.len);
    try testing.expectEqualStrings("add", ir.functions[0].name);
    try testing.expectEqualStrings("main", ir.functions[1].name);
    try testing.expect(ir.functions[1].is_entry);

    // add 函数节点：const_i(1)? 不——参数是 identifier
    // add 节点序列：int_add(a, b), halt_return
    const add_fn_nodes = ir.funcNodes(0);
    try testing.expectEqual(@as(usize, 2), add_fn_nodes.len);
    try testing.expectEqual(NodeOp.int_add, add_fn_nodes[0].op);
    try testing.expectEqual(NodeOp.halt_return, add_fn_nodes[1].op);

    // main 函数节点：const_i(1), const_i(2), call, halt_return
    const main_fn_nodes = ir.funcNodes(1);
    try testing.expectEqual(@as(usize, 4), main_fn_nodes.len);
    try testing.expectEqual(NodeOp.const_i, main_fn_nodes[0].op);
    try testing.expectEqual(NodeOp.const_i, main_fn_nodes[1].op);
    try testing.expectEqual(NodeOp.call, main_fn_nodes[2].op);
    try testing.expectEqual(NodeOp.halt_return, main_fn_nodes[3].op);

    // call 节点输入连接
    try testing.expectEqual(@as(u8, 2), main_fn_nodes[2].input_count);
    try testing.expectEqual(main_fn_nodes[0].output, main_fn_nodes[2].inputs[0]); // arg 1
    try testing.expectEqual(main_fn_nodes[1].output, main_fn_nodes[2].inputs[1]); // arg 2

    // call 元数据
    try testing.expectEqual(@as(u16, 0), ir.call_metas[0].func_index);
    try testing.expectEqual(@as(u8, 2), ir.call_metas[0].arg_count);
}

test "e2e: var 声明与赋值 fun main() -> i64 { var x = 1; x = 2; x }" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun main() -> i64 { var x = 1; x = 2; x }
    const stmts = [_]*ast.Stmt{
        ah.varDecl("x", ah.intLit("1")),
        ah.assignment("x", ah.intLit("2")),
    };
    const body = ah.block(&stmts, ah.ident("x"));
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 节点序列：const_i(1), load(x_cell), const_i(2), store(x_cell), halt_return
    try testing.expectEqual(@as(usize, 5), ir.nodes.len);
    try testing.expectEqual(NodeOp.const_i, ir.nodes[0].op);
    try testing.expectEqual(NodeOp.load, ir.nodes[1].op);
    try testing.expectEqual(NodeOp.const_i, ir.nodes[2].op);
    try testing.expectEqual(NodeOp.store, ir.nodes[3].op);
    try testing.expectEqual(NodeOp.halt_return, ir.nodes[4].op);

    // load 和 store 应指向同一个 cell 通道
    try testing.expectEqual(ir.nodes[1].output, ir.nodes[3].output);

    // var 声明的通道应标记为 cell
    const cell_chan = ir.nodes[1].output;
    try testing.expect(ir.channels.get(cell_chan).is_cell);
}

test "e2e: 类型推导（后缀 + 浮点）" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun main() -> f32 { 1.5f32 + 2.5f32 }
    const body = ah.block(&.{}, ah.binary(
        .add,
        ah.floatLitSuf("1.5", "f32"),
        ah.floatLitSuf("2.5", "f32"),
    ));
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("f32"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 节点序列：const_f, const_f, float_add, halt_return
    try testing.expectEqual(@as(usize, 4), ir.nodes.len);
    try testing.expectEqual(NodeOp.const_f, ir.nodes[0].op);
    try testing.expectEqual(NodeOp.const_f, ir.nodes[1].op);
    try testing.expectEqual(NodeOp.float_add, ir.nodes[2].op);
    try testing.expectEqual(NodeOp.halt_return, ir.nodes[3].op);

    // 通道类型应为 f32
    try testing.expectEqual(ChanType.f32_chan, ir.channels.get(ir.nodes[0].output).chan_type);
    try testing.expectEqual(ChanType.f32_chan, ir.channels.get(ir.nodes[2].output).chan_type);

    // 元数据中 float_kind 应为 f32
    try testing.expectEqual(FloatKind.f32, ir.scalar_metas[1].float_kind);
    try testing.expectEqual(FloatKind.f32, ir.scalar_metas[2].float_kind);
    try testing.expectEqual(FloatKind.f32, ir.scalar_metas[3].float_kind);
}

test "e2e: 比较运算与 bool 逻辑" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun main() -> bool { 1 < 2 }
    const body = ah.block(&.{}, ah.binary(.lt, ah.intLit("1"), ah.intLit("2")));
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("bool"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 节点序列：const_i, const_i, cmp_lt, halt_return
    try testing.expectEqual(@as(usize, 4), ir.nodes.len);
    try testing.expectEqual(NodeOp.cmp_lt, ir.nodes[2].op);

    // 比较结果类型应为 mask
    try testing.expectEqual(ChanType.mask_chan, ir.channels.get(ir.nodes[2].output).chan_type);
}

test "e2e: 一元运算 fun main() -> i64 { -5 }" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun main() -> i64 { -5 }
    const body = ah.block(&.{}, ah.unary(.neg, ah.intLit("5")));
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 节点序列：const_i(5), int_neg, halt_return
    try testing.expectEqual(@as(usize, 3), ir.nodes.len);
    try testing.expectEqual(NodeOp.const_i, ir.nodes[0].op);
    try testing.expectEqual(NodeOp.int_neg, ir.nodes[1].op);
    try testing.expectEqual(NodeOp.halt_return, ir.nodes[2].op);

    // neg 的输入应连接到 const_i 的输出
    try testing.expectEqual(ir.nodes[0].output, ir.nodes[1].inputs[0]);
}

test "e2e: IR printer 输出验证" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun main() -> i64 { 1 + 2 }
    const body = ah.block(&.{}, ah.binary(.add, ah.intLit("1"), ah.intLit("2")));
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 打印 IR
    const output = try @import("printer.zig").irToString(testing.allocator, &ir);
    defer testing.allocator.free(output);

    // 验证输出包含关键内容
    try testing.expect(std.mem.indexOf(u8, output, "Glue IR") != null);
    try testing.expect(std.mem.indexOf(u8, output, "const_i") != null);
    try testing.expect(std.mem.indexOf(u8, output, "int_add") != null);
    try testing.expect(std.mem.indexOf(u8, output, "halt_return") != null);
    try testing.expect(std.mem.indexOf(u8, output, "main") != null);
    try testing.expect(std.mem.indexOf(u8, output, "[entry]") != null);
}

// ════════════════════════════════════════════════════════════════
// Phase 2 端到端测试：向量 op
// ════════════════════════════════════════════════════════════════

test "e2e: for 循环 range 向量化 fun main() { for i in 0..10 { i } }" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: for i in 0..10 { i }
    const for_stmt = ah.stmt(.{ .for_stmt = .{
        .name = "i",
        .iterable = ah.binary(.range, ah.intLit("0"), ah.intLit("10")),
        .body = ah.ident("i"),
    } });
    const body = ah.block(&.{for_stmt}, null);
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 节点序列：const_i(0), const_i(10), vec_source, vec_map, vec_sink, halt_return
    try testing.expectEqual(@as(usize, 6), ir.nodes.len);
    try testing.expectEqual(NodeOp.const_i, ir.nodes[0].op);
    try testing.expectEqual(NodeOp.const_i, ir.nodes[1].op);
    try testing.expectEqual(NodeOp.vec_source, ir.nodes[2].op);
    try testing.expectEqual(NodeOp.vec_map, ir.nodes[3].op);
    try testing.expectEqual(NodeOp.vec_sink, ir.nodes[4].op);

    // vec_source 的输入是 start 和 end 通道
    try testing.expectEqual(@as(u8, 2), ir.nodes[2].input_count);
    try testing.expectEqual(ir.nodes[0].output, ir.nodes[2].inputs[0]); // start
    try testing.expectEqual(ir.nodes[1].output, ir.nodes[2].inputs[1]); // end

    // vec_map 的输入是 vec_source 的输出
    try testing.expectEqual(ir.nodes[2].output, ir.nodes[3].inputs[0]);

    // vec_sink 的输入是 vec_map 的输出
    try testing.expectEqual(ir.nodes[3].output, ir.nodes[4].inputs[0]);

    // 向量元数据验证（vec_source + vec_map + vec_sink = 3 个）
    try testing.expectEqual(@as(usize, 3), ir.vector_metas.len);

    // vmeta[0]: vec_source (range_source)
    try testing.expectEqual(VecOp.range_source, ir.vector_metas[0].vec_op);
    try testing.expectEqual(@as(?u32, 10), ir.vector_metas[0].length); // 编译期推导长度
    try testing.expectEqual(ChanType.i64_chan, ir.vector_metas[0].elem_type);

    // vmeta[2]: vec_sink (sink_last)
    try testing.expectEqual(VecOp.sink_last, ir.vector_metas[2].vec_op);
}

test "e2e: for 循环 inclusive range 向量化" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: for i in 0..=5 { i }
    const for_stmt = ah.stmt(.{ .for_stmt = .{
        .name = "i",
        .iterable = ah.binary(.range_inclusive, ah.intLit("0"), ah.intLit("5")),
        .body = ah.ident("i"),
    } });
    const body = ah.block(&.{for_stmt}, null);
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // range_inclusive 长度 = 5 - 0 + 1 = 6
    try testing.expectEqual(@as(?u32, 6), ir.vector_metas[0].length);
}

test "e2e: for 循环带循环体运算" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: for i in 0..100 { i * 2 }
    const for_stmt = ah.stmt(.{ .for_stmt = .{
        .name = "i",
        .iterable = ah.binary(.range, ah.intLit("0"), ah.intLit("100")),
        .body = ah.binary(.mul, ah.ident("i"), ah.intLit("2")),
    } });
    const body = ah.block(&.{for_stmt}, null);
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 节点序列：const_i(0), const_i(100), vec_source, const_i(2), int_mul, vec_map, vec_sink, halt_return
    // 循环体子图：const_i(2), int_mul — body_start/body_len 引用这段
    try testing.expectEqual(@as(usize, 8), ir.nodes.len);
    try testing.expectEqual(NodeOp.vec_source, ir.nodes[2].op);
    try testing.expectEqual(NodeOp.int_mul, ir.nodes[4].op);
    try testing.expectEqual(NodeOp.vec_map, ir.nodes[5].op);

    // vec_map 的 meta 应记录循环体子图范围（vmeta[1] 是 vec_map）
    const map_meta = ir.vector_metas[1];
    try testing.expect(map_meta.body_len > 0); // 循环体非空
    try testing.expectEqual(@as(?u32, 100), ir.vector_metas[0].length);
}

test "e2e: while 循环向量化" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: while true { 1 }
    const while_stmt = ah.stmt(.{ .while_stmt = .{
        .condition = ah.boolLit(true),
        .body = ah.intLit("1"),
    } });
    const body = ah.block(&.{while_stmt}, null);
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // while 编译为 vec_take_while + vec_sink
    const has_take_while = blk: {
        for (ir.nodes) |n| if (n.op == .vec_take_while) break :blk true;
        break :blk false;
    };
    try testing.expect(has_take_while);

    // 验证 vec_take_while 之后有 vec_sink
    const has_sink = blk: {
        for (ir.nodes) |n| if (n.op == .vec_sink) break :blk true;
        break :blk false;
    };
    try testing.expect(has_sink);
}

test "e2e: vec_fold 归约编译" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // 直接测试 compileFold 方法
    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();

    // 手动构造场景：src_vec_chan 和 init_chan
    const src_vec = try builder.allocChannel(.i64_chan);
    const init_chan = try builder.allocChannel(.i64_chan);

    const fold_out = try builder.compileFold(.int_add, init_chan, src_vec);

    // 验证最后一个节点是 vec_fold
    const last_node = builder.nodes.items[builder.nodes.items.len - 1];
    try testing.expectEqual(NodeOp.vec_fold, last_node.op);
    try testing.expectEqual(@as(u8, 2), last_node.input_count);
    try testing.expectEqual(src_vec, last_node.inputs[0]);
    try testing.expectEqual(init_chan, last_node.inputs[1]);
    try testing.expectEqual(fold_out, last_node.output);

    // 验证向量元数据
    const fold_meta = builder.vector_metas.items[0];
    try testing.expectEqual(NodeOp.int_add, fold_meta.inner_op);
    try testing.expectEqual(ChanType.i64_chan, fold_meta.elem_type);
}

test "e2e: vec_scan 前缀计算编译" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();

    const src_vec = try builder.allocChannel(.i64_chan);
    const init_chan = try builder.allocChannel(.i64_chan);

    const scan_out = try builder.compileScan(.int_add, init_chan, src_vec);

    // 验证最后一个节点是 vec_scan
    const last_node = builder.nodes.items[builder.nodes.items.len - 1];
    try testing.expectEqual(NodeOp.vec_scan, last_node.op);
    try testing.expectEqual(@as(u8, 2), last_node.input_count);
    try testing.expectEqual(src_vec, last_node.inputs[0]);
    try testing.expectEqual(init_chan, last_node.inputs[1]);
    try testing.expectEqual(scan_out, last_node.output);

    // 验证向量元数据
    const scan_meta = builder.vector_metas.items[0];
    try testing.expectEqual(NodeOp.int_add, scan_meta.inner_op);
}

test "e2e: for 循环 dispatch 降频验证" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: for i in 0..1000 { i * 2 + 1 }
    // 传统执行：1000 次 dispatch（mul + add + const）
    // 向量化：3 次 dispatch（vec_source + vec_map + vec_sink）
    const for_stmt = ah.stmt(.{ .for_stmt = .{
        .name = "i",
        .iterable = ah.binary(.range, ah.intLit("0"), ah.intLit("1000")),
        .body = ah.binary(.add, ah.binary(.mul, ah.ident("i"), ah.intLit("2")), ah.intLit("1")),
    } });
    const body = ah.block(&.{for_stmt}, null);
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 统计向量 op 数量
    var vec_op_count: usize = 0;
    for (ir.nodes) |n| {
        if (n.op.isVector()) vec_op_count += 1;
    }

    // 向量 op 只有 3 个：vec_source + vec_map + vec_sink
    // 循环体子图（const_i, const_i, int_mul, int_add）是内联的，不算独立 dispatch
    try testing.expectEqual(@as(usize, 3), vec_op_count);

    // 编译期已知长度 1000
    try testing.expectEqual(@as(?u32, 1000), ir.vector_metas[0].length);
}

test "e2e: 向量 meta printer 输出" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: for i in 0..10 { i }
    const for_stmt = ah.stmt(.{ .for_stmt = .{
        .name = "i",
        .iterable = ah.binary(.range, ah.intLit("0"), ah.intLit("10")),
        .body = ah.ident("i"),
    } });
    const body = ah.block(&.{for_stmt}, null);
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    const output = try @import("printer.zig").irToString(testing.allocator, &ir);
    defer testing.allocator.free(output);

    // 验证向量元数据打印输出
    try testing.expect(std.mem.indexOf(u8, output, "向量元数据") != null);
    try testing.expect(std.mem.indexOf(u8, output, "range_source") != null);
    try testing.expect(std.mem.indexOf(u8, output, "sink_last") != null);
    try testing.expect(std.mem.indexOf(u8, output, "length=10") != null);
    try testing.expect(std.mem.indexOf(u8, output, "vec_source") != null);
    try testing.expect(std.mem.indexOf(u8, output, "vec_map") != null);
    try testing.expect(std.mem.indexOf(u8, output, "vec_sink") != null);
}

// ════════════════════════════════════════════════════════════════
// Phase 3 端到端测试：门控/路由/竞争/清理
// ════════════════════════════════════════════════════════════════

test "e2e: ? 传播表达式编译为 gate 节点链" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun f() -> i64 { 0 } fun main() -> i64 { f()? }
    const f_body = ah.block(&.{}, ah.intLit("0"));
    const f_decl = ah.funDecl("f", &.{}, ah.namedType("i64"), f_body, false);
    const body = ah.block(&.{}, ah.expr(.{ .propagate = .{
        .expr = ah.call("f", &.{}),
    } }));
    const decls = [_]ast.Decl{
        f_decl,
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 节点序列：call(f), gate_check, gate_get_ok, const_unit, halt_return
    try testing.expect(ir.nodes.len >= 3);

    // 查找 gate_check 和 gate_get_ok 节点
    var has_gate_check = false;
    var has_gate_get_ok = false;
    for (ir.nodes) |n| {
        if (n.op == .gate_check) has_gate_check = true;
        if (n.op == .gate_get_ok) has_gate_get_ok = true;
    }
    try testing.expect(has_gate_check);
    try testing.expect(has_gate_get_ok);

    // 验证门控元数据
    try testing.expect(ir.gate_metas.len >= 2);
    try testing.expectEqual(GateKind.check, ir.gate_metas[0].gate_kind);
    try testing.expectEqual(GateKind.get_ok, ir.gate_metas[1].gate_kind);
}

test "e2e: defer 语句编译为 cleanup_register" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun cleanup() -> i64 { 0 } fun main() -> i64 { defer cleanup(); return 42 }
    const cleanup_body = ah.block(&.{}, ah.intLit("0"));
    const cleanup_decl = ah.funDecl("cleanup", &.{}, ah.namedType("i64"), cleanup_body, false);
    const defer_stmt = ah.stmt(.{ .defer_stmt = .{
        .expr = ah.call("cleanup", &.{}),
    } });
    const return_stmt = ah.returnStmt(ah.intLit("42"));
    const body = ah.block(&.{ defer_stmt, return_stmt }, null);
    const decls = [_]ast.Decl{
        cleanup_decl,
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 查找 cleanup_register 节点
    var has_cleanup = false;
    for (ir.nodes) |n| {
        if (n.op == .cleanup_register) has_cleanup = true;
    }
    try testing.expect(has_cleanup);

    // 验证清理元数据
    try testing.expect(ir.cleanup_metas.len >= 1);
    const cm = ir.cleanup_metas[0];
    try testing.expectEqual(HaltKind.any_halt, cm.trigger);
    try testing.expect(cm.body_len > 0); // defer 体非空
    try testing.expectEqual(@as(u32, 0), cm.order); // 第一个 defer
}

test "e2e: 多个 defer LIFO 顺序" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun a() -> i64 { 0 } fun b() -> i64 { 0 } fun main() -> i64 { defer a(); defer b(); return 0 }
    const a_decl = ah.funDecl("a", &.{}, ah.namedType("i64"), ah.block(&.{}, ah.intLit("0")), false);
    const b_decl = ah.funDecl("b", &.{}, ah.namedType("i64"), ah.block(&.{}, ah.intLit("0")), false);
    const defer_a = ah.stmt(.{ .defer_stmt = .{
        .expr = ah.call("a", &.{}),
    } });
    const defer_b = ah.stmt(.{ .defer_stmt = .{
        .expr = ah.call("b", &.{}),
    } });
    const return_stmt = ah.returnStmt(ah.intLit("0"));
    const body = ah.block(&.{ defer_a, defer_b, return_stmt }, null);
    const decls = [_]ast.Decl{
        a_decl,
        b_decl,
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 两个 cleanup_register 节点
    var cleanup_count: usize = 0;
    for (ir.nodes) |n| {
        if (n.op == .cleanup_register) cleanup_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), cleanup_count);

    // 验证 LIFO 顺序：order 递增
    try testing.expectEqual(@as(u32, 0), ir.cleanup_metas[0].order);
    try testing.expectEqual(@as(u32, 1), ir.cleanup_metas[1].order);
}

test "e2e: throw 语句编译为 halt_throw" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun main() -> i64 { throw 42 }
    // 简化：throw 一个整数字面量
    const throw_stmt = ah.stmt(.{ .throw_stmt = .{
        .expr = ah.intLit("42"),
    } });
    const body = ah.block(&.{throw_stmt}, null);
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 查找 halt_throw 节点
    var has_throw = false;
    for (ir.nodes) |n| {
        if (n.op == .halt_throw) has_throw = true;
    }
    try testing.expect(has_throw);

    // 验证门控元数据（make_err）
    try testing.expect(ir.gate_metas.len >= 1);
    var has_make_err = false;
    for (ir.gate_metas) |gm| {
        if (gm.gate_kind == .make_err) has_make_err = true;
    }
    try testing.expect(has_make_err);
}

test "e2e: select 多路复用编译为竞争图" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: select { ch1.recv() => v => 0; ch2.recv() => v => 1 }
    // 简化：使用整数通道，body 返回整数
    const arm1 = ast.SelectArm{ .receive = .{
        .location = AstHelper.loc,
        .channel_expr = ah.intLit("1"), // 简化：用整数代替通道
        .binding = "v",
        .body = ah.intLit("0"),
    } };
    const arm2 = ast.SelectArm{ .receive = .{
        .location = AstHelper.loc,
        .channel_expr = ah.intLit("2"),
        .binding = "v",
        .body = ah.intLit("1"),
    } };

    const arms = ah.alloc().alloc(ast.SelectArm, 2) catch unreachable;
    arms[0] = arm1;
    arms[1] = arm2;

    const body = ah.block(&.{}, ah.expr(.{ .select = .{ .arms = arms } }));
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 查找竞争节点
    var race_source_count: usize = 0;
    var has_race_select = false;
    var has_route_dispatch = false;
    for (ir.nodes) |n| {
        if (n.op == .race_source) race_source_count += 1;
        if (n.op == .race_select) has_race_select = true;
        if (n.op == .route_dispatch) has_route_dispatch = true;
    }

    // 2 个 race_source（每个分支一个）
    try testing.expectEqual(@as(usize, 2), race_source_count);
    try testing.expect(has_race_select);
    try testing.expect(has_route_dispatch);

    // 验证竞争元数据
    try testing.expect(ir.race_metas.len >= 3); // 2 个 race_source + 1 个 race_select

    // 验证路由元数据
    try testing.expect(ir.route_metas.len >= 1);
    try testing.expectEqual(@as(u8, 2), ir.route_metas[0].target_count);
}

test "e2e: Phase 3 元数据 printer 输出" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun cleanup() -> i64 { 0 } fun main() -> i64 { defer cleanup(); return 42 }
    const cleanup_decl = ah.funDecl("cleanup", &.{}, ah.namedType("i64"), ah.block(&.{}, ah.intLit("0")), false);
    const defer_stmt = ah.stmt(.{ .defer_stmt = .{
        .expr = ah.call("cleanup", &.{}),
    } });
    const return_stmt = ah.returnStmt(ah.intLit("42"));
    const body = ah.block(&.{ defer_stmt, return_stmt }, null);
    const decls = [_]ast.Decl{
        cleanup_decl,
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    const output = try @import("printer.zig").irToString(testing.allocator, &ir);
    defer testing.allocator.free(output);

    // 验证 Phase 3 元数据打印
    try testing.expect(std.mem.indexOf(u8, output, "清理元数据") != null);
    try testing.expect(std.mem.indexOf(u8, output, "cleanup_register") != null);
    try testing.expect(std.mem.indexOf(u8, output, "any_halt") != null);
}

// ── Phase 5 星轨扩展端到端测试 ──

test "e2e: async 函数调用编译为 orbit_async_create" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: async fun compute() -> i64 { 42 } fun main() -> i64 { compute().await() }
    const compute_decl = ah.asyncFunDecl("compute", &.{}, ah.namedType("i64"), ah.block(&.{}, ah.intLit("42")));
    const body = ah.block(&.{}, ah.methodCall(ah.call("compute", &.{}), "await", &.{}));
    const decls = [_]ast.Decl{
        compute_decl,
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 验证：compute 函数标记为 async
    try testing.expect(ir.functions[0].is_async);
    try testing.expect(!ir.functions[1].is_async);

    // 验证：main 函数中应发射 orbit_async_create + orbit_async_join
    // 节点序列：orbit_async_create, orbit_async_join, halt_return
    const main_nodes = ir.funcNodes(1);
    try testing.expectEqual(@as(usize, 3), main_nodes.len);
    try testing.expectEqual(NodeOp.orbit_async_create, main_nodes[0].op);
    try testing.expectEqual(NodeOp.orbit_async_join, main_nodes[1].op);
    try testing.expectEqual(NodeOp.halt_return, main_nodes[2].op);

    // 验证：orbit_async_create 的输出是 ref_chan（handle）
    try testing.expectEqual(ChanType.ref_chan, ir.channels.get(main_nodes[0].output).chan_type);

    // 验证：orbit_metas 表有 1 条记录
    try testing.expectEqual(@as(usize, 1), ir.orbit_metas.len);
    try testing.expectEqual(@as(u16, 0), ir.orbit_metas[0].func_index);
    try testing.expectEqual(@as(u8, 0), ir.orbit_metas[0].arg_count);
    try testing.expectEqual(ChanType.i64_chan, ir.orbit_metas[0].result_type);
}

test "e2e: orbit_async_join 等待异步结果" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: async fun compute() -> i64 { 42 } fun main() -> i64 { compute().await() }
    const compute_decl = ah.asyncFunDecl("compute", &.{}, ah.namedType("i64"), ah.block(&.{}, ah.intLit("42")));
    const body = ah.block(&.{}, ah.methodCall(ah.call("compute", &.{}), "await", &.{}));
    const decls = [_]ast.Decl{
        compute_decl,
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 验证：orbit_async_create 的 meta_index 指向 orbit_metas[0]
    const create_node = ir.funcNodes(1)[0];
    try testing.expectEqual(NodeOp.orbit_async_create, create_node.op);
    try testing.expectEqual(@as(u16, 1), create_node.meta_index);

    // 验证：orbit_metas 记录了结果类型，join 时用此类型分配结果通道
    try testing.expectEqual(ChanType.i64_chan, ir.orbit_metas[0].result_type);
}

test "e2e: async 函数带参数" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: async fun add(x: i64, y: i64) -> i64 { x + y } fun main() -> i64 { add(1, 2).await() }
    const x_param = ah.param("x", "i64");
    const y_param = ah.param("y", "i64");
    const add_decl = ah.asyncFunDecl("add", &.{ x_param, y_param }, ah.namedType("i64"),
        ah.block(&.{}, ah.binary(.add, ah.ident("x"), ah.ident("y"))));
    const body = ah.block(&.{}, ah.methodCall(ah.call("add", &.{ ah.intLit("1"), ah.intLit("2") }), "await", &.{}));
    const decls = [_]ast.Decl{
        add_decl,
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 验证：orbit_async_create 有 2 个输入（参数通道）
    // 节点序列：const_i(1), const_i(2), orbit_async_create, orbit_async_join, halt_return
    const main_nodes = ir.funcNodes(1);
    try testing.expectEqual(@as(usize, 5), main_nodes.len);
    try testing.expectEqual(NodeOp.const_i, main_nodes[0].op);
    try testing.expectEqual(NodeOp.const_i, main_nodes[1].op);
    try testing.expectEqual(NodeOp.orbit_async_create, main_nodes[2].op);
    try testing.expectEqual(@as(u8, 2), main_nodes[2].input_count);
    try testing.expectEqual(NodeOp.orbit_async_join, main_nodes[3].op);

    // 验证：orbit_metas 记录了正确的函数索引和参数数量
    try testing.expectEqual(@as(u16, 0), ir.orbit_metas[0].func_index);
    try testing.expectEqual(@as(u8, 2), ir.orbit_metas[0].arg_count);
}

test "e2e: orbit_chan_send/recv 通道通信" {
    // 直接用 builder 发射 orbit 通信节点（不经过 AST build）
    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();

    // 手动发射 orbit_chan_send 和 orbit_chan_recv
    const handle_chan: u16 = 0;
    const val_chan: u16 = 1;
    _ = try builder.emitOrbitSend(handle_chan, val_chan);
    _ = try builder.emitOrbitRecv(handle_chan, .i64_chan);
    _ = try builder.emitOrbitTryRecv(handle_chan, .i64_chan);

    // 验证节点已追加到 builder.nodes
    try testing.expectEqual(@as(usize, 3), builder.nodes.items.len);
    try testing.expectEqual(NodeOp.orbit_chan_send, builder.nodes.items[0].op);
    try testing.expectEqual(NodeOp.orbit_chan_recv, builder.nodes.items[1].op);
    try testing.expectEqual(NodeOp.orbit_chan_try_recv, builder.nodes.items[2].op);

    // 验证 send 节点是二元（handle + value）
    try testing.expectEqual(@as(u8, 2), builder.nodes.items[0].input_count);
    // 验证 recv 节点是一元（handle）
    try testing.expectEqual(@as(u8, 1), builder.nodes.items[1].input_count);
}

test "e2e: 星轨元数据 printer 输出" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: async fun compute() -> i64 { 42 } fun main() -> i64 { compute() }
    const compute_decl = ah.asyncFunDecl("compute", &.{}, ah.namedType("i64"), ah.block(&.{}, ah.intLit("42")));
    const body = ah.block(&.{}, ah.call("compute", &.{}));
    const decls = [_]ast.Decl{
        compute_decl,
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    const output = try @import("printer.zig").irToString(testing.allocator, &ir);
    defer testing.allocator.free(output);

    // 验证星轨元数据打印
    try testing.expect(std.mem.indexOf(u8, output, "星轨元数据") != null);
    try testing.expect(std.mem.indexOf(u8, output, "orbit_async_create") != null);
    try testing.expect(std.mem.indexOf(u8, output, "func=0") != null);
}

test "e2e: 优化器不消除 orbit 副作用节点" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: async fun compute() -> i64 { 42 } fun main() -> i64 { compute().await() }
    const compute_decl = ah.asyncFunDecl("compute", &.{}, ah.namedType("i64"), ah.block(&.{}, ah.intLit("42")));
    const body = ah.block(&.{}, ah.methodCall(ah.call("compute", &.{}), "await", &.{}));
    const decls = [_]ast.Decl{
        compute_decl,
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    _ = @import("optimizer.zig").optimize(&ir);

    // orbit_async_create 有副作用，不应被 deadNodeElim 消除
    const main_nodes = ir.funcNodes(1);
    try testing.expectEqual(NodeOp.orbit_async_create, main_nodes[0].op);
}
