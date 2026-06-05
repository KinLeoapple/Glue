//! Glue 语言核心求值器
//!
//! 执行 AST 并产生运行时值，支持：
//! - 基本类型值（整数、浮点、布尔、字符、字符串、null、单位值）
//! - 表达式求值（字面量、二元/一元运算、函数调用、Lambda、if/match 等）
//! - 语句执行（val/var 声明、赋值、return/throw/defer/break/continue/for/while/loop）
//! - 模式匹配（通配符、字面量、变量绑定、构造器、记录、或模式、守卫）
//! - 闭包和词法作用域
//! - Nullable 相关操作（??, ?., !, ?）
//!
//! 本文件是 eval 模块的核心，依赖同目录下的：
//! - value.zig — 运行时值表示
//! - env.zig — 变量环境
//! - pattern.zig — 模式匹配
//! - throw.zig — throw 运行时处理
//! - module_eval.zig — 模块求值

const std = @import("std");
const ast = @import("ast");
const value = @import("value");
const env = @import("env");
const pattern = @import("pattern");
const throw_mod = @import("throw_mod");
const module_eval = @import("module_eval");

// ============================================================
// 便捷重导出
// ============================================================

pub const Value = value.Value;
pub const Range = value.Range;
pub const Environment = env.Environment;
pub const EvalError = value.EvalError;
pub const ControlFlow = value.ControlFlow;
pub const EvalResult = value.EvalResult;

// ============================================================
// 求值器
// ============================================================

pub const Evaluator = struct {
    allocator: std.mem.Allocator,
    global_env: Environment,
    io: ?std.Io = null,
    return_value: ?Value = null,
    throw_value: ?Value = null,
    closures: std.ArrayList(*value.Closure),

    pub fn init(allocator: std.mem.Allocator) Evaluator {
        var ev = Evaluator{
            .allocator = allocator,
            .global_env = Environment.init(allocator),
            .closures = std.ArrayList(*value.Closure).empty,
        };
        ev.registerBuiltins();
        return ev;
    }

    pub fn initWithIo(allocator: std.mem.Allocator, io: std.Io) Evaluator {
        var ev = Evaluator{
            .allocator = allocator,
            .global_env = Environment.init(allocator),
            .io = io,
            .closures = std.ArrayList(*value.Closure).empty,
        };
        ev.registerBuiltins();
        return ev;
    }

    pub fn deinit(self: *Evaluator) void {
        self.global_env.deinit();
        // 释放所有注册的闭包
        for (self.closures.items) |closure| {
            self.allocator.destroy(closure);
        }
        self.closures.deinit(self.allocator);
    }

    // ============================================================
    // 内建函数注册
    // ============================================================

    fn registerBuiltins(self: *Evaluator) void {

        // println
        self.global_env.define("println", Value{ .builtin = struct {
            fn call(ctx: *anyopaque, args: []const Value) anyerror!Value {
                const ev: *Evaluator = @ptrCast(@alignCast(ctx));
                return ev.builtinPrintln(args);
            }
        }.call }, true) catch {};
        // print
        self.global_env.define("print", Value{ .builtin = struct {
            fn call(ctx: *anyopaque, args: []const Value) anyerror!Value {
                const ev: *Evaluator = @ptrCast(@alignCast(ctx));
                return ev.builtinPrint(args);
            }
        }.call }, true) catch {};
        // eprintln
        self.global_env.define("eprintln", Value{ .builtin = struct {
            fn call(ctx: *anyopaque, args: []const Value) anyerror!Value {
                const ev: *Evaluator = @ptrCast(@alignCast(ctx));
                return ev.builtinEprintln(args);
            }
        }.call }, true) catch {};
        // eprint
        self.global_env.define("eprint", Value{ .builtin = struct {
            fn call(ctx: *anyopaque, args: []const Value) anyerror!Value {
                const ev: *Evaluator = @ptrCast(@alignCast(ctx));
                return ev.builtinEprint(args);
            }
        }.call }, true) catch {};
        // assert
        self.global_env.define("assert", Value{ .builtin = struct {
            fn call(ctx: *anyopaque, args: []const Value) anyerror!Value {
                const ev: *Evaluator = @ptrCast(@alignCast(ctx));
                return ev.builtinAssert(args);
            }
        }.call }, true) catch {};
        // precondition
        self.global_env.define("precondition", Value{ .builtin = struct {
            fn call(ctx: *anyopaque, args: []const Value) anyerror!Value {
                const ev: *Evaluator = @ptrCast(@alignCast(ctx));
                return ev.builtinPrecondition(args);
            }
        }.call }, true) catch {};
        // fatal
        self.global_env.define("fatal", Value{ .builtin = struct {
            fn call(ctx: *anyopaque, args: []const Value) anyerror!Value {
                const ev: *Evaluator = @ptrCast(@alignCast(ctx));
                return ev.builtinFatal(args);
            }
        }.call }, true) catch {};
        // eq (结构相等)
        self.global_env.define("eq", Value{ .builtin = struct {
            fn call(ctx: *anyopaque, args: []const Value) anyerror!Value {
                const ev: *Evaluator = @ptrCast(@alignCast(ctx));
                return ev.builtinEq(args);
            }
        }.call }, true) catch {};
        // string (类型转换)
        self.global_env.define("string", Value{ .builtin = struct {
            fn call(ctx: *anyopaque, args: []const Value) anyerror!Value {
                const ev: *Evaluator = @ptrCast(@alignCast(ctx));
                return ev.builtinString(args);
            }
        }.call }, true) catch {};
    }

    // ============================================================
    // 内建函数实现
    // ============================================================

    fn builtinPrintln(self: *Evaluator, args: []const Value) EvalError!Value {
        if (args.len != 1) return error.WrongArity;
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);
        args[0].format(&buf, self.allocator) catch return error.OutOfMemory;
        if (self.io) |io| {
            buf.append(self.allocator, '\n') catch {};
            var out_buf: [4096]u8 = undefined;
            var stdout_writer = std.Io.File.stdout().writerStreaming(io, &out_buf);
            stdout_writer.interface.print("{s}", .{buf.items}) catch {};
            stdout_writer.flush() catch {};
        } else {
            std.debug.print("{s}\n", .{buf.items});
        }
        return Value.unit;
    }

    fn builtinPrint(self: *Evaluator, args: []const Value) EvalError!Value {
        if (args.len != 1) return error.WrongArity;
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);
        args[0].format(&buf, self.allocator) catch return error.OutOfMemory;
        if (self.io) |io| {
            var out_buf: [4096]u8 = undefined;
            var stdout_writer = std.Io.File.stdout().writerStreaming(io, &out_buf);
            stdout_writer.interface.print("{s}", .{buf.items}) catch {};
            stdout_writer.flush() catch {};
        } else {
            std.debug.print("{s}", .{buf.items});
        }
        return Value.unit;
    }

    fn builtinEprintln(self: *Evaluator, args: []const Value) EvalError!Value {
        if (args.len != 1) return error.WrongArity;
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);
        args[0].format(&buf, self.allocator) catch return error.OutOfMemory;
        if (self.io) |io| {
            buf.append(self.allocator, '\n') catch {};
            var err_buf: [4096]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
            stderr_writer.interface.print("{s}", .{buf.items}) catch {};
            stderr_writer.flush() catch {};
        } else {
            std.debug.print("{s}\n", .{buf.items});
        }
        return Value.unit;
    }

    fn builtinEprint(self: *Evaluator, args: []const Value) EvalError!Value {
        if (args.len != 1) return error.WrongArity;
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);
        args[0].format(&buf, self.allocator) catch return error.OutOfMemory;
        if (self.io) |io| {
            var err_buf: [4096]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
            stderr_writer.interface.print("{s}", .{buf.items}) catch {};
            stderr_writer.flush() catch {};
        } else {
            std.debug.print("{s}", .{buf.items});
        }
        return Value.unit;
    }

    fn builtinAssert(self: *Evaluator, args: []const Value) EvalError!Value {
        _ = self;
        if (args.len != 1) return error.WrongArity;
        const cond = args[0];
        if (cond != .boolean or !cond.boolean) {
            @panic("assertion failed");
        }
        return Value.unit;
    }

    fn builtinPrecondition(self: *Evaluator, args: []const Value) EvalError!Value {
        _ = self;
        if (args.len != 1) return error.WrongArity;
        const cond = args[0];
        if (cond != .boolean or !cond.boolean) {
            @panic("precondition failed");
        }
        return Value.unit;
    }

    fn builtinFatal(self: *Evaluator, args: []const Value) EvalError!Value {
        if (args.len != 1) return error.WrongArity;
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);
        args[0].format(&buf, self.allocator) catch {};
        if (self.io) |io| {
            var err_buf: [4096]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
            stderr_writer.interface.print("{s}", .{buf.items}) catch {};
            stderr_writer.flush() catch {};
        } else {
            std.debug.print("{s}", .{buf.items});
        }
        return error.Unreachable;
    }

    fn builtinEq(self: *Evaluator, args: []const Value) EvalError!Value {
        _ = self;
        if (args.len != 2) return error.WrongArity;
        return Value{ .boolean = structuralEquals(args[0], args[1]) };
    }

    fn builtinString(self: *Evaluator, args: []const Value) EvalError!Value {
        if (args.len != 1) return error.WrongArity;
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(self.allocator);
        args[0].format(&buf, self.allocator) catch return error.OutOfMemory;
        return Value{ .string = buf.toOwnedSlice(self.allocator) catch return error.OutOfMemory };
    }

    // ============================================================
    // 模块求值
    // ============================================================

    pub fn evalModule(self: *Evaluator, module: ast.Module) !void {
        for (module.declarations) |decl| {
            try self.evalDecl(decl, &self.global_env);
        }
    }

    pub fn evalDecl(self: *Evaluator, decl: ast.Decl, environment: *Environment) !void {
        switch (decl) {
            .fun_decl => |f| {
                const closure = try self.allocator.create(value.Closure);
                closure.* = value.Closure{
                    .params = f.params,
                    .body = .{ .block = f.body },
                    .env = @ptrCast(environment),
                    .allocator = self.allocator,
                };
                try self.closures.append(self.allocator, closure);
                try environment.define(f.name, Value{ .closure = closure }, false);
            },
            .type_decl => {
                // Phase 1: 简单处理，注册类型名但不做更多
            },
            .trait_decl => {
                // Phase 1: 简单处理
            },
            .impl_decl => {
                // Phase 1: 简单处理
            },
            .use_decl => {
                // Phase 1: 简单处理
            },
            .pack_decl => {
                // Phase 1: 简单处理
            },
            .expr_decl => |ed| {
                if (ed.stmt) |s| {
                    var defer_stack = std.ArrayList(*const ast.Expr).empty;
                    defer defer_stack.deinit(self.allocator);
                    _ = try self.evalStmt(s, environment, &defer_stack);
                } else {
                    _ = try self.evalExpr(ed.expr, environment);
                }
            },
        }
    }

    // ============================================================
    // 表达式求值
    // ============================================================

    pub fn evalExpr(self: *Evaluator, expr: *const ast.Expr, environment: *Environment) EvalResult!Value {
        return switch (expr.*) {
            .int_literal => |lit| self.evalIntLiteral(lit),
            .float_literal => |lit| self.evalFloatLiteral(lit),
            .bool_literal => |lit| Value{ .boolean = lit.value },
            .char_literal => |lit| Value{ .char_val = lit.value },
            .string_literal => |lit| Value{ .string = try self.allocator.dupe(u8, lit.value) },
            .string_interpolation => |interp| self.evalStringInterpolation(interp, environment),
            .null_literal => Value.null_val,
            .unit_literal => Value.unit,
            .identifier => |id| self.evalIdentifier(id, environment),
            .binary => |bin| self.evalBinary(bin, environment),
            .unary => |un| self.evalUnary(un, environment),
            .call => |c| self.evalCall(c, environment),
            .method_call => |mc| self.evalMethodCall(mc, environment),
            .field_access => |fa| self.evalFieldAccess(fa, environment),
            .safe_access => |sa| self.evalSafeAccess(sa, environment),
            .safe_method_call => |smc| self.evalSafeMethodCall(smc, environment),
            .non_null_assert => |nna| self.evalNonNullAssert(nna, environment),
            .propagate => |prop| self.evalPropagate(prop, environment),
            .index => |idx| self.evalIndex(idx, environment),
            .array_literal => |al| self.evalArrayLiteral(al, environment),
            .record_literal => |rl| self.evalRecordLiteral(rl, environment),
            .lambda => |lam| self.evalLambda(lam, environment),
            .if_expr => |ie| self.evalIfExpr(ie, environment),
            .block => |blk| self.evalBlock(blk, environment),
            .match => |m| self.evalMatch(m, environment),
            .type_cast => |tc| self.evalTypeCast(tc, environment),
            .spawn => error.UnsupportedOperation,
            .lazy => error.UnsupportedOperation,
            .select => error.UnsupportedOperation,
            .monad_comprehension => error.UnsupportedOperation,
            .inline_trait_value => error.UnsupportedOperation,
        };
    }

    fn evalIntLiteral(self: *Evaluator, lit: @TypeOf(@as(ast.Expr, undefined).int_literal)) EvalResult!Value {
        const raw = lit.raw;
        const suffix = lit.suffix;

        // 解析整数值
        const int_val = parseInt(i128, raw) catch
            return error.IntegerOverflow;

        // 如果有类型后缀，检查范围
        if (suffix) |s| {
            return self.castInteger(int_val, s);
        }

        // 默认 i32
        return self.castInteger(int_val, "i32");
    }

    fn evalFloatLiteral(self: *Evaluator, lit: @TypeOf(@as(ast.Expr, undefined).float_literal)) EvalResult!Value {
        _ = self;
        const raw = lit.raw;
        const suffix = lit.suffix;

        const float_val = parseFloat(f64, raw) catch
            return error.TypeMismatch;

        if (suffix) |s| {
            if (std.mem.eql(u8, s, "f32")) {
                const f32_val: f32 = @floatCast(float_val);
                return Value{ .float = @floatCast(f32_val) };
            }
        }

        return Value{ .float = float_val };
    }

    fn evalStringInterpolation(self: *Evaluator, interp: @TypeOf(@as(ast.Expr, undefined).string_interpolation), environment: *Environment) EvalResult!Value {
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(self.allocator);

        for (interp.parts) |part| {
            switch (part) {
                .literal => |text| {
                    try result.appendSlice(self.allocator, text);
                },
                .expression => |expr| {
                    const val = try self.evalExpr(expr, environment);
                    var buf = std.ArrayList(u8).empty;
                    defer buf.deinit(self.allocator);
                    try val.format(&buf, self.allocator);
                    try result.appendSlice(self.allocator, buf.items);
                },
            }
        }

        return Value{ .string = try result.toOwnedSlice(self.allocator) };
    }

    fn evalIdentifier(self: *Evaluator, id: @TypeOf(@as(ast.Expr, undefined).identifier), environment: *Environment) EvalResult!Value {
        _ = self;
        if (environment.get(id.name)) |v| {
            return v.value;
        }
        return error.UndefinedVariable;
    }

    // ============================================================
    // 二元运算
    // ============================================================

    fn evalBinary(self: *Evaluator, bin: @TypeOf(@as(ast.Expr, undefined).binary), environment: *Environment) EvalResult!Value {
        // 短路运算符
        switch (bin.op) {
            .and_op => {
                const left = try self.evalExpr(bin.left, environment);
                if (!try left.asBoolean()) return Value{ .boolean = false };
                const right = try self.evalExpr(bin.right, environment);
                return Value{ .boolean = try right.asBoolean() };
            },
            .or_op => {
                const left = try self.evalExpr(bin.left, environment);
                if (try left.asBoolean()) return Value{ .boolean = true };
                const right = try self.evalExpr(bin.right, environment);
                return Value{ .boolean = try right.asBoolean() };
            },
            .elvis => {
                const left = try self.evalExpr(bin.left, environment);
                if (!left.isNull()) return left;
                return try self.evalExpr(bin.right, environment);
            },
            else => {},
        }

        const left = try self.evalExpr(bin.left, environment);
        const right = try self.evalExpr(bin.right, environment);

        switch (bin.op) {
            .add => return self.evalAdd(left, right),
            .sub => return self.evalSub(left, right),
            .mul => return self.evalMul(left, right),
            .div => return self.evalDiv(left, right, bin.location),
            .mod => return self.evalMod(left, right, bin.location),
            .eq => return Value{ .boolean = left.equals(right) },
            .not_eq => return Value{ .boolean = !left.equals(right) },
            .lt => return self.evalLt(left, right),
            .gt => return self.evalGt(left, right),
            .lt_eq => return self.evalLtEq(left, right),
            .gt_eq => return self.evalGtEq(left, right),
            .concat => return self.evalConcat(left, right),
            .range => {
                const left_int = try left.asInteger();
                const right_int = try right.asInteger();
                return Value{ .range = Range{ .start = left_int, .end = right_int, .inclusive = false } };
            },
            .range_inclusive => {
                const left_int = try left.asInteger();
                const right_int = try right.asInteger();
                return Value{ .range = Range{ .start = left_int, .end = right_int, .inclusive = true } };
            },
            else => unreachable,
        }
    }

    fn evalAdd(self: *Evaluator, left: Value, right: Value) EvalResult!Value {
        if (left == .integer and right == .integer) {
            const result = @addWithOverflow(left.integer, right.integer);
            if (result[1] != 0) return error.IntegerOverflow;
            return Value{ .integer = result[0] };
        }
        if (left == .float and right == .float) {
            return Value{ .float = left.float + right.float };
        }
        if (left == .integer and right == .float) {
            return Value{ .float = @as(f64, @floatFromInt(left.integer)) + right.float };
        }
        if (left == .float and right == .integer) {
            return Value{ .float = left.float + @as(f64, @floatFromInt(right.integer)) };
        }
        if (left == .string and right == .string) {
            var result = std.ArrayList(u8).empty;
            try result.appendSlice(self.allocator, left.string);
            try result.appendSlice(self.allocator, right.string);
            return Value{ .string = try result.toOwnedSlice(self.allocator) };
        }
        return error.TypeMismatch;
    }

    fn evalSub(self: *Evaluator, left: Value, right: Value) EvalResult!Value {
        _ = self;
        if (left == .integer and right == .integer) {
            const result = @subWithOverflow(left.integer, right.integer);
            if (result[1] != 0) return error.IntegerOverflow;
            return Value{ .integer = result[0] };
        }
        if (left == .float and right == .float) {
            return Value{ .float = left.float - right.float };
        }
        if (left == .integer and right == .float) {
            return Value{ .float = @as(f64, @floatFromInt(left.integer)) - right.float };
        }
        if (left == .float and right == .integer) {
            return Value{ .float = left.float - @as(f64, @floatFromInt(right.integer)) };
        }
        return error.TypeMismatch;
    }

    fn evalMul(self: *Evaluator, left: Value, right: Value) EvalResult!Value {
        _ = self;
        if (left == .integer and right == .integer) {
            const result = @mulWithOverflow(left.integer, right.integer);
            if (result[1] != 0) return error.IntegerOverflow;
            return Value{ .integer = result[0] };
        }
        if (left == .float and right == .float) {
            return Value{ .float = left.float * right.float };
        }
        if (left == .integer and right == .float) {
            return Value{ .float = @as(f64, @floatFromInt(left.integer)) * right.float };
        }
        if (left == .float and right == .integer) {
            return Value{ .float = left.float * @as(f64, @floatFromInt(right.integer)) };
        }
        return error.TypeMismatch;
    }

    fn evalDiv(self: *Evaluator, left: Value, right: Value, location: ast.SourceLocation) EvalResult!Value {
        _ = self;
        _ = location;
        if (left == .integer and right == .integer) {
            if (right.integer == 0) return error.DivisionByZero;
            // 检查 i128 最小值 / -1 溢出
            if (left.integer == std.math.minInt(i128) and right.integer == -1) {
                return error.IntegerOverflow;
            }
            return Value{ .integer = @divTrunc(left.integer, right.integer) };
        }
        if (left == .float and right == .float) {
            if (right.float == 0.0) return error.DivisionByZero;
            const result = left.float / right.float;
            if (std.math.isNan(result) or std.math.isInf(result)) {
                return error.DivisionByZero;
            }
            return Value{ .float = result };
        }
        if (left == .integer and right == .float) {
            if (right.float == 0.0) return error.DivisionByZero;
            const result = @as(f64, @floatFromInt(left.integer)) / right.float;
            if (std.math.isNan(result) or std.math.isInf(result)) {
                return error.DivisionByZero;
            }
            return Value{ .float = result };
        }
        if (left == .float and right == .integer) {
            if (right.integer == 0) return error.DivisionByZero;
            const result = left.float / @as(f64, @floatFromInt(right.integer));
            if (std.math.isNan(result) or std.math.isInf(result)) {
                return error.DivisionByZero;
            }
            return Value{ .float = result };
        }
        return error.TypeMismatch;
    }

    fn evalMod(self: *Evaluator, left: Value, right: Value, location: ast.SourceLocation) EvalResult!Value {
        _ = self;
        _ = location;
        if (left == .integer and right == .integer) {
            if (right.integer == 0) return error.DivisionByZero;
            return Value{ .integer = @mod(left.integer, right.integer) };
        }
        if (left == .float and right == .float) {
            if (right.float == 0.0) return error.DivisionByZero;
            return Value{ .float = @mod(left.float, right.float) };
        }
        return error.TypeMismatch;
    }

    fn evalLt(self: *Evaluator, left: Value, right: Value) EvalResult!Value {
        _ = self;
        if (left == .integer and right == .integer) return Value{ .boolean = left.integer < right.integer };
        if (left == .float and right == .float) return Value{ .boolean = left.float < right.float };
        if (left == .integer and right == .float) return Value{ .boolean = @as(f64, @floatFromInt(left.integer)) < right.float };
        if (left == .float and right == .integer) return Value{ .boolean = left.float < @as(f64, @floatFromInt(right.integer)) };
        if (left == .char_val and right == .char_val) return Value{ .boolean = left.char_val < right.char_val };
        if (left == .string and right == .string) return Value{ .boolean = std.mem.order(u8, left.string, right.string) == .lt };
        return error.TypeMismatch;
    }

    fn evalGt(self: *Evaluator, left: Value, right: Value) EvalResult!Value {
        _ = self;
        if (left == .integer and right == .integer) return Value{ .boolean = left.integer > right.integer };
        if (left == .float and right == .float) return Value{ .boolean = left.float > right.float };
        if (left == .integer and right == .float) return Value{ .boolean = @as(f64, @floatFromInt(left.integer)) > right.float };
        if (left == .float and right == .integer) return Value{ .boolean = left.float > @as(f64, @floatFromInt(right.integer)) };
        if (left == .char_val and right == .char_val) return Value{ .boolean = left.char_val > right.char_val };
        if (left == .string and right == .string) return Value{ .boolean = std.mem.order(u8, left.string, right.string) == .gt };
        return error.TypeMismatch;
    }

    fn evalLtEq(self: *Evaluator, left: Value, right: Value) EvalResult!Value {
        _ = self;
        if (left == .integer and right == .integer) return Value{ .boolean = left.integer <= right.integer };
        if (left == .float and right == .float) return Value{ .boolean = left.float <= right.float };
        if (left == .integer and right == .float) return Value{ .boolean = @as(f64, @floatFromInt(left.integer)) <= right.float };
        if (left == .float and right == .integer) return Value{ .boolean = left.float <= @as(f64, @floatFromInt(right.integer)) };
        if (left == .char_val and right == .char_val) return Value{ .boolean = left.char_val <= right.char_val };
        if (left == .string and right == .string) return Value{ .boolean = std.mem.order(u8, left.string, right.string) != .gt };
        return error.TypeMismatch;
    }

    fn evalGtEq(self: *Evaluator, left: Value, right: Value) EvalResult!Value {
        _ = self;
        if (left == .integer and right == .integer) return Value{ .boolean = left.integer >= right.integer };
        if (left == .float and right == .float) return Value{ .boolean = left.float >= right.float };
        if (left == .integer and right == .float) return Value{ .boolean = @as(f64, @floatFromInt(left.integer)) >= right.float };
        if (left == .float and right == .integer) return Value{ .boolean = left.float >= @as(f64, @floatFromInt(right.integer)) };
        if (left == .char_val and right == .char_val) return Value{ .boolean = left.char_val >= right.char_val };
        if (left == .string and right == .string) return Value{ .boolean = std.mem.order(u8, left.string, right.string) != .lt };
        return error.TypeMismatch;
    }

    fn evalConcat(self: *Evaluator, left: Value, right: Value) EvalResult!Value {
        const left_str = switch (left) {
            .string => |s| s,
            else => return error.TypeMismatch,
        };
        const right_str = switch (right) {
            .string => |s| s,
            else => return error.TypeMismatch,
        };
        var result = std.ArrayList(u8).empty;
        try result.appendSlice(self.allocator, left_str);
        try result.appendSlice(self.allocator, right_str);
        return Value{ .string = try result.toOwnedSlice(self.allocator) };
    }

    // ============================================================
    // 一元运算
    // ============================================================

    fn evalUnary(self: *Evaluator, un: @TypeOf(@as(ast.Expr, undefined).unary), environment: *Environment) EvalResult!Value {
        const operand = try self.evalExpr(un.operand, environment);
        return switch (un.op) {
            .not => switch (operand) {
                .boolean => |b| Value{ .boolean = !b },
                else => error.TypeMismatch,
            },
            .neg => switch (operand) {
                .integer => |i| {
                    const result = @subWithOverflow(@as(i128, 0), i);
                    if (result[1] != 0) return error.IntegerOverflow;
                    return Value{ .integer = result[0] };
                },
                .float => |f| Value{ .float = -f },
                else => error.TypeMismatch,
            },
        };
    }

    // ============================================================
    // 函数调用
    // ============================================================

    fn evalCall(self: *Evaluator, call: @TypeOf(@as(ast.Expr, undefined).call), environment: *Environment) EvalResult!Value {
        // 先检查是否是类型转换调用
        if (call.callee.* == .identifier) {
            const name = call.callee.identifier.name;
            if (isBuiltinType(name) and call.arguments.len == 1) {
                const arg = try self.evalExpr(call.arguments[0], environment);
                return self.castValue(arg, name);
            }
        }

        const callee = try self.evalExpr(call.callee, environment);

        // 求值参数
        var args = std.ArrayList(Value).empty;
        errdefer {
            for (args.items) |*a| a.deinit(self.allocator);
            args.deinit(self.allocator);
        }
        for (call.arguments) |arg_expr| {
            try args.append(self.allocator, try self.evalExpr(arg_expr, environment));
        }
        defer args.deinit(self.allocator);

        return self.callFunction(callee, args.items, environment);
    }

    fn callFunction(self: *Evaluator, callee: Value, args: []const Value, environment: ?*Environment) EvalResult!Value {
        _ = environment;
        switch (callee) {
            .closure => |closure| {
                if (args.len != closure.params.len) {
                    return error.WrongArity;
                }

                // 从 *anyopaque 恢复 *Environment
                const closure_env: *Environment = @ptrCast(@alignCast(closure.env));
                const call_env = try closure_env.createChild();

                for (closure.params, 0..) |param, i| {
                    try call_env.define(param.name, args[i], param.is_var);
                }

                // 执行闭包体
                const result = switch (closure.body) {
                    .block => |body| self.evalExpr(body, call_env),
                    .expression => |expr| self.evalExpr(expr, call_env),
                };

                return result catch |err| switch (err) {
                    error.ReturnValue => {
                        if (self.return_value) |val| {
                            self.return_value = null;
                            return val;
                        }
                        return Value.unit;
                    },
                    else => err,
                };
            },
            .builtin => |fn_ptr| {
                const result = fn_ptr(@ptrCast(self), args) catch |err| {
                    // anyerror 不能直接转换为 EvalResult，只传播已知的错误
                    switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.TypeMismatch => return error.TypeMismatch,
                        error.UndefinedVariable => return error.UndefinedVariable,
                        error.ImmutableAssignment => return error.ImmutableAssignment,
                        error.DivisionByZero => return error.DivisionByZero,
                        error.IntegerOverflow => return error.IntegerOverflow,
                        error.NotCallable => return error.NotCallable,
                        error.WrongArity => return error.WrongArity,
                        error.IndexOutOfBounds => return error.IndexOutOfBounds,
                        error.NullPointer => return error.NullPointer,
                        error.UnsupportedOperation => return error.UnsupportedOperation,
                        error.Unreachable => return error.Unreachable,
                        else => return error.UnsupportedOperation,
                    }
                };
                return result;
            },
            else => return error.NotCallable,
        }
    }

    fn evalMethodCall(self: *Evaluator, mc: @TypeOf(@as(ast.Expr, undefined).method_call), environment: *Environment) EvalResult!Value {
        const object = try self.evalExpr(mc.object, environment);

        // 求值参数
        var args = std.ArrayList(Value).empty;
        errdefer {
            for (args.items) |*a| a.deinit(self.allocator);
            args.deinit(self.allocator);
        }
        for (mc.arguments) |arg_expr| {
            try args.append(self.allocator, try self.evalExpr(arg_expr, environment));
        }
        defer args.deinit(self.allocator);

        return self.callMethod(object, mc.method, args.items, environment);
    }

    fn callMethod(self: *Evaluator, object: Value, method: []const u8, args: []const Value, environment: ?*Environment) EvalResult!Value {
        // 内建方法
        if (std.mem.eql(u8, method, "len")) {
            return switch (object) {
                .string => |s| Value{ .integer = @as(i128, @intCast(s.len)) },
                .array => |arr| Value{ .integer = @as(i128, @intCast(arr.items.len)) },
                else => error.TypeMismatch,
            };
        }

        if (std.mem.eql(u8, method, "char_count")) {
            return switch (object) {
                .string => |s| {
                    const view = std.unicode.Utf8View.init(s) catch {
                        return Value{ .integer = @as(i128, @intCast(s.len)) };
                    };
                    var count: i128 = 0;
                    var iter = view.iterator();
                    while (iter.nextCodepoint() != null) {
                        count += 1;
                    }
                    return Value{ .integer = count };
                },
                else => error.TypeMismatch,
            };
        }

        if (std.mem.eql(u8, method, "toString")) {
            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(self.allocator);
            try object.format(&buf, self.allocator);
            return Value{ .string = try buf.toOwnedSlice(self.allocator) };
        }

        // 记录方法 — 在记录中查找方法字段
        if (object == .record) {
            if (object.record.get(method)) |val| {
                return self.callFunction(val, args, environment);
            }
        }

        return error.UndefinedVariable;
    }

    fn evalFieldAccess(self: *Evaluator, fa: @TypeOf(@as(ast.Expr, undefined).field_access), environment: *Environment) EvalResult!Value {
        const object = try self.evalExpr(fa.object, environment);
        return self.accessField(object, fa.field);
    }

    fn accessField(self: *Evaluator, object: Value, field: []const u8) EvalResult!Value {
        _ = self;
        switch (object) {
            .record => |map| {
                if (map.get(field)) |val| {
                    return val;
                }
                return error.UndefinedVariable;
            },
            else => return error.TypeMismatch,
        }
    }

    fn evalSafeAccess(self: *Evaluator, sa: @TypeOf(@as(ast.Expr, undefined).safe_access), environment: *Environment) EvalResult!Value {
        const object = try self.evalExpr(sa.object, environment);
        if (object.isNull()) return Value.null_val;
        return self.accessField(object, sa.field);
    }

    fn evalSafeMethodCall(self: *Evaluator, smc: @TypeOf(@as(ast.Expr, undefined).safe_method_call), environment: *Environment) EvalResult!Value {
        const object = try self.evalExpr(smc.object, environment);
        if (object.isNull()) return Value.null_val;

        var args = std.ArrayList(Value).empty;
        errdefer {
            for (args.items) |*a| a.deinit(self.allocator);
            args.deinit(self.allocator);
        }
        for (smc.arguments) |arg_expr| {
            try args.append(self.allocator, try self.evalExpr(arg_expr, environment));
        }
        defer args.deinit(self.allocator);

        return self.callMethod(object, smc.method, args.items, environment);
    }

    fn evalNonNullAssert(self: *Evaluator, nna: @TypeOf(@as(ast.Expr, undefined).non_null_assert), environment: *Environment) EvalResult!Value {
        const val = try self.evalExpr(nna.expr, environment);
        if (val.isNull()) return error.NullPointer;
        return val;
    }

    fn evalPropagate(self: *Evaluator, prop: @TypeOf(@as(ast.Expr, undefined).propagate), environment: *Environment) EvalResult!Value {
        const val = try self.evalExpr(prop.expr, environment);
        if (val.isNull()) {
            return error.ThrowValue;
        }
        if (val == .error_val) {
            return error.ThrowValue;
        }
        return val;
    }

    fn evalIndex(self: *Evaluator, idx: @TypeOf(@as(ast.Expr, undefined).index), environment: *Environment) EvalResult!Value {
        const object = try self.evalExpr(idx.object, environment);
        const index_val = try self.evalExpr(idx.index, environment);

        switch (object) {
            .array => |arr| {
                const i = try index_val.asInteger();
                if (i < 0 or i >= @as(i128, @intCast(arr.items.len))) {
                    return error.IndexOutOfBounds;
                }
                return arr.items[@as(usize, @intCast(i))];
            },
            .string => |s| {
                const i = try index_val.asInteger();
                if (i < 0 or i >= @as(i128, @intCast(s.len))) {
                    return error.IndexOutOfBounds;
                }
                return Value{ .char_val = @as(u21, @intCast(s[@as(usize, @intCast(i))])) };
            },
            else => return error.TypeMismatch,
        }
    }

    fn evalArrayLiteral(self: *Evaluator, al: @TypeOf(@as(ast.Expr, undefined).array_literal), environment: *Environment) EvalResult!Value {
        var arr = std.ArrayList(Value).empty;
        errdefer {
            for (arr.items) |*a| a.deinit(self.allocator);
            arr.deinit(self.allocator);
        }
        for (al.elements) |elem| {
            try arr.append(self.allocator, try self.evalExpr(elem, environment));
        }
        return Value{ .array = arr };
    }

    fn evalRecordLiteral(self: *Evaluator, rl: @TypeOf(@as(ast.Expr, undefined).record_literal), environment: *Environment) EvalResult!Value {
        var map = std.StringHashMap(Value).init(self.allocator);
        errdefer map.deinit();

        for (rl.fields) |field| {
            const key = try self.allocator.dupe(u8, field.name);
            const val = try self.evalExpr(field.value, environment);
            try map.put(key, val);
        }

        return Value{ .record = map };
    }

    fn evalLambda(self: *Evaluator, lam: @TypeOf(@as(ast.Expr, undefined).lambda), environment: *Environment) EvalResult!Value {
        const closure = try self.allocator.create(value.Closure);
        closure.* = value.Closure{
            .params = lam.params,
            .body = lam.body,
            .env = @ptrCast(environment),
            .allocator = self.allocator,
        };
        try self.closures.append(self.allocator, closure);
        return Value{ .closure = closure };
    }

    fn evalIfExpr(self: *Evaluator, ie: @TypeOf(@as(ast.Expr, undefined).if_expr), environment: *Environment) EvalResult!Value {
        const condition = try self.evalExpr(ie.condition, environment);
        if (condition.isTruthy()) {
            return self.evalExpr(ie.then_branch, environment);
        } else if (ie.else_branch) |else_br| {
            return self.evalExpr(else_br, environment);
        }
        return Value.unit;
    }

    fn evalBlock(self: *Evaluator, blk: @TypeOf(@as(ast.Expr, undefined).block), environment: *Environment) EvalResult!Value {
        // Phase 1: 不 deinit block_env，因为闭包可能引用它
        const block_env = try environment.createChild();

        var defer_stack = std.ArrayList(*const ast.Expr).empty;
        defer defer_stack.deinit(self.allocator);

        var result: Value = Value.unit;

        // 执行语句
        for (blk.statements) |stmt| {
            const stmt_result = self.evalStmt(stmt, block_env, &defer_stack) catch |err| switch (err) {
                error.ReturnValue, error.ThrowValue, error.BreakSignal, error.ContinueSignal => {
                    // 执行 defer
                    self.runDefers(defer_stack.items, block_env) catch {};
                    return err;
                },
                else => return err,
            };
            if (stmt_result) |val| {
                result = val;
            }
        }

        // 尾表达式
        if (blk.trailing_expr) |expr| {
            result = try self.evalExpr(expr, block_env);
        }

        // 执行 defer
        try self.runDefers(defer_stack.items, block_env);

        return result;
    }

    fn runDefers(self: *Evaluator, defer_stack: []const *const ast.Expr, environment: *Environment) !void {
        // LIFO 顺序
        var i: usize = defer_stack.len;
        while (i > 0) {
            i -= 1;
            _ = self.evalExpr(defer_stack[i], environment) catch {};
        }
    }

    // ============================================================
    // match 表达式
    // ============================================================

    fn evalMatch(self: *Evaluator, m: @TypeOf(@as(ast.Expr, undefined).match), environment: *Environment) EvalResult!Value {
        const scrutinee = try self.evalExpr(m.scrutinee, environment);

        for (m.arms) |arm| {
            // Phase 1: 不 deinit match_env，因为闭包可能引用它
            const match_env = try environment.createChild();

            // 尝试使用 pattern.zig 的 matchPattern
            const matched = pattern.matchPattern(arm.pattern, scrutinee, match_env) catch |err| switch (err) {
                error.UnsupportedOperation => {
                    // 守卫模式需要 evalExpr，在此处理
                    if (arm.pattern.* == .guard) {
                        const guard_pattern = arm.pattern.guard;
                        if (try pattern.matchPattern(guard_pattern.pattern, scrutinee, match_env)) {
                            const guard_val = try self.evalExpr(guard_pattern.condition, match_env);
                            if (guard_val.isTruthy()) {
                                // 检查 arm 级别守卫
                                if (arm.guard) |guard| {
                                    const arm_guard_val = try self.evalExpr(guard, match_env);
                                    if (!arm_guard_val.isTruthy()) continue;
                                }
                                return self.evalExpr(arm.body, match_env);
                            }
                        }
                    }
                    continue;
                },
                else => return err,
            };

            if (matched) {
                // 检查守卫条件
                if (arm.guard) |guard| {
                    const guard_val = try self.evalExpr(guard, match_env);
                    if (!guard_val.isTruthy()) continue;
                }
                return self.evalExpr(arm.body, match_env);
            }
        }

        return error.Unreachable;
    }

    // ============================================================
    // 类型转换
    // ============================================================

    fn evalTypeCast(self: *Evaluator, tc: @TypeOf(@as(ast.Expr, undefined).type_cast), environment: *Environment) EvalResult!Value {
        const val = try self.evalExpr(tc.expr, environment);
        const type_name = switch (tc.target_type.*) {
            .named => |n| n.name,
            else => return error.TypeMismatch,
        };
        return self.castValue(val, type_name);
    }

    fn castValue(self: *Evaluator, val: Value, type_name: []const u8) EvalResult!Value {
        if (std.mem.eql(u8, type_name, "string")) {
            return self.valueToString(val);
        }
        if (val == .integer) {
            return self.castInteger(val.integer, type_name);
        }
        if (val == .float) {
            return self.castFloat(val.float, type_name);
        }
        if (val == .boolean) {
            if (std.mem.eql(u8, type_name, "string")) {
                return self.valueToString(val);
            }
            return error.TypeMismatch;
        }
        return error.TypeMismatch;
    }

    fn castInteger(self: *Evaluator, val: i128, type_name: []const u8) EvalResult!Value {
        _ = self;
        if (std.mem.eql(u8, type_name, "i8")) return Value{ .integer = clampInt(val, i8) };
        if (std.mem.eql(u8, type_name, "i16")) return Value{ .integer = clampInt(val, i16) };
        if (std.mem.eql(u8, type_name, "i32")) return Value{ .integer = clampInt(val, i32) };
        if (std.mem.eql(u8, type_name, "i64")) return Value{ .integer = clampInt(val, i64) };
        if (std.mem.eql(u8, type_name, "i128")) return Value{ .integer = val };
        if (std.mem.eql(u8, type_name, "u8")) return Value{ .integer = clampUInt(val, u8) };
        if (std.mem.eql(u8, type_name, "u16")) return Value{ .integer = clampUInt(val, u16) };
        if (std.mem.eql(u8, type_name, "u32")) return Value{ .integer = clampUInt(val, u32) };
        if (std.mem.eql(u8, type_name, "u64")) return Value{ .integer = clampUInt(val, u64) };
        if (std.mem.eql(u8, type_name, "u128")) return Value{ .integer = clampUInt(val, u128) };
        if (std.mem.eql(u8, type_name, "f32")) return Value{ .float = @as(f64, @floatFromInt(val)) };
        if (std.mem.eql(u8, type_name, "f64")) return Value{ .float = @as(f64, @floatFromInt(val)) };
        return error.TypeMismatch;
    }

    fn castFloat(self: *Evaluator, val: f64, type_name: []const u8) EvalResult!Value {
        _ = self;
        if (std.mem.eql(u8, type_name, "f32")) return Value{ .float = @as(f64, @floatCast(@as(f32, @floatCast(val)))) };
        if (std.mem.eql(u8, type_name, "f64")) return Value{ .float = val };
        if (std.mem.eql(u8, type_name, "i8")) return floatToInt(val, i8);
        if (std.mem.eql(u8, type_name, "i16")) return floatToInt(val, i16);
        if (std.mem.eql(u8, type_name, "i32")) return floatToInt(val, i32);
        if (std.mem.eql(u8, type_name, "i64")) return floatToInt(val, i64);
        if (std.mem.eql(u8, type_name, "i128")) return floatToInt(val, i128);
        return error.TypeMismatch;
    }

    fn valueToString(self: *Evaluator, val: Value) EvalResult!Value {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(self.allocator);
        try val.format(&buf, self.allocator);
        return Value{ .string = try buf.toOwnedSlice(self.allocator) };
    }

    // ============================================================
    // 语句执行
    // ============================================================

    pub fn evalStmt(self: *Evaluator, stmt: *const ast.Stmt, environment: *Environment, defer_stack: ?*std.ArrayList(*const ast.Expr)) EvalResult!?Value {
        return switch (stmt.*) {
            .val_decl => |vd| {
                const val = try self.evalExpr(vd.value, environment);
                try environment.define(vd.name, val, false);
                return null;
            },
            .var_decl => |vd| {
                const val = try self.evalExpr(vd.value, environment);
                try environment.define(vd.name, val, true);
                return null;
            },
            .assignment => |asgn| {
                const val = try self.evalExpr(asgn.value, environment);
                switch (asgn.target.*) {
                    .identifier => |id| {
                        try environment.set(id.name, val);
                    },
                    else => return error.TypeMismatch,
                }
                return null;
            },
            .field_assignment => |fa| {
                const val = try self.evalExpr(fa.value, environment);
                const object = try self.evalExpr(fa.object, environment);
                switch (object) {
                    .record => |*map| {
                        if (map.getPtr(fa.field)) |existing| {
                            existing.* = val;
                        } else {
                            return error.UndefinedVariable;
                        }
                    },
                    else => return error.TypeMismatch,
                }
                return null;
            },
            .expression => |expr_stmt| {
                const val = try self.evalExpr(expr_stmt.expr, environment);
                return val;
            },
            .return_stmt => |ret| {
                const val = if (ret.value) |v| try self.evalExpr(v, environment) else Value.unit;
                self.return_value = val;
                return error.ReturnValue;
            },
            .defer_stmt => |def| {
                // 注册到 defer 栈，而非立即执行
                if (defer_stack) |ds| {
                    try ds.append(self.allocator, def.expr);
                }
                return null;
            },
            .throw_stmt => |thr| {
                const val = try self.evalExpr(thr.expr, environment);
                self.throw_value = val;
                return error.ThrowValue;
            },
            .break_stmt => {
                return error.BreakSignal;
            },
            .continue_stmt => {
                return error.ContinueSignal;
            },
            .for_stmt => |fs| {
                return self.evalForStmt(fs, environment);
            },
            .while_stmt => |ws| {
                return self.evalWhileStmt(ws, environment);
            },
            .loop_stmt => |ls| {
                return self.evalLoopStmt(ls, environment);
            },
        };
    }

    fn evalForStmt(self: *Evaluator, fs: @TypeOf(@as(ast.Stmt, undefined).for_stmt), environment: *Environment) EvalResult!?Value {
        const iterable = try self.evalExpr(fs.iterable, environment);

        switch (iterable) {
            .array => |arr| {
                for (arr.items) |item| {
                    const loop_env = try environment.createChild();

                    try loop_env.define(fs.name, item, false);

                    _ = self.evalExpr(fs.body, loop_env) catch |err| switch (err) {
                        error.BreakSignal => break,
                        error.ContinueSignal => continue,
                        else => return err,
                    };
                }
            },
            .string => |s| {
                // UTF-8 码点迭代
                var iter = std.unicode.Utf8View.init(s) catch {
                    // 如果不是有效 UTF-8，回退到字节迭代
                    for (s) |byte| {
                        const loop_env = try environment.createChild();
                        try loop_env.define(fs.name, Value{ .char_val = @as(u21, @intCast(byte)) }, false);
                        _ = self.evalExpr(fs.body, loop_env) catch |err| switch (err) {
                            error.BreakSignal => break,
                            error.ContinueSignal => continue,
                            else => return err,
                        };
                    }
                    return null;
                };
                var utf8_iter = iter.iterator();
                while (utf8_iter.nextCodepoint()) |codepoint| {
                    const loop_env = try environment.createChild();

                    try loop_env.define(fs.name, Value{ .char_val = codepoint }, false);

                    _ = self.evalExpr(fs.body, loop_env) catch |err| switch (err) {
                        error.BreakSignal => break,
                        error.ContinueSignal => continue,
                        else => return err,
                    };
                }
            },
            .range => |r| {
                var i: i128 = r.start;
                const end_val: i128 = if (r.inclusive) r.end + 1 else r.end;
                while (i < end_val) : (i += 1) {
                    const loop_env = try environment.createChild();

                    try loop_env.define(fs.name, Value{ .integer = i }, false);

                    _ = self.evalExpr(fs.body, loop_env) catch |err| switch (err) {
                        error.BreakSignal => break,
                        error.ContinueSignal => continue,
                        else => return err,
                    };
                }
            },
            .integer => |range_end| {
                // 整数作为范围上限（0..range_end）
                if (range_end < 0) return null;
                var i: i128 = 0;
                while (i < range_end) : (i += 1) {
                    const loop_env = try environment.createChild();

                    try loop_env.define(fs.name, Value{ .integer = i }, false);

                    _ = self.evalExpr(fs.body, loop_env) catch |err| switch (err) {
                        error.BreakSignal => break,
                        error.ContinueSignal => continue,
                        else => return err,
                    };
                }
            },
            else => return error.TypeMismatch,
        }

        return null;
    }

    fn evalWhileStmt(self: *Evaluator, ws: @TypeOf(@as(ast.Stmt, undefined).while_stmt), environment: *Environment) EvalResult!?Value {
        while (true) {
            const condition = try self.evalExpr(ws.condition, environment);
            if (!condition.isTruthy()) break;

            _ = self.evalExpr(ws.body, environment) catch |err| switch (err) {
                error.BreakSignal => break,
                error.ContinueSignal => continue,
                else => return err,
            };
        }
        return null;
    }

    fn evalLoopStmt(self: *Evaluator, ls: @TypeOf(@as(ast.Stmt, undefined).loop_stmt), environment: *Environment) EvalResult!?Value {
        while (true) {
            _ = self.evalExpr(ls.body, environment) catch |err| switch (err) {
                error.BreakSignal => break,
                else => return err,
            };
        }
        return null;
    }
};

// ============================================================
// 文件级辅助函数
// ============================================================

/// 结构相等（递归比较值）
fn structuralEquals(a: Value, b: Value) bool {
    const a_tag = std.meta.activeTag(a);
    const b_tag = std.meta.activeTag(b);
    if (a_tag != b_tag) return false;
    return switch (a) {
        .integer => |i| i == b.integer,
        .float => |f| f == b.float,
        .boolean => |bo| bo == b.boolean,
        .char_val => |c| c == b.char_val,
        .string => |s| std.mem.eql(u8, s, b.string),
        .null_val => true,
        .unit => true,
        .range => |r| r.start == b.range.start and r.end == b.range.end and r.inclusive == b.range.inclusive,
        .array => |arr| {
            if (arr.items.len != b.array.items.len) return false;
            for (arr.items, b.array.items) |item_a, item_b| {
                if (!structuralEquals(item_a, item_b)) return false;
            }
            return true;
        },
        .record => |map| {
            // 比较所有键值对
            var iter = map.iterator();
            while (iter.next()) |entry| {
                if (b.record.get(entry.key_ptr.*)) |b_val| {
                    if (!structuralEquals(entry.value_ptr.*, b_val)) return false;
                } else {
                    return false;
                }
            }
            // 确保没有多余的键
            var b_iter = b.record.iterator();
            while (b_iter.next()) |entry| {
                if (map.get(entry.key_ptr.*)) |_| {} else {
                    return false;
                }
            }
            return true;
        },
        .closure => |c| c == b.closure,
        .builtin => |fn_ptr| fn_ptr == b.builtin,
        .error_val => |e| std.mem.eql(u8, e.message, b.error_val.message),
    };
}

fn parseInt(comptime T: type, raw: []const u8) !T {
    // 去除下划线
    var clean = std.ArrayList(u8).empty;
    defer clean.deinit(std.heap.page_allocator);

    var i: usize = 0;

    // 检查进制前缀
    var base: u8 = 10;
    if (raw.len > 2 and raw[0] == '0') {
        if (raw[1] == 'x' or raw[1] == 'X') {
            base = 16;
            i = 2;
        } else if (raw[1] == 'o' or raw[1] == 'O') {
            base = 8;
            i = 2;
        } else if (raw[1] == 'b' or raw[1] == 'B') {
            base = 2;
            i = 2;
        }
    }

    // 去除类型后缀
    var end = raw.len;
    while (end > i) {
        const ch = raw[end - 1];
        if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z')) {
            end -= 1;
        } else {
            break;
        }
    }

    // 去除下划线
    while (i < end) : (i += 1) {
        if (raw[i] != '_') {
            clean.append(std.heap.page_allocator, raw[i]) catch return error.IntegerOverflow;
        }
    }

    const str = clean.items;
    if (str.len == 0) return 0;

    return std.fmt.parseInt(T, str, base) catch error.IntegerOverflow;
}

fn parseFloat(comptime T: type, raw: []const u8) !T {
    // 去除类型后缀
    var end = raw.len;
    while (end > 0) {
        const ch = raw[end - 1];
        if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z')) {
            end -= 1;
        } else {
            break;
        }
    }

    return std.fmt.parseFloat(T, raw[0..end]) catch error.TypeMismatch;
}

fn isBuiltinType(name: []const u8) bool {
    const builtin_types = [_][]const u8{
        "i8",   "i16",  "i32",  "i64",  "i128",
        "u8",   "u16",  "u32",  "u64",  "u128",
        "f32",  "f64",
        "bool", "string",
    };
    for (builtin_types) |bt| {
        if (std.mem.eql(u8, name, bt)) return true;
    }
    return false;
}

fn clampInt(val: i128, comptime T: type) i128 {
    const min: i128 = std.math.minInt(T);
    const max: i128 = std.math.maxInt(T);
    if (val < min or val > max) {
        // 溢出 panic
        @panic("integer overflow in narrowing conversion");
    }
    return val;
}

fn clampUInt(val: i128, comptime T: type) i128 {
    if (val < 0) {
        @panic("integer overflow in narrowing conversion");
    }
    // 对于 u128，i128 的最大值就是上限（因为 i128 < u128::MAX）
    if (comptime std.math.maxInt(T) > std.math.maxInt(i128)) {
        // u128 类型：i128 正值都在范围内
        return val;
    }
    const max: i128 = @intCast(std.math.maxInt(T));
    if (val > max) {
        @panic("integer overflow in narrowing conversion");
    }
    return val;
}

fn floatToInt(val: f64, comptime T: type) EvalResult!Value {
    if (std.math.isNan(val) or std.math.isInf(val)) return error.IntegerOverflow;
    const min: f64 = @floatFromInt(std.math.minInt(T));
    const max: f64 = @floatFromInt(std.math.maxInt(T));
    if (val < min or val > max) return error.IntegerOverflow;
    return Value{ .integer = @as(i128, @intFromFloat(val)) };
}

// ============================================================
// 便捷求值函数
// ============================================================

/// 解析并求值表达式字符串
pub fn evalSource(allocator: std.mem.Allocator, source: []const u8) !Value {
    const lexer_mod = @import("lexer");
    const parser_mod = @import("parser");

    var lex = lexer_mod.Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();
    defer allocator.free(tokens);

    var p = parser_mod.Parser.init(allocator, tokens);
    defer p.deinit();

    const expr = try p.parseExpr();

    var evaluator = Evaluator.init(allocator);
    defer evaluator.deinit();

    return try evaluator.evalExpr(expr, &evaluator.global_env);
}

// ============================================================
// 测试
// ============================================================

test "求值器 - 整数字面量" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "42");
    try std.testing.expect(result == .integer);
    try std.testing.expectEqual(@as(i128, 42), result.integer);
}

test "求值器 - 浮点字面量" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "3.14");
    try std.testing.expect(result == .float);
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), result.float, 0.001);
}

test "求值器 - 布尔字面量" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const t = try evalSource(allocator, "true");
    try std.testing.expect(t == .boolean);
    try std.testing.expectEqual(true, t.boolean);

    const f = try evalSource(allocator, "false");
    try std.testing.expect(f == .boolean);
    try std.testing.expectEqual(false, f.boolean);
}

test "求值器 - null 和单位值" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const n = try evalSource(allocator, "null");
    try std.testing.expect(n == .null_val);

    const u = try evalSource(allocator, "()");
    try std.testing.expect(u == .unit);
}

test "求值器 - 基本算术" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const add = try evalSource(allocator, "1 + 2");
    try std.testing.expectEqual(@as(i128, 3), add.integer);

    const sub = try evalSource(allocator, "10 - 3");
    try std.testing.expectEqual(@as(i128, 7), sub.integer);

    const mul = try evalSource(allocator, "4 * 5");
    try std.testing.expectEqual(@as(i128, 20), mul.integer);

    const div = try evalSource(allocator, "10 / 3");
    try std.testing.expectEqual(@as(i128, 3), div.integer);

    const mod = try evalSource(allocator, "10 % 3");
    try std.testing.expectEqual(@as(i128, 1), mod.integer);
}

test "求值器 - 运算符优先级" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "1 + 2 * 3");
    try std.testing.expectEqual(@as(i128, 7), result.integer);
}

test "求值器 - 比较运算" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const lt = try evalSource(allocator, "1 < 2");
    try std.testing.expectEqual(true, lt.boolean);

    const gt = try evalSource(allocator, "3 > 2");
    try std.testing.expectEqual(true, gt.boolean);

    const eq = try evalSource(allocator, "1 == 1");
    try std.testing.expectEqual(true, eq.boolean);

    const neq = try evalSource(allocator, "1 != 2");
    try std.testing.expectEqual(true, neq.boolean);
}

test "求值器 - 逻辑运算（短路）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const and_true = try evalSource(allocator, "true && true");
    try std.testing.expectEqual(true, and_true.boolean);

    const and_false = try evalSource(allocator, "true && false");
    try std.testing.expectEqual(false, and_false.boolean);

    const or_true = try evalSource(allocator, "false || true");
    try std.testing.expectEqual(true, or_true.boolean);

    const or_false = try evalSource(allocator, "false || false");
    try std.testing.expectEqual(false, or_false.boolean);
}

test "求值器 - 一元运算" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const neg = try evalSource(allocator, "-42");
    try std.testing.expectEqual(@as(i128, -42), neg.integer);

    const not_val = try evalSource(allocator, "!true");
    try std.testing.expectEqual(false, not_val.boolean);
}

test "求值器 - val 声明和引用" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "{ val x = 42; x }");
    try std.testing.expectEqual(@as(i128, 42), result.integer);
}

test "求值器 - var 声明和赋值" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "{ var x = 1; x = 10; x }");
    try std.testing.expectEqual(@as(i128, 10), result.integer);
}

test "求值器 - if 表达式" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const then_val = try evalSource(allocator, "if true { 1 } else { 2 }");
    try std.testing.expectEqual(@as(i128, 1), then_val.integer);

    const else_val = try evalSource(allocator, "if false { 1 } else { 2 }");
    try std.testing.expectEqual(@as(i128, 2), else_val.integer);
}

test "求值器 - 块表达式" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "{ val x = 1; val y = 2; x + y }");
    try std.testing.expectEqual(@as(i128, 3), result.integer);
}

test "求值器 - Lambda 和闭包" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Lambda 表达式体
    const result = try evalSource(allocator, "{ val add = (a, b) => a + b; add(3, 4) }");
    try std.testing.expectEqual(@as(i128, 7), result.integer);
}

test "求值器 - fun Lambda" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "{ val double = fun(x) { x * 2 }; double(5) }");
    try std.testing.expectEqual(@as(i128, 10), result.integer);
}

test "求值器 - 闭包捕获" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "{ val x = 10; val f = (y) => x + y; f(5) }");
    try std.testing.expectEqual(@as(i128, 15), result.integer);
}

test "求值器 - match 表达式" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 字面量匹配
    const result = try evalSource(allocator, "match 1 { 0 => 100, 1 => 200, _ => 300 }");
    try std.testing.expectEqual(@as(i128, 200), result.integer);
}

test "求值器 - match 通配符" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "match 99 { 0 => 100, _ => 200 }");
    try std.testing.expectEqual(@as(i128, 200), result.integer);
}

test "求值器 - match 变量绑定" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "match 42 { x => x + 1 }");
    try std.testing.expectEqual(@as(i128, 43), result.integer);
}

test "求值器 - Elvis 运算符 ??" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const non_null = try evalSource(allocator, "42 ?? 0");
    try std.testing.expectEqual(@as(i128, 42), non_null.integer);

    const null_val = try evalSource(allocator, "null ?? 0");
    try std.testing.expectEqual(@as(i128, 0), null_val.integer);
}

test "求值器 - 非空断言 !" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const non_null = try evalSource(allocator, "42!");
    try std.testing.expectEqual(@as(i128, 42), non_null.integer);

    // null! 应该 panic
    // const null_assert = evalSource(allocator, "null!");
}

test "求值器 - 类型转换" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // i32 -> f64 (widening)
    const i2f = try evalSource(allocator, "f64(42)");
    try std.testing.expect(i2f == .float);
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), i2f.float, 0.001);

    // f64 -> i32 (narrowing)
    const f2i = try evalSource(allocator, "i32(3.14)");
    try std.testing.expectEqual(@as(i128, 3), f2i.integer);

    // string()
    const s = try evalSource(allocator, "string(42)");
    try std.testing.expect(s == .string);
    try std.testing.expectEqualStrings("42", s.string);
}

test "求值器 - 数组字面量" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "[1, 2, 3]");
    try std.testing.expect(result == .array);
    try std.testing.expectEqual(@as(usize, 3), result.array.items.len);
    try std.testing.expectEqual(@as(i128, 1), result.array.items[0].integer);
    try std.testing.expectEqual(@as(i128, 2), result.array.items[1].integer);
    try std.testing.expectEqual(@as(i128, 3), result.array.items[2].integer);
}

test "求值器 - 索引访问" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "{ val arr = [10, 20, 30]; arr[1] }");
    try std.testing.expectEqual(@as(i128, 20), result.integer);
}

test "求值器 - 记录字面量" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "(name: \"Alice\", age: 30)");
    try std.testing.expect(result == .record);
    const name = result.record.get("name").?;
    try std.testing.expectEqualStrings("Alice", name.string);
    const age = result.record.get("age").?;
    try std.testing.expectEqual(@as(i128, 30), age.integer);
}

test "求值器 - 字段访问" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "{ val p = (name: \"Bob\", age: 25); p.age }");
    try std.testing.expectEqual(@as(i128, 25), result.integer);
}

test "求值器 - 安全访问 ?." {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const null_access = try evalSource(allocator, "null?.field");
    try std.testing.expect(null_access == .null_val);

    const valid_access = try evalSource(allocator, "{ val p = (x: 1); p?.x }");
    try std.testing.expectEqual(@as(i128, 1), valid_access.integer);
}

test "求值器 - while 循环" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "{ var sum = 0; var i = 0; while i < 5 { sum = sum + i; i = i + 1 }; sum }");
    try std.testing.expectEqual(@as(i128, 10), result.integer);
}

test "求值器 - for 循环" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 使用 evalExpr 直接测试，避免解析器限制
    const lexer_mod = @import("lexer");
    const parser_mod = @import("parser");

    const source = "fun sum_arr(arr) { var s = 0; for x in arr { s = s + x }; s }";
    var lex = lexer_mod.Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();
    defer allocator.free(tokens);

    var p = parser_mod.Parser.init(allocator, tokens);
    defer p.deinit();

    const module = try p.parseModule("test");

    var evaluator = Evaluator.init(allocator);
    defer evaluator.deinit();

    try evaluator.evalModule(module);

    const fn_val = evaluator.global_env.get("sum_arr").?;
    var arr = std.ArrayList(Value).empty;
    try arr.append(allocator, Value{ .integer = 1 });
    try arr.append(allocator, Value{ .integer = 2 });
    try arr.append(allocator, Value{ .integer = 3 });
    try arr.append(allocator, Value{ .integer = 4 });
    try arr.append(allocator, Value{ .integer = 5 });
    const args = [_]Value{Value{ .array = arr }};
    const result = try evaluator.callFunction(fn_val.value, &args, null);
    try std.testing.expectEqual(@as(i128, 15), result.integer);
}

test "求值器 - loop 和 break" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const lexer_mod = @import("lexer");
    const parser_mod = @import("parser");

    const source = "fun loop_test() { var i = 0; loop { i = i + 1; if i >= 5 { break } }; i }";
    var lex = lexer_mod.Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();
    defer allocator.free(tokens);

    var p = parser_mod.Parser.init(allocator, tokens);
    defer p.deinit();

    const module = try p.parseModule("test");

    var evaluator = Evaluator.init(allocator);
    defer evaluator.deinit();

    try evaluator.evalModule(module);

    const fn_val = evaluator.global_env.get("loop_test").?;
    const args = [_]Value{};
    const result = try evaluator.callFunction(fn_val.value, &args, null);
    try std.testing.expectEqual(@as(i128, 5), result.integer);
}

test "求值器 - for 循环 continue" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const lexer_mod = @import("lexer");
    const parser_mod = @import("parser");

    const source = "fun skip_three(arr) { var s = 0; for x in arr { if x == 3 { continue } s = s + x }; s }";
    var lex = lexer_mod.Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();
    defer allocator.free(tokens);

    var p = parser_mod.Parser.init(allocator, tokens);
    defer p.deinit();

    const module = try p.parseModule("test");

    var evaluator = Evaluator.init(allocator);
    defer evaluator.deinit();

    try evaluator.evalModule(module);

    const fn_val = evaluator.global_env.get("skip_three").?;
    var arr = std.ArrayList(Value).empty;
    try arr.append(allocator, Value{ .integer = 1 });
    try arr.append(allocator, Value{ .integer = 2 });
    try arr.append(allocator, Value{ .integer = 3 });
    try arr.append(allocator, Value{ .integer = 4 });
    try arr.append(allocator, Value{ .integer = 5 });
    const args = [_]Value{Value{ .array = arr }};
    const result = try evaluator.callFunction(fn_val.value, &args, null);
    try std.testing.expectEqual(@as(i128, 12), result.integer);
}

test "求值器 - 顶层函数声明和调用" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const lexer_mod = @import("lexer");
    const parser_mod = @import("parser");

    const source = "fun add(a, b) { a + b }";
    var lex = lexer_mod.Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();
    defer allocator.free(tokens);

    var p = parser_mod.Parser.init(allocator, tokens);
    defer p.deinit();

    const module = try p.parseModule("test");

    var evaluator = Evaluator.init(allocator);
    defer evaluator.deinit();

    try evaluator.evalModule(module);

    // 调用 add 函数
    const add_fn = evaluator.global_env.get("add").?;
    const args = [_]Value{ Value{ .integer = 3 }, Value{ .integer = 4 } };
    const result = try evaluator.callFunction(add_fn.value, &args, null);
    try std.testing.expectEqual(@as(i128, 7), result.integer);
}

test "求值器 - 字符串拼接" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "\"hello\" + \" \" + \"world\"");
    try std.testing.expect(result == .string);
    try std.testing.expectEqualStrings("hello world", result.string);
}

test "求值器 - 传播操作符 ?" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 非 null 值传播
    const non_null = try evalSource(allocator, "42?");
    try std.testing.expectEqual(@as(i128, 42), non_null.integer);
}

test "求值器 - 嵌套闭包" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const lexer_mod = @import("lexer");
    const parser_mod = @import("parser");

    const source = "fun make_adder(x) { fun(y) { x + y } }";
    var lex = lexer_mod.Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();
    defer allocator.free(tokens);

    var p = parser_mod.Parser.init(allocator, tokens);
    defer p.deinit();

    const module = try p.parseModule("test");

    var evaluator = Evaluator.init(allocator);
    defer evaluator.deinit();

    try evaluator.evalModule(module);

    const make_adder = evaluator.global_env.get("make_adder").?;
    const make_args = [_]Value{Value{ .integer = 5 }};
    const add5 = try evaluator.callFunction(make_adder.value, &make_args, null);

    const add_args = [_]Value{Value{ .integer = 3 }};
    const result = try evaluator.callFunction(add5, &add_args, null);
    try std.testing.expectEqual(@as(i128, 8), result.integer);
}

test "求值器 - 递归函数" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const lexer_mod = @import("lexer");
    const parser_mod = @import("parser");

    const source = "fun fib(n) { if n <= 1 { n } else { fib(n - 1) + fib(n - 2) } }";
    var lex = lexer_mod.Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();
    defer allocator.free(tokens);

    var p = parser_mod.Parser.init(allocator, tokens);
    defer p.deinit();

    const module = try p.parseModule("test");

    var evaluator = Evaluator.init(allocator);
    defer evaluator.deinit();

    try evaluator.evalModule(module);

    const fib_fn = evaluator.global_env.get("fib").?;
    const args = [_]Value{Value{ .integer = 10 }};
    const result = try evaluator.callFunction(fib_fn.value, &args, null);
    try std.testing.expectEqual(@as(i128, 55), result.integer);
}

test "求值器 - match 记录模式" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "match (x: 1, y: 2) { (x: a, y: b) => a + b }");
    try std.testing.expectEqual(@as(i128, 3), result.integer);
}

test "求值器 - match 布尔模式" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "match true { true => 1, false => 0 }");
    try std.testing.expectEqual(@as(i128, 1), result.integer);
}

test "求值器 - match null 模式" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try evalSource(allocator, "match null { null => 0, _ => 1 }");
    try std.testing.expectEqual(@as(i128, 0), result.integer);
}
