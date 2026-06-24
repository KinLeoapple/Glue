//! Glue 字节码 VM — Chunk + Function（M0 骨架）
//!
//! 设计见 docs/bytecode-vm-plan.md §5.1。
//! Chunk = 一段可执行字节码 + 常量池 + ip→源位置调试信息。
//! Function = 编译后的函数对象（M0 暂只用顶层单 chunk，arity/upvalues 在 M1 接入）。

const std = @import("std");
const ast = @import("ast");
const value = @import("value");
const opcode = @import("opcode.zig");

const OpCode = opcode.OpCode;
const Value = value.Value;
const SourceLocation = ast.SourceLocation;

pub const Chunk = struct {
    /// 字节码流
    code: std.ArrayListUnmanaged(u8) = .empty,
    /// 常量池：字面量 / 函数对象 / 类型元信息。运行时持有母本，压栈前 retain。
    constants: std.ArrayListUnmanaged(Value) = .empty,
    /// 与 code 等长的指令起点 → 源位置映射（运行期错误报告行列）。
    /// lines[i] 对应 code[i] 字节处开始的指令。
    lines: std.ArrayListUnmanaged(SourceLocation) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Chunk {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Chunk) void {
        self.code.deinit(self.allocator);
        // 常量池持有母本：逐个 release（复合值 rc-1，string 释放 dupe）。
        for (self.constants.items) |c| c.release(self.allocator);
        self.constants.deinit(self.allocator);
        self.lines.deinit(self.allocator);
    }

    /// 写一字节 opcode，并登记其源位置。
    pub fn writeOp(self: *Chunk, op: OpCode, loc: SourceLocation) !void {
        try self.code.append(self.allocator, @intFromEnum(op));
        try self.lines.append(self.allocator, loc);
    }

    /// 写一个裸字节（立即数）。立即数不单独登记位置，复用其 opcode 的位置。
    pub fn writeByte(self: *Chunk, b: u8) !void {
        try self.code.append(self.allocator, b);
        try self.lines.append(self.allocator, .{ .line = 0, .column = 0 });
    }

    pub fn writeU16(self: *Chunk, v: u16) !void {
        try self.writeByte(@intCast(v & 0xFF));
        try self.writeByte(@intCast((v >> 8) & 0xFF));
    }

    pub fn writeI32(self: *Chunk, v: i32) !void {
        const u: u32 = @bitCast(v);
        try self.writeByte(@intCast(u & 0xFF));
        try self.writeByte(@intCast((u >> 8) & 0xFF));
        try self.writeByte(@intCast((u >> 16) & 0xFF));
        try self.writeByte(@intCast((u >> 24) & 0xFF));
    }

    /// 向常量池追加一个常量，返回其索引。常量池取得该值所有权。
    pub fn addConstant(self: *Chunk, v: Value) !u16 {
        const idx = self.constants.items.len;
        try self.constants.append(self.allocator, v);
        return @intCast(idx);
    }

    /// 当前字节码长度（用于跳转回填）。
    pub fn here(self: *const Chunk) usize {
        return self.code.items.len;
    }

    /// 发一个待回填的跳转：写 opcode + 占位 i32(0)，返回立即数所在偏移。
    pub fn emitJump(self: *Chunk, op: OpCode, loc: SourceLocation) !usize {
        try self.writeOp(op, loc);
        const operand_at = self.code.items.len;
        try self.writeI32(0);
        return operand_at;
    }

    /// 回填 emitJump 返回的偏移：跳转目标 = 立即数之后到 here 的相对距离。
    /// 相对基准 = 立即数结束处（operand_at + 4），与 VM 解码后 ip 一致（§见 vm.zig）。
    pub fn patchJump(self: *Chunk, operand_at: usize) void {
        const after = operand_at + 4;
        const target = self.code.items.len;
        const rel: i32 = @intCast(@as(i64, @intCast(target)) - @as(i64, @intCast(after)));
        const u: u32 = @bitCast(rel);
        self.code.items[operand_at] = @intCast(u & 0xFF);
        self.code.items[operand_at + 1] = @intCast((u >> 8) & 0xFF);
        self.code.items[operand_at + 2] = @intCast((u >> 16) & 0xFF);
        self.code.items[operand_at + 3] = @intCast((u >> 24) & 0xFF);
    }
};

/// 编译后的函数对象。M1a：承载函数体 chunk + arity + slot_count（帧需预留槽数）。
/// upvalues 在 M1c（闭包）接入。
pub const Function = struct {
    chunk: Chunk,
    arity: u8 = 0,
    slot_count: u16 = 0,
    name_id: u32 = 0xFFFF_FFFF,
    /// 诊断/反汇编用的函数名（借用 AST 的字节，不持有所有权）。
    name: []const u8 = "",

    pub fn deinit(self: *Function) void {
        self.chunk.deinit();
    }
};

/// ADT 构造器描述（M2a）：OP_MAKE_ADT <ctor_idx> 索引进 program.adt_ctors。
/// 所有字符串借用 AST 的字节（不持有所有权，与 Function.name 同），故 deinit 不释放。
pub const AdtCtorDesc = struct {
    type_name: []const u8,
    ctor_name: []const u8,
    /// 各字段名（位置字段为 null）；len == arity。建 AdtValue 时填 fields[i].name。
    field_names: []const ?[]const u8,
    /// M5c：各字段声明类型名（builtin 数值类型才非 null），用于 OP_MAKE_ADT 隐式定型
    /// （如 Emp(.., salary: i32) 把 i8 实参 100 协调成 i32，避免后续算术溢出）。len == arity。
    field_types: []const ?[]const u8,
    arity: u8,
};

/// 记录字面量形状（M2b）：OP_MAKE_RECORD <shape_idx> 索引进 program.record_shapes。
/// field_names 借用 AST 字节（不持有），外层切片由 Program alloc/free。栈顶 n 个值依次对应。
pub const RecordShape = struct {
    field_names: []const []const u8,
};

/// Newtype 构造器描述（M2c）：OP_MAKE_NEWTYPE <nt_idx> 索引进 program.newtype_ctors。
/// type_name 借用 AST 字节（不持有）。
pub const NewtypeCtorDesc = struct {
    type_name: []const u8,
};

/// 自定义错误类型构造器描述（M5e）：OP_MAKE_ERROR <err_idx> 索引进 program.error_ctors。
/// type FileError = Error("file error") → FileError("msg") 产 throw_val.err{
///   type_name="FileError", message="file error: msg", is_error_subtype=true}。
/// type_name / default_prefix 借用 AST 字节（不持有）。
pub const ErrorCtorDesc = struct {
    type_name: []const u8,
    default_prefix: []const u8,
};

/// impl 方法描述（M5i）：`impl Trait<Type> { fun m(self, ..) {..} }` 编出的方法函数。
/// OP_CALL_METHOD 据 receiver 的类型名 + 方法名查此表分派。type_name/method_name/trait_name 借用 AST。
/// func_idx 指向 program.functions 中编译好的方法体（self 占 slot 0）。
pub const ImplMethodDesc = struct {
    type_name: []const u8,
    method_name: []const u8,
    trait_name: []const u8,
    func_idx: u16,
};

/// trait 默认方法描述（M5i）：`trait T { fun m(self) {..默认..} }`，impl 未覆写时回退此体。
/// trait_name/method_name 借用 AST；func_idx 指向编译好的默认方法体。
pub const TraitDefaultDesc = struct {
    trait_name: []const u8,
    method_name: []const u8,
    func_idx: u16,
};

/// 组合 Trait 的冲突消解描述（M5n）：`trait Combined(P1, P2) { ... }`。文档 §2.7.2。
/// 当多个父 Trait 有同名方法时，组合 Trait 须用 override / 委托(=) 显式消解。VM 据此在
/// 扁平 impl 查找**之前**做组合分派：若接收者类型对所有 parents 都有 impl，则按本描述
/// 解析方法（override→调 override_func；delegate→查 (delegate_trait, method) 的父 impl）。
/// 多个组合 Trait 同时匹配时，按定义顺序后者覆盖前者（镜像 eval trait_definition_order 遍历）。
pub const TraitParentDesc = struct {
    /// 组合 Trait 名（借用 AST）。
    trait_name: []const u8,
    /// 父 Trait 名（借用 AST）。
    parent_name: []const u8,
};

/// 组合 Trait 内一个被消解的方法（M5n）。borrow AST 的名字。
pub const TraitResolveDesc = struct {
    trait_name: []const u8,
    method_name: []const u8,
    /// override：调用此 func_idx（override 方法体，self 占 slot 0）。否则 null。
    override_func: ?u16 = null,
    /// 委托：方法实现来自 (delegate_trait, delegate_method) 的父 impl（运行时按接收者类型查）。
    delegate_trait: ?[]const u8 = null,
    delegate_method: ?[]const u8 = null,
};

/// 整个编译单元：一组顶层函数 + 入口索引（main）。
/// OP_CALL <func_idx> 索引进 functions。Program 持有所有 Function 的所有权。
pub const Program = struct {
    functions: std.ArrayListUnmanaged(Function) = .empty,
    /// main 函数在 functions 中的索引（无 main 则为 null）。
    entry: ?u16 = null,
    /// ADT 构造器表（M2a）：OP_MAKE_ADT <ctor_idx> 索引进此。field_names 数组由 Program 持有
    /// （alloc/free），但其中的字符串借用 AST。
    adt_ctors: std.ArrayListUnmanaged(AdtCtorDesc) = .empty,
    /// 记录字面量形状表（M2b）：OP_MAKE_RECORD <shape_idx> 索引进此。
    record_shapes: std.ArrayListUnmanaged(RecordShape) = .empty,
    /// Newtype 构造器表（M2c）：OP_MAKE_NEWTYPE <nt_idx> 索引进此。
    newtype_ctors: std.ArrayListUnmanaged(NewtypeCtorDesc) = .empty,
    /// 自定义错误类型构造器表（M5e）：OP_MAKE_ERROR <err_idx> 索引进此。
    error_ctors: std.ArrayListUnmanaged(ErrorCtorDesc) = .empty,
    /// 顶层全局变量数（M5g）：VM 据此预留 globals 数组。OP_GET_GLOBAL/OP_SET_GLOBAL <u16 idx> 索引进此。
    global_count: u16 = 0,
    /// 全局初始化函数索引（M5g）：在 entry(main) 之前运行，求值顶层 val/var 的 RHS 写入 globals。
    /// null 表示无顶层 val/var（不需初始化）。
    globals_init: ?u16 = null,
    /// impl 方法表（M5i）：OP_CALL_METHOD 据 receiver 类型名 + 方法名查此分派到用户 impl。
    impl_methods: std.ArrayListUnmanaged(ImplMethodDesc) = .empty,
    /// trait 默认方法表（M5i）：impl 未覆写时回退。
    trait_defaults: std.ArrayListUnmanaged(TraitDefaultDesc) = .empty,
    /// 组合 Trait 的父 Trait 关系（M5n）：(组合 Trait, 父 Trait) 对，按定义顺序追加。
    trait_parents: std.ArrayListUnmanaged(TraitParentDesc) = .empty,
    /// 组合 Trait 内被 override/委托消解的方法（M5n）。
    trait_resolves: std.ArrayListUnmanaged(TraitResolveDesc) = .empty,
    /// 组合 Trait 名按定义顺序（M5n）：组合分派遍历此序，后者覆盖前者（镜像 eval trait_definition_order）。
    trait_order: std.ArrayListUnmanaged([]const u8) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Program {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Program) void {
        for (self.functions.items) |*f| f.deinit();
        self.functions.deinit(self.allocator);
        // field_names 切片由 addAdtCtor alloc，释放外层数组（内含字符串借用 AST，不释放）。
        for (self.adt_ctors.items) |d| {
            self.allocator.free(d.field_names);
            self.allocator.free(d.field_types);
        }
        self.adt_ctors.deinit(self.allocator);
        for (self.record_shapes.items) |s| self.allocator.free(s.field_names);
        self.record_shapes.deinit(self.allocator);
        self.newtype_ctors.deinit(self.allocator);
        self.error_ctors.deinit(self.allocator);
        // 释放 impl_methods 中复制的字符串
        for (self.impl_methods.items) |m| {
            self.allocator.free(m.type_name);
            self.allocator.free(m.method_name);
            self.allocator.free(m.trait_name);
        }
        self.impl_methods.deinit(self.allocator);
        self.trait_defaults.deinit(self.allocator);
        self.trait_parents.deinit(self.allocator);
        self.trait_resolves.deinit(self.allocator);
        self.trait_order.deinit(self.allocator);
    }

    /// 追加一个函数，返回其索引。
    pub fn addFunction(self: *Program, f: Function) !u16 {
        const idx = self.functions.items.len;
        try self.functions.append(self.allocator, f);
        return @intCast(idx);
    }

    /// 登记一个 ADT 构造器，返回其 ctor_idx。field_names 由本函数 dupe 进 Program 持有的数组
    /// （内含的字符串仍借用 AST）。
    pub fn addAdtCtor(self: *Program, type_name: []const u8, ctor_name: []const u8, field_names: []const ?[]const u8, field_types: []const ?[]const u8) !u16 {
        const idx = self.adt_ctors.items.len;
        const fn_copy = try self.allocator.dupe(?[]const u8, field_names);
        const ft_copy = try self.allocator.dupe(?[]const u8, field_types);
        try self.adt_ctors.append(self.allocator, .{
            .type_name = type_name,
            .ctor_name = ctor_name,
            .field_names = fn_copy,
            .field_types = ft_copy,
            .arity = @intCast(field_names.len),
        });
        return @intCast(idx);
    }

    /// 登记一个记录字面量形状，返回其 shape_idx。field_names dupe 进 Program 持有的数组
    /// （内含字符串借用 AST）。
    pub fn addRecordShape(self: *Program, field_names: []const []const u8) !u16 {
        const idx = self.record_shapes.items.len;
        const fn_copy = try self.allocator.dupe([]const u8, field_names);
        try self.record_shapes.append(self.allocator, .{ .field_names = fn_copy });
        return @intCast(idx);
    }

    /// 登记一个 newtype 构造器，返回其 nt_idx。type_name 借用 AST。
    pub fn addNewtypeCtor(self: *Program, type_name: []const u8) !u16 {
        const idx = self.newtype_ctors.items.len;
        try self.newtype_ctors.append(self.allocator, .{ .type_name = type_name });
        return @intCast(idx);
    }

    /// 登记一个自定义错误类型构造器，返回其 err_idx。type_name/default_prefix 借用 AST。
    pub fn addErrorCtor(self: *Program, type_name: []const u8, default_prefix: []const u8) !u16 {
        const idx = self.error_ctors.items.len;
        try self.error_ctors.append(self.allocator, .{ .type_name = type_name, .default_prefix = default_prefix });
        return @intCast(idx);
    }

    /// 登记一个 impl 方法（M5i）。type_name/method_name/trait_name 借用 AST。
    pub fn addImplMethod(self: *Program, type_name: []const u8, method_name: []const u8, trait_name: []const u8, func_idx: u16) !void {
        // 复制字符串以确保生命周期独立于源代码
        const type_name_copy = try self.allocator.dupe(u8, type_name);
        const method_name_copy = try self.allocator.dupe(u8, method_name);
        const trait_name_copy = try self.allocator.dupe(u8, trait_name);

        try self.impl_methods.append(self.allocator, .{
            .type_name = type_name_copy,
            .method_name = method_name_copy,
            .trait_name = trait_name_copy,
            .func_idx = func_idx,
        });
    }

    /// 登记一个 trait 默认方法（M5i）。trait_name/method_name 借用 AST。
    pub fn addTraitDefault(self: *Program, trait_name: []const u8, method_name: []const u8, func_idx: u16) !void {
        try self.trait_defaults.append(self.allocator, .{
            .trait_name = trait_name,
            .method_name = method_name,
            .func_idx = func_idx,
        });
    }

    /// 登记一个组合 Trait 的父 Trait 关系（M5n）。借用 AST。
    pub fn addTraitParent(self: *Program, trait_name: []const u8, parent_name: []const u8) !void {
        try self.trait_parents.append(self.allocator, .{ .trait_name = trait_name, .parent_name = parent_name });
    }

    /// 登记一个组合 Trait 内被消解的方法（M5n）。借用 AST。
    pub fn addTraitResolve(self: *Program, desc: TraitResolveDesc) !void {
        try self.trait_resolves.append(self.allocator, desc);
    }

    /// 把一个组合 Trait 名追加到定义顺序（M5n，去重——跨模块同名 trait 只记首个）。
    pub fn addTraitOrder(self: *Program, trait_name: []const u8) !void {
        for (self.trait_order.items) |t| if (std.mem.eql(u8, t, trait_name)) return;
        try self.trait_order.append(self.allocator, trait_name);
    }
};
