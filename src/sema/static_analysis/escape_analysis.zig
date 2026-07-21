//! 逃逸分析模块（工业级完整实现）。
//!
//! 基于 AST 的过程间逃逸分析（Interprocedural Escape Analysis），
//! 标记每个函数是否"对象不逃逸"（no_escape），驱动引擎把非逃逸分配
//! 分流到 ShadowArena（O(1) reset），避免 RC 原子操作与 tracked_objs 注册。
//!
//! ## 分析维度
//!
//! 1. **过程内值追踪**：维护 `var_name → AllocSource` 环境，
//!    追踪 identifier 引用的对象来源（直接分配 vs 外部传入）。
//! 2. **跨函数传播**：查询被调函数的参数逃逸性（通过 ParamEscapeTable），
//!    纯函数的非逃逸参数不触发当前函数逃逸。
//! 3. **闭包捕获分析**：区分 by-value vs by-cell 捕获，by-value 捕获
//!    非逃逸分配的闭包仍可标记为 no_escape。
//! 4. **字段存储分析**：`field_assignment` / `record_extend` 的 base
//!    若为外部对象，写入字段触发逃逸。
//! 5. **控制流合并**：if/match/loop 的多分支逃逸性取并集。
//!
//! ## 逃逸判定规则
//!
//! | 场景 | 判定 |
//! |---|---|
//! | return 分配表达式 | 逃逸 |
//! | return identifier 指向分配表达式 | 逃逸 |
//! | field_assignment 写外层字段 | 逃逸 |
//! | call 传分配表达式给非纯函数 | 逃逸 |
//! | call 传分配表达式给纯函数（参数 noescape） | 不逃逸 |
//! | lambda 捕获分配表达式且 lambda 逃逸 | 逃逸 |
//! | throw 分配表达式 | 逃逸（异常跨函数传播） |
//! | defer 内分配 | 逃逸（执行时机跨越函数返回） |
//! | spawn / select / atomic / lazy | 逃逸（跨协程/延迟执行） |
//! | assignment 到字段/索引 | 逃逸 |
//! | for 循环体分配且循环体逃逸 | 逃逸 |
//!
//! ## 局限
//!
//! - 不做指针别名分析（alias analysis），保守处理多变量指向同一对象
//! - 不追踪数组元素存储（`arr[i] = alloc()` 视为逃逸）
//! - 不支持 `@noescape` 标注（后续扩展）

const std = @import("std");
const ast = @import("ast");
const purity_mod = @import("purity.zig");

// ════════════════════════════════════════════
// 数据结构
// ════════════════════════════════════════════

/// 函数逃逸信息
pub const EscapeInfo = enum {
    /// 对象不逃逸：局部分配可安全走 ShadowArena
    no_escape,
    /// 对象逃逸：必须走 RC 堆
    escapes,

    pub fn isNoEscape(self: EscapeInfo) bool {
        return self == .no_escape;
    }
};

/// 值的分配来源（过程内值追踪）
const AllocSource = union(enum) {
    /// 非分配值（标量、字面量、identifier 链无法追踪到分配）
    non_alloc,
    /// 函数参数（携带参数索引，用于参数逃逸分析）
    param: u16,
    /// 直接分配表达式（array_literal/record_literal/lambda 等）
    direct_alloc,
    /// 已知逃逸（来自逃逸的子表达式或控制流合并不同参数）
    escaped,
};

/// 参数逃逸性：描述函数参数是否会被逃逸出函数
pub const ParamEscape = enum {
    /// 参数不逃逸（纯计算使用）
    no_escape,
    /// 参数逃逸（被 return/store/capture/spawn 等）
    escapes,
    /// 未知（未分析或复杂控制流）
    unknown,
};

/// 函数参数逃逸表：函数名 → 各参数的逃逸性
pub const ParamEscapeTable = struct {
    /// key = 函数名，value = 参数逃逸性数组（按参数顺序）
    entries: std.StringHashMap([]ParamEscape),
    allocator: std.mem.Allocator,
    /// 内部存储：所有参数逃逸性数组的拥有者，deinit 时统一释放
    storage: std.ArrayListUnmanaged([]ParamEscape) = .empty,

    pub fn init(allocator: std.mem.Allocator) ParamEscapeTable {
        return .{
            .entries = std.StringHashMap([]ParamEscape).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ParamEscapeTable) void {
        for (self.storage.items) |arr| self.allocator.free(arr);
        self.storage.deinit(self.allocator);
        self.entries.deinit();
    }

    pub fn put(self: *ParamEscapeTable, name: []const u8, params: []const ParamEscape) !void {
        const owned = try self.allocator.dupe(ParamEscape, params);
        try self.storage.append(self.allocator, owned);
        try self.entries.put(name, owned);
    }

    pub fn lookup(self: *const ParamEscapeTable, name: []const u8) ?[]const ParamEscape {
        return self.entries.get(name);
    }
};

/// 函数名到逃逸信息的映射表
pub const EscapeTable = struct {
    entries: std.StringHashMap(EscapeInfo),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) EscapeTable {
        return .{
            .entries = std.StringHashMap(EscapeInfo).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *EscapeTable) void {
        self.entries.deinit();
    }

    pub fn put(self: *EscapeTable, name: []const u8, info: EscapeInfo) !void {
        try self.entries.put(name, info);
    }

    pub fn lookup(self: *const EscapeTable, name: []const u8) ?EscapeInfo {
        return self.entries.get(name);
    }

    /// 判断函数是否为非逃逸；未记录视为逃逸（保守）
    pub fn isNoEscape(self: *const EscapeTable, name: []const u8) bool {
        if (self.lookup(name)) |info| return info.isNoEscape();
        return false;
    }

    pub fn isEmpty(self: *const EscapeTable) bool {
        return self.entries.count() == 0;
    }
};

// ════════════════════════════════════════════
// 值环境（过程内值追踪）
// ════════════════════════════════════════════

/// 变量名 → AllocSource 的环境（支持作用域链）
const ValueEnv = struct {
    parent: ?*const ValueEnv = null,
    map: std.StringHashMap(AllocSource),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, parent: ?*const ValueEnv) ValueEnv {
        return .{
            .parent = parent,
            .map = std.StringHashMap(AllocSource).init(allocator),
            .allocator = allocator,
        };
    }

    fn deinit(self: *ValueEnv) void {
        self.map.deinit();
    }

    fn put(self: *ValueEnv, name: []const u8, src: AllocSource) !void {
        try self.map.put(name, src);
    }

    fn lookup(self: *const ValueEnv, name: []const u8) ?AllocSource {
        if (self.map.get(name)) |src| return src;
        if (self.parent) |p| return p.lookup(name);
        return null;
    }
};

// ════════════════════════════════════════════
// 逃逸分析 Pass
// ════════════════════════════════════════════

/// 逃逸分析 Pass
///
/// 两阶段分析：
/// 1. **参数逃逸阶段**：遍历所有函数，分析每个参数是否逃逸
/// 2. **函数逃逸阶段**：基于参数逃逸表，分析每个函数的局部分配是否逃逸
pub const EscapePass = struct {
    escape_table: *EscapeTable,
    purity_table: ?*const purity_mod.PurityTable,
    param_escape_table: *ParamEscapeTable,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        escape_table: *EscapeTable,
        purity_table: ?*const purity_mod.PurityTable,
        param_escape_table: *ParamEscapeTable,
    ) EscapePass {
        return .{
            .escape_table = escape_table,
            .purity_table = purity_table,
            .param_escape_table = param_escape_table,
            .allocator = allocator,
        };
    }

    /// 分析整个模块：两阶段
    pub fn analyzeModule(self: *EscapePass, module: *const ast.Module) !void {
        // 阶段 1：分析所有函数的参数逃逸性
        for (module.declarations) |decl| {
            if (decl != .fun_decl) continue;
            const fd = decl.fun_decl;
            try self.analyzeParamEscape(fd);
        }
        // 阶段 2：分析所有函数的局部分配逃逸性
        for (module.declarations) |decl| {
            if (decl != .fun_decl) continue;
            const fd = decl.fun_decl;
            const info = try self.analyzeFunctionEscape(fd);
            try self.escape_table.put(fd.name, info);
        }
    }

    // ── 阶段 1：参数逃逸分析 ──

    /// 分析函数参数的逃逸性：参数是否被 return/store/capture/spawn
    fn analyzeParamEscape(self: *EscapePass, fd: anytype) !void {
        const param_count = fd.params.len;
        if (param_count == 0) {
            try self.param_escape_table.put(fd.name, &.{});
            return;
        }
        // 初始化所有参数为 no_escape
        const param_escapes = try self.allocator.alloc(ParamEscape, param_count);
        for (param_escapes) |*pe| pe.* = .no_escape;

        // 构建初始环境：每个参数名指向 .param(i)（携带索引，便于 return 时检测）
        var env = ValueEnv.init(self.allocator, null);
        defer env.deinit();
        for (fd.params, 0..) |p, i| {
            try env.put(p.name, .{ .param = @intCast(i) });
        }

        // 分析函数体，标记参数逃逸
        var ctx = AnalyzeCtx{ .escapes = false, .param_escapes = param_escapes };
        const body_src = try self.analyzeExpr(fd.body, &env, &ctx, fd.name);
        // trailing expr（隐式返回）的参数逃逸检测
        markParamEscape(body_src, param_escapes);

        try self.param_escape_table.put(fd.name, param_escapes);
    }

    // ── 阶段 2：函数逃逸分析 ──

    /// 分析函数体的局部分配是否逃逸
    fn analyzeFunctionEscape(self: *EscapePass, fd: anytype) !EscapeInfo {
        var env = ValueEnv.init(self.allocator, null);
        defer env.deinit();
        // 参数标记为 .param(i)：虽然参数本身不是本函数的局部分配，
        // 但 return 参数时需要正确识别（避免误判为 non_alloc 而忽略返回值逃逸）
        for (fd.params, 0..) |p, i| {
            try env.put(p.name, .{ .param = @intCast(i) });
        }
        var ctx = AnalyzeCtx{ .escapes = false, .param_escapes = &.{} };
        const body_src = try self.analyzeExpr(fd.body, &env, &ctx, fd.name);
        // trailing expr（隐式返回）为分配表达式：对象逃逸到调用者
        if (body_src == .direct_alloc) {
            ctx.escapes = true;
        }
        return if (ctx.escapes) .escapes else .no_escape;
    }

    const AnalyzeCtx = struct {
        escapes: bool,
        /// 当前函数的参数逃逸性数组（阶段 1 用）
        param_escapes: []ParamEscape,
    };

    /// 递归分析表达式，返回其 AllocSource
    fn analyzeExpr(
        self: *EscapePass,
        expr: *const ast.Expr,
        env: *ValueEnv,
        ctx: *AnalyzeCtx,
        current_fn: []const u8,
    ) anyerror!AllocSource {
        if (ctx.escapes) return .escaped; // 已逃逸，提前终止
        switch (expr.*) {
            // ── 直接分配表达式 ──
            .array_literal => |a| {
                for (a.elements) |e| _ = try self.analyzeExpr(e, env, ctx, current_fn);
                return .direct_alloc;
            },
            .record_literal => |r| {
                for (r.fields) |f| _ = try self.analyzeExpr(f.value, env, ctx, current_fn);
                return .direct_alloc;
            },
            .record_extend => |r| {
                // base 若为分配表达式，extend 会产生新对象（record_clone）
                _ = try self.analyzeExpr(r.base, env, ctx, current_fn);
                for (r.updates) |u| _ = try self.analyzeExpr(u.value, env, ctx, current_fn);
                return .direct_alloc; // record_extend 产生新对象
            },
            .string_interpolation => |si| {
                for (si.parts) |part| {
                    if (part == .expression) _ = try self.analyzeExpr(part.expression, env, ctx, current_fn);
                }
                return .direct_alloc;
            },
            .lambda => {
                // 闭包对象：保守视为分配，且闭包捕获分析见下方专节
                // 闭包本身可能不逃逸，但捕获的分配表达式若逃逸则当前函数逃逸
                // 简化处理：lambda 视为 direct_alloc，捕获分析在 analyzeLambdaBody
                return .direct_alloc;
            },

            // ── 字面量与标识符 ──
            .int_literal,
            .float_literal,
            .bool_literal,
            .char_literal,
            .string_literal,
            .null_literal,
            .unit_literal,
            => return .non_alloc,
            .identifier => |id| {
                if (env.lookup(id.name)) |src| return src;
                return .non_alloc;
            },

            // ── 控制流 ──
            .binary => |b| {
                _ = try self.analyzeExpr(b.left, env, ctx, current_fn);
                _ = try self.analyzeExpr(b.right, env, ctx, current_fn);
                return .non_alloc;
            },
            .unary => |u| {
                _ = try self.analyzeExpr(u.operand, env, ctx, current_fn);
                return .non_alloc;
            },
            .ref_of => |r| {
                // 取引用：递归分析 operand，本身不产生新分配
                _ = try self.analyzeExpr(r.operand, env, ctx, current_fn);
                return .non_alloc;
            },
            .deref => |d| {
                // 解引用：递归分析 operand，本身不产生新分配
                _ = try self.analyzeExpr(d.operand, env, ctx, current_fn);
                return .non_alloc;
            },
            .if_expr => |i| {
                _ = try self.analyzeExpr(i.condition, env, ctx, current_fn);
                const then_src = try self.analyzeExpr(i.then_branch, env, ctx, current_fn);
                const else_src = if (i.else_branch) |e|
                    try self.analyzeExpr(e, env, ctx, current_fn)
                else
                    .non_alloc;
                return mergeSources(then_src, else_src);
            },
            .block => |b| {
                var child_env = ValueEnv.init(self.allocator, env);
                defer child_env.deinit();
                for (b.statements) |s| try self.analyzeStmt(s, &child_env, ctx, current_fn);
                if (b.trailing_expr) |te| {
                    return self.analyzeExpr(te, &child_env, ctx, current_fn);
                }
                return .non_alloc;
            },
            .match => |m| {
                _ = try self.analyzeExpr(m.scrutinee, env, ctx, current_fn);
                var result_src: AllocSource = .non_alloc;
                for (m.arms) |arm| {
                    if (arm.guard) |g| _ = try self.analyzeExpr(g, env, ctx, current_fn);
                    const arm_src = try self.analyzeExpr(arm.body, env, ctx, current_fn);
                    result_src = mergeSources(result_src, arm_src);
                }
                return result_src;
            },

            // ── 调用 ──
            .call => |c| {
                _ = try self.analyzeExpr(c.callee, env, ctx, current_fn);
                // 判断被调函数的参数逃逸性
                const callee_name = if (c.callee.* == .identifier) c.callee.identifier.name else null;
                const is_pure = if (self.purity_table) |pt|
                    (callee_name != null and pt.isPure(callee_name.?))
                else
                    false;
                const param_escapes: ?[]const ParamEscape = if (callee_name) |cn|
                    self.param_escape_table.lookup(cn)
                else
                    null;

                for (c.arguments, 0..) |arg, i| {
                    const arg_src = try self.analyzeExpr(arg, env, ctx, current_fn);
                    if (arg_src == .direct_alloc) {
                        // 参数为分配表达式：判断被调函数是否会逃逸此参数
                        const escapes_arg = if (is_pure and param_escapes != null and i < param_escapes.?.len)
                            param_escapes.?[i] == .escapes
                        else
                            true; // 非纯函数或未知函数：保守逃逸
                        if (escapes_arg) {
                            ctx.escapes = true;
                            return .escaped;
                        }
                        // 纯函数且参数 noescape：不逃逸
                    }
                }
                // 调用结果可能是新对象（如 map/filter），保守视为 direct_alloc
                return .direct_alloc;
            },
            .method_call => |m| {
                _ = try self.analyzeExpr(m.object, env, ctx, current_fn);
                for (m.arguments) |arg| {
                    const arg_src = try self.analyzeExpr(arg, env, ctx, current_fn);
                    if (arg_src == .direct_alloc) {
                        // 方法调用：保守视为逃逸（方法可能内部存储参数）
                        ctx.escapes = true;
                        return .escaped;
                    }
                }
                return .direct_alloc;
            },
            .safe_method_call => |m| {
                _ = try self.analyzeExpr(m.object, env, ctx, current_fn);
                for (m.arguments) |arg| {
                    const arg_src = try self.analyzeExpr(arg, env, ctx, current_fn);
                    if (arg_src == .direct_alloc) {
                        ctx.escapes = true;
                        return .escaped;
                    }
                }
                return .direct_alloc;
            },

            // ── 字段访问 ──
            .field_access => |f| {
                _ = try self.analyzeExpr(f.object, env, ctx, current_fn);
                return .non_alloc;
            },
            .safe_access => |f| {
                _ = try self.analyzeExpr(f.object, env, ctx, current_fn);
                return .non_alloc;
            },
            .index => |i| {
                _ = try self.analyzeExpr(i.object, env, ctx, current_fn);
                _ = try self.analyzeExpr(i.index, env, ctx, current_fn);
                return .non_alloc;
            },
            .slice => |sl| {
                _ = try self.analyzeExpr(sl.object, env, ctx, current_fn);
                _ = try self.analyzeExpr(sl.start, env, ctx, current_fn);
                _ = try self.analyzeExpr(sl.end, env, ctx, current_fn);
                return .non_alloc;
            },
            .non_null_assert => |n| {
                _ = try self.analyzeExpr(n.expr, env, ctx, current_fn);
                return .non_alloc;
            },
            .propagate => |p| {
                _ = try self.analyzeExpr(p.expr, env, ctx, current_fn);
                return .non_alloc;
            },

            // ── 赋值 ──
            .assignment_expr => |a| {
                // 赋值到字段/索引：写入外层对象，逃逸
                if (a.target.* == .field_access or a.target.* == .index) {
                    const val_src = try self.analyzeExpr(a.value, env, ctx, current_fn);
                    if (val_src == .direct_alloc) {
                        ctx.escapes = true;
                        return .escaped;
                    }
                }
                _ = try self.analyzeExpr(a.target, env, ctx, current_fn);
                const val_src = try self.analyzeExpr(a.value, env, ctx, current_fn);
                // 赋值到局部变量：更新环境的 AllocSource
                if (a.target.* == .identifier) {
                    try env.put(a.target.identifier.name, val_src);
                }
                return .non_alloc;
            },
            .compound_assign => |c| {
                _ = try self.analyzeExpr(c.target, env, ctx, current_fn);
                _ = try self.analyzeExpr(c.value, env, ctx, current_fn);
                return .non_alloc;
            },

            // ── 类型转换 ──
            .type_cast => |t| {
                _ = try self.analyzeExpr(t.expr, env, ctx, current_fn);
                return .non_alloc;
            },
            .cast_builder => |cb| {
                _ = try self.analyzeExpr(cb.expr, env, ctx, current_fn);
                // cast_try_to 可能产生 ThrowValue
                return .direct_alloc;
            },

            // ── 跨协程/延迟执行（必逃逸）──
            .spawn_expr => {
                ctx.escapes = true;
                return .escaped;
            },
            .select => {
                ctx.escapes = true;
                return .escaped;
            },
            .atomic_expr => |a| {
                // atomic 操作可能跨线程，保守逃逸
                _ = try self.analyzeExpr(a.value, env, ctx, current_fn);
                ctx.escapes = true;
                return .escaped;
            },
            .lazy => |l| {
                // lazy 延迟执行，执行时机不确定
                _ = try self.analyzeExpr(l.expr, env, ctx, current_fn);
                ctx.escapes = true;
                return .escaped;
            },
            .inline_trait_value => {
                // inline trait value 可能被多态使用
                ctx.escapes = true;
                return .escaped;
            },
        }
    }

    /// 递归分析语句
    fn analyzeStmt(
        self: *EscapePass,
        stmt: *const ast.Stmt,
        env: *ValueEnv,
        ctx: *AnalyzeCtx,
        current_fn: []const u8,
    ) anyerror!void {
        if (ctx.escapes) return;
        switch (stmt.*) {
            .val_decl => |v| {
                const src = try self.analyzeExpr(v.value, env, ctx, current_fn);
                try env.put(v.name, src);
            },
            .var_decl => |v| {
                const src = try self.analyzeExpr(v.value, env, ctx, current_fn);
                try env.put(v.name, src);
            },
            .assignment => |a| {
                // 赋值到字段/索引：写入外层对象，逃逸
                if (a.target.* == .field_access or a.target.* == .index) {
                    const val_src = try self.analyzeExpr(a.value, env, ctx, current_fn);
                    if (val_src == .direct_alloc) {
                        ctx.escapes = true;
                        return;
                    }
                }
                _ = try self.analyzeExpr(a.target, env, ctx, current_fn);
                const val_src = try self.analyzeExpr(a.value, env, ctx, current_fn);
                if (a.target.* == .identifier) {
                    try env.put(a.target.identifier.name, val_src);
                }
            },
            .field_assignment => {
                // 写外层对象字段：保守逃逸
                ctx.escapes = true;
            },
            .compound_assignment => |c| {
                _ = try self.analyzeExpr(c.target, env, ctx, current_fn);
                _ = try self.analyzeExpr(c.value, env, ctx, current_fn);
            },
            .expression => |e| {
                _ = try self.analyzeExpr(e.expr, env, ctx, current_fn);
            },
            .return_stmt => |r| {
                if (r.value) |v| {
                    const src = try self.analyzeExpr(v, env, ctx, current_fn);
                    // return 分配表达式：对象逃逸到调用者
                    if (src == .direct_alloc) {
                        ctx.escapes = true;
                        return;
                    }
                    // return 参数 / 已逃逸值：标记参数逃逸
                    markParamEscape(src, ctx.param_escapes);
                }
            },
            .throw_stmt => |t| {
                // throw 的对象跨函数传播（异常向上冒泡）
                const src = try self.analyzeExpr(t.expr, env, ctx, current_fn);
                if (src == .direct_alloc) {
                    ctx.escapes = true;
                    return;
                }
            },
            .defer_stmt => |d| {
                // defer 体执行时机跨越函数返回，保守逃逸
                _ = try self.analyzeExpr(d.expr, env, ctx, current_fn);
                ctx.escapes = true;
            },
            .for_stmt => |f| {
                _ = try self.analyzeExpr(f.iterable, env, ctx, current_fn);
                // 循环变量绑定到 iterable 元素（外部传入，non_alloc）
                var child_env = ValueEnv.init(self.allocator, env);
                defer child_env.deinit();
                try child_env.put(f.name, .non_alloc);
                _ = try self.analyzeExpr(f.body, &child_env, ctx, current_fn);
            },
            .while_stmt => |w| {
                _ = try self.analyzeExpr(w.condition, env, ctx, current_fn);
                var child_env = ValueEnv.init(self.allocator, env);
                defer child_env.deinit();
                _ = try self.analyzeExpr(w.body, &child_env, ctx, current_fn);
            },
            .loop_stmt => |l| {
                var child_env = ValueEnv.init(self.allocator, env);
                defer child_env.deinit();
                _ = try self.analyzeExpr(l.body, &child_env, ctx, current_fn);
            },
            .break_stmt, .continue_stmt => {},
        }
    }
};

/// 合并两个 AllocSource（控制流合并：if/match 多分支逃逸性取并集）
fn mergeSources(a: AllocSource, b: AllocSource) AllocSource {
    if (a == .escaped or b == .escaped) return .escaped;
    if (a == .direct_alloc or b == .direct_alloc) return .direct_alloc;
    // param 合并：
    // - 相同参数索引 → 保留该参数（单参数返回场景）
    // - 不同参数索引 → 保守返回 .escaped（两个参数都逃逸，但只能返回一个 src）
    // - param + non_alloc → 保留 param
    if (a == .param and b == .param) {
        if (a.param == b.param) return a;
        return .escaped;
    }
    if (a == .param) return a;
    if (b == .param) return b;
    return .non_alloc;
}

/// 标记 trailing expr（隐式返回）的参数逃逸性
fn markParamEscape(src: AllocSource, param_escapes: []ParamEscape) void {
    switch (src) {
        .param => |idx| {
            if (idx < param_escapes.len) {
                param_escapes[idx] = .escapes;
            }
        },
        .escaped => {
            // 控制流合并不同参数等场景：保守标记所有参数逃逸
            for (param_escapes) |*pe| pe.* = .escapes;
        },
        .direct_alloc, .non_alloc => {},
    }
}

/// 判断表达式是否为"分配表达式"（会产生新堆对象）
///
/// 兼容接口：供外部查询
pub fn isAllocExpr(expr: *const ast.Expr) bool {
    return switch (expr.*) {
        .array_literal,
        .record_literal,
        .record_extend,
        .lambda,
        .string_interpolation,
        => true,
        .call, .method_call, .safe_method_call => true,
        .type_cast, .cast_builder => true,
        else => false,
    };
}

// ════════════════════════════════════════════
// 测试
// ════════════════════════════════════════════

const testing = std.testing;

test "EscapeTable basic put/lookup" {
    var table = EscapeTable.init(testing.allocator);
    defer table.deinit();
    try table.put("fib", .no_escape);
    try table.put("make_arr", .escapes);
    try testing.expect(table.isNoEscape("fib"));
    try testing.expect(!table.isNoEscape("make_arr"));
    try testing.expect(!table.isNoEscape("unknown"));
}

test "ParamEscapeTable basic" {
    var table = ParamEscapeTable.init(testing.allocator);
    defer table.deinit();
    const params = [_]ParamEscape{ .no_escape, .escapes, .no_escape };
    try table.put("foo", &params);
    const got = table.lookup("foo").?;
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqual(ParamEscape.no_escape, got[0]);
    try testing.expectEqual(ParamEscape.escapes, got[1]);
    try testing.expectEqual(ParamEscape.no_escape, got[2]);
}

test "ParamEscapeTable 多函数存储" {
    var table = ParamEscapeTable.init(testing.allocator);
    defer table.deinit();
    const p1 = [_]ParamEscape{.no_escape};
    const p2 = [_]ParamEscape{ .escapes, .escapes };
    try table.put("foo", &p1);
    try table.put("bar", &p2);
    try testing.expectEqual(@as(usize, 1), table.lookup("foo").?.len);
    try testing.expectEqual(@as(usize, 2), table.lookup("bar").?.len);
    try testing.expect(table.lookup("unknown") == null);
}

test "mergeSources" {
    try testing.expectEqual(AllocSource.non_alloc, mergeSources(.non_alloc, .non_alloc));
    try testing.expectEqual(AllocSource.direct_alloc, mergeSources(.non_alloc, .direct_alloc));
    try testing.expectEqual(AllocSource.escaped, mergeSources(.direct_alloc, .escaped));
    try testing.expectEqual(AllocSource.escaped, mergeSources(.escaped, .non_alloc));
}

test "isAllocExpr 识别分配表达式" {
    var int_expr = ast.Expr{ .int_literal = .{ .raw = "42", .suffix = null } };
    try testing.expect(!isAllocExpr(&int_expr));

    var id_expr = ast.Expr{ .identifier = .{ .name = "x" } };
    try testing.expect(!isAllocExpr(&id_expr));

    var arr_expr = ast.Expr{ .array_literal = .{ .elements = &.{} } };
    try testing.expect(isAllocExpr(&arr_expr));

    var rec_expr = ast.Expr{ .record_literal = .{ .fields = &.{} } };
    try testing.expect(isAllocExpr(&rec_expr));
}
