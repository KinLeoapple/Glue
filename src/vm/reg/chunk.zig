//! 寄存器 VM 的字节码块与程序结构。
//!
//! 定义 RegChunk（指令序列 + 常量池 + 行号表）、RegFunction（单个函数）
//! 以及 RegProgram（完整程序，含函数表、构造器表、trait 表等）。
//! 同时提供常量去重、指令写入与跳转回填等基础操作。

const std = @import("std");
const value = @import("value");
const ast = @import("ast");
const reg_opcode = @import("opcode.zig");

pub const reg_opcode_mod = reg_opcode;
const Instruction = reg_opcode.Instruction;

/// 字节码块，承载单个函数的指令、常量与行号信息。
pub const RegChunk = struct {
    code: std.ArrayListUnmanaged(Instruction) = .empty,
    constants: std.ArrayListUnmanaged(value.Value) = .empty,
    lines: std.ArrayListUnmanaged(u32) = .empty,
    const_dedup: std.HashMapUnmanaged(value.Value, u16, ConstDedupContext, std.hash_map.default_max_load_percentage) = .{},
    allocator: std.mem.Allocator,

    /// 创建一个空的字节码块。
    pub fn init(allocator: std.mem.Allocator) RegChunk {
        return .{ .allocator = allocator };
    }

    /// 释放指令、常量、行号与去重表等全部资源。
    pub fn deinit(self: *RegChunk) void {
        self.code.deinit(self.allocator);
        for (self.constants.items) |c| c.release(self.allocator);
        self.constants.deinit(self.allocator);
        self.lines.deinit(self.allocator);
        self.const_dedup.deinit(self.allocator);
    }

    /// 写入一条 iABC 格式指令并记录行号。
    pub fn writeABC(self: *RegChunk, op: reg_opcode.Op, a: u8, b: u8, c: u8, loc: ast.SourceLocation) !void {
        try self.code.append(self.allocator, reg_opcode.makeABC(op, a, b, c));
        try self.lines.append(self.allocator, packLoc(loc));
    }

    /// 写入一条 iABx 格式指令并记录行号。
    pub fn writeABx(self: *RegChunk, op: reg_opcode.Op, a: u8, bx: u16, loc: ast.SourceLocation) !void {
        try self.code.append(self.allocator, reg_opcode.makeABx(op, a, bx));
        try self.lines.append(self.allocator, packLoc(loc));
    }

    /// 写入一条 iAsBx 格式指令并记录行号。
    pub fn writesBx(self: *RegChunk, op: reg_opcode.Op, a: u8, offset: i32, loc: ast.SourceLocation) !void {
        try self.code.append(self.allocator, reg_opcode.makesBx(op, a, offset));
        try self.lines.append(self.allocator, packLoc(loc));
    }

    /// 发射一条跳转指令，返回其在代码中的索引，便于后续回填。
    pub fn emitJump(self: *RegChunk, op: reg_opcode.Op, a: u8, loc: ast.SourceLocation) !usize {
        const idx = self.code.items.len;
        try self.writesBx(op, a, 0, loc);
        return idx;
    }

    /// 回填指定跳转指令的目标地址。
    pub fn patchJump(self: *RegChunk, jump_idx: usize, target_idx: usize) void {
        reg_opcode.patchJump(self.code.items, jump_idx, target_idx);
    }

    /// 返回当前指令数量（即下一条指令将要写入的位置）。
    pub fn here(self: *const RegChunk) usize {
        return self.code.items.len;
    }

    /// 添加常量并返回其索引，对可去重类型进行去重以节省空间。
    pub fn addConstant(self: *RegChunk, v: value.Value) !u16 {
        if (ConstDedupContext.isDedupable(v)) {
            if (self.const_dedup.get(v)) |existing_idx| {
                v.release(self.allocator);
                return existing_idx;
            }
            const idx: u16 = @intCast(self.constants.items.len);
            try self.constants.append(self.allocator, v);
            try self.const_dedup.put(self.allocator, v, idx);
            return idx;
        }
        const idx: u16 = @intCast(self.constants.items.len);
        try self.constants.append(self.allocator, v);
        return idx;
    }

    /// 返回指定指令索引对应的源码位置。
    pub fn locAt(self: *const RegChunk, inst_idx: usize) ast.SourceLocation {
        if (inst_idx >= self.lines.items.len) return .{ .line = 0, .column = 0 };
        return unpackLoc(self.lines.items[inst_idx]);
    }

    // 行号打包：高 20 位行号 + 低 12 位列号
    fn packLoc(loc: ast.SourceLocation) u32 {
        const line: u32 = @intCast(loc.line & 0xFFFFF);
        const col: u32 = @intCast(loc.column & 0xFFF);
        return (line << 12) | col;
    }

    fn unpackLoc(packed_val: u32) ast.SourceLocation {
        return .{
            .line = @intCast(packed_val >> 12),
            .column = @intCast(packed_val & 0xFFF),
        };
    }
};

/// 常量去重上下文，为基本标量类型提供哈希与相等判定。
const ConstDedupContext = struct {
    pub fn hash(_: ConstDedupContext, v: value.Value) u64 {
        return switch (v) {
            .null_val => 0x9E37_79B9_7E37_79B9,
            .unit => 0xD6E8_FEB8_6659_EF73,
            .boolean => |b| if (b) 0x3C1F_8C29_A7B4_D5E6 else 0x6F4A_2D71_B8E0_9C35,
            .char => |c| @as(u64, 0x55A5_55A5) +% @as(u64, c.codepoint),
            .int => |i| hashInt(i.type, i.lo, i.hi),
            .float => |f| hashInt(f.type, f.bits, f.extra),
            .string => |s| std.hash.Wyhash.hash(0, s.bytes()),
            else => unreachable,
        };
    }

    pub fn eql(_: ConstDedupContext, a: value.Value, b: value.Value) bool {
        return value.equals(a, b);
    }

    /// 判断该值是否可以参与去重（仅基本标量类型）。
    pub fn isDedupable(v: value.Value) bool {
        return switch (v) {
            .null_val, .unit, .boolean, .char, .int, .float, .string => true,
            else => false,
        };
    }

    fn hashInt(t: anytype, lo: u64, hi: u64) u64 {
        var h: u64 = @intFromEnum(t);
        h = h *% 0x1000_0000_1B3 +% lo;
        h = h *% 0x1000_0000_1B3 +% hi;
        return h;
    }
};

/// 单个函数的完整定义，包含字节码、参数与寄存器信息。
pub const RegFunction = struct {
    chunk: RegChunk,
    arity: u8 = 0,
    register_count: u16 = 0,
    release_mask: u64 = 0,
    name: []const u8 = "",
    ic_slot_count: u16 = 0,
    upvalue_specs: std.ArrayListUnmanaged(UpvalueSpec) = .empty,
    param_types: []const ?[]const u8 = &.{},
    is_async: bool = false,
    memo_slot: u16 = 0xFFFF,

    /// 释放函数占用的字节码与 upvalue 规格等资源。
    pub fn deinit(self: *RegFunction, allocator: std.mem.Allocator) void {
        self.chunk.deinit();
        self.upvalue_specs.deinit(allocator);
        if (self.param_types.len > 0) allocator.free(self.param_types);
    }
};

/// upvalue 规格：指明捕获的是外层局部变量还是外层 upvalue。
pub const UpvalueSpec = struct {
    is_local: bool,
    index: u8,
};

/// 完整程序，聚合所有函数、类型描述符与 trait 信息。
pub const RegProgram = struct {
    functions: std.ArrayListUnmanaged(RegFunction) = .empty,
    entry: ?u16 = null,
    adt_ctors: std.ArrayListUnmanaged(AdtCtorDesc) = .empty,
    record_shapes: std.ArrayListUnmanaged(RecordShape) = .empty,
    newtype_ctors: std.ArrayListUnmanaged(NewtypeCtorDesc) = .empty,
    error_ctors: std.ArrayListUnmanaged(ErrorCtorDesc) = .empty,
    global_count: u16 = 0,
    globals_init: ?u16 = null,
    trait_methods: std.ArrayListUnmanaged(TraitMethodDesc) = .empty,
    trait_defaults: std.ArrayListUnmanaged(TraitDefaultDesc) = .empty,
    allocator: std.mem.Allocator,

    /// 创建一个空的程序。
    pub fn init(allocator: std.mem.Allocator) RegProgram {
        return .{ .allocator = allocator };
    }

    /// 释放函数表、构造器表、trait 表等全部资源。
    pub fn deinit(self: *RegProgram) void {
        for (self.functions.items) |*f| f.deinit(self.allocator);
        self.functions.deinit(self.allocator);
        self.adt_ctors.deinit(self.allocator);
        self.record_shapes.deinit(self.allocator);
        self.newtype_ctors.deinit(self.allocator);
        self.error_ctors.deinit(self.allocator);
        for (self.trait_methods.items) |m| {
            self.allocator.free(m.type_name);
            self.allocator.free(m.method_name);
            self.allocator.free(m.trait_name);
        }
        self.trait_methods.deinit(self.allocator);
        for (self.trait_defaults.items) |m| {
            self.allocator.free(m.trait_name);
            self.allocator.free(m.method_name);
        }
        self.trait_defaults.deinit(self.allocator);
    }

    /// 注册一个 trait 方法，复制所有名称字符串。
    pub fn addTraitMethod(self: *RegProgram, type_name: []const u8, method_name: []const u8, trait_name: []const u8, func_idx: u16) !void {
        try self.trait_methods.append(self.allocator, .{
            .type_name = try self.allocator.dupe(u8, type_name),
            .method_name = try self.allocator.dupe(u8, method_name),
            .trait_name = try self.allocator.dupe(u8, trait_name),
            .func_idx = func_idx,
        });
    }

    /// 注册一个 trait 默认方法，复制 trait 名与方法名。
    pub fn addTraitDefault(self: *RegProgram, trait_name: []const u8, method_name: []const u8, func_idx: u16) !void {
        try self.trait_defaults.append(self.allocator, .{
            .trait_name = try self.allocator.dupe(u8, trait_name),
            .method_name = try self.allocator.dupe(u8, method_name),
            .func_idx = func_idx,
        });
    }
};

const shared = @import("shared");

pub const AdtCtorDesc = shared.descriptors_mod.AdtCtorDesc;
pub const RecordShape = shared.descriptors_mod.RecordShape;
pub const NewtypeCtorDesc = shared.descriptors_mod.NewtypeCtorDesc;
pub const ErrorCtorDesc = shared.descriptors_mod.ErrorCtorDesc;
pub const TraitMethodDesc = shared.descriptors_mod.TraitMethodDesc;
pub const TraitDefaultDesc = shared.descriptors_mod.TraitDefaultDesc;
