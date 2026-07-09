//! 寄存器式字节码容器。与栈式 chunk.zig 对应，但 code 为 Instruction(u32) 数组。

const std = @import("std");
const value = @import("value");
const ast = @import("ast");
const reg_opcode = @import("reg_opcode.zig");
const Instruction = reg_opcode.Instruction;

pub const RegChunk = struct {
    code: std.ArrayListUnmanaged(Instruction) = .empty,
    constants: std.ArrayListUnmanaged(value.Value) = .empty,
    lines: std.ArrayListUnmanaged(u32) = .empty, // PackedLoc，与 code 等长（每条指令一个 loc）
    const_dedup: std.HashMapUnmanaged(value.Value, u16, ConstDedupContext, std.hash_map.default_max_load_percentage) = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RegChunk {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *RegChunk) void {
        self.code.deinit(self.allocator);
        for (self.constants.items) |c| c.release(self.allocator);
        self.constants.deinit(self.allocator);
        self.lines.deinit(self.allocator);
        self.const_dedup.deinit(self.allocator);
    }

    /// 写入一条 iABC 指令
    pub fn writeABC(self: *RegChunk, op: reg_opcode.Op, a: u8, b: u8, c: u8, loc: ast.SourceLocation) !void {
        try self.code.append(self.allocator, reg_opcode.makeABC(op, a, b, c));
        try self.lines.append(self.allocator, packLoc(loc));
    }

    /// 写入一条 iABx 指令
    pub fn writeABx(self: *RegChunk, op: reg_opcode.Op, a: u8, bx: u16, loc: ast.SourceLocation) !void {
        try self.code.append(self.allocator, reg_opcode.makeABx(op, a, bx));
        try self.lines.append(self.allocator, packLoc(loc));
    }

    /// 写入一条 iAsBx 指令（有符号偏移）
    pub fn writesBx(self: *RegChunk, op: reg_opcode.Op, a: u8, offset: i32, loc: ast.SourceLocation) !void {
        try self.code.append(self.allocator, reg_opcode.makesBx(op, a, offset));
        try self.lines.append(self.allocator, packLoc(loc));
    }

    /// 写入占位跳转指令，返回指令索引（用于后续 patchJump）
    pub fn emitJump(self: *RegChunk, op: reg_opcode.Op, a: u8, loc: ast.SourceLocation) !usize {
        const idx = self.code.items.len;
        try self.writesBx(op, a, 0, loc); // 占位偏移=0
        return idx;
    }

    /// 回填跳转偏移
    pub fn patchJump(self: *RegChunk, jump_idx: usize, target_idx: usize) void {
        reg_opcode.patchJump(self.code.items, jump_idx, target_idx);
    }

    /// 当前指令索引
    pub fn here(self: *const RegChunk) usize {
        return self.code.items.len;
    }

    /// 添加常量（带去重），返回常量索引。常量池取得该值所有权。
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

    pub fn locAt(self: *const RegChunk, inst_idx: usize) ast.SourceLocation {
        if (inst_idx >= self.lines.items.len) return .{ .line = 0, .column = 0 };
        return unpackLoc(self.lines.items[inst_idx]);
    }

    fn packLoc(loc: ast.SourceLocation) u32 {
        const line: u32 = @intCast(loc.line & 0xFFFFF); // 20 bits
        const col: u32 = @intCast(loc.column & 0xFFF); // 12 bits
        return (line << 12) | col;
    }

    fn unpackLoc(packed_val: u32) ast.SourceLocation {
        return .{
            .line = @intCast(packed_val >> 12),
            .column = @intCast(packed_val & 0xFFF),
        };
    }
};

/// 常量池去重 context（镜像栈式 chunk.zig 的 ConstDedupContext，仅对内联标量 + string 去重）
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
            else => unreachable, // isDedupable 保证不会走到这里
        };
    }

    pub fn eql(_: ConstDedupContext, a: value.Value, b: value.Value) bool {
        return value.equals(a, b);
    }

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

pub const RegFunction = struct {
    chunk: RegChunk,
    arity: u8 = 0,
    /// 本函数所需寄存器总数（含参数 + 局部 + 临时）
    register_count: u16 = 0,
    /// release_mask：bit i=1 表示寄存器 i 持 boxed 值需 release
    release_mask: u64 = 0,
    name: []const u8 = "",
    ic_slot_count: u16 = 0,
    /// upvalue 描述符列表（闭包用）
    upvalue_specs: std.ArrayListUnmanaged(UpvalueSpec) = .empty,

    pub fn deinit(self: *RegFunction, allocator: std.mem.Allocator) void {
        self.chunk.deinit();
        self.upvalue_specs.deinit(allocator);
    }
};

pub const UpvalueSpec = struct {
    is_local: bool, // true = 捕获外层局部，false = 捕获外层 upvalue
    index: u8, // 寄存器号或 upvalue 索引
};

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

    pub fn init(allocator: std.mem.Allocator) RegProgram {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *RegProgram) void {
        for (self.functions.items) |*f| f.deinit(self.allocator);
        self.functions.deinit(self.allocator);
        self.adt_ctors.deinit(self.allocator);
        self.record_shapes.deinit(self.allocator);
        self.newtype_ctors.deinit(self.allocator);
        self.error_ctors.deinit(self.allocator);
        self.trait_methods.deinit(self.allocator);
        self.trait_defaults.deinit(self.allocator);
    }
};

// 描述结构体复用栈式 chunk.zig 的定义（通过 re-export）
pub const AdtCtorDesc = @import("../chunk.zig").AdtCtorDesc;
pub const RecordShape = @import("../chunk.zig").RecordShape;
pub const NewtypeCtorDesc = @import("../chunk.zig").NewtypeCtorDesc;
pub const ErrorCtorDesc = @import("../chunk.zig").ErrorCtorDesc;
pub const TraitMethodDesc = @import("../chunk.zig").TraitMethodDesc;
pub const TraitDefaultDesc = @import("../chunk.zig").TraitDefaultDesc;
