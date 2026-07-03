//! Value/Chunk/Function/Program 序列化与反序列化。
//!
//! 仅支持常量池中出现的 Value 种类（Int/Float/Bool/Char/Str/Unit/Null）。
//! 复合值（ADT/record/closure）不在常量池，运行时构造。
//!
//! 字符串所有权：Str 反序列化时由 allocator 分配新 *Str，独立于 AST 生命周期。

const std = @import("std");
const value = @import("value");
const vm = @import("vm");
const chunk_mod = vm.chunk;
const reloc_mod = @import("reloc.zig");

/// Value tag（序列化用，与 Value union 的 tag 对齐但只含常量池种类）
const ValueTag = enum(u8) {
    int,
    float,
    bool_true,
    bool_false,
    char,
    str,
    unit,
    null_val,
};

// ============================================================
// Value 序列化
// ============================================================

/// 序列化单个 Value 到 buffer
pub fn serializeValue(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, v: value.Value) !void {
    switch (v) {
        .int => |iv| {
            try buf.appendSlice(allocator, std.mem.asBytes(&ValueTag.int));
            const type_tag: u8 = @intFromEnum(iv.type);
            try buf.appendSlice(allocator, std.mem.asBytes(&type_tag));
            try buf.appendSlice(allocator, std.mem.asBytes(&iv.lo));
            try buf.appendSlice(allocator, std.mem.asBytes(&iv.hi));
        },
        .float => |fv| {
            try buf.appendSlice(allocator, std.mem.asBytes(&ValueTag.float));
            const type_tag: u8 = @intFromEnum(fv.type);
            try buf.appendSlice(allocator, std.mem.asBytes(&type_tag));
            try buf.appendSlice(allocator, std.mem.asBytes(&fv.bits));
            try buf.appendSlice(allocator, std.mem.asBytes(&fv.extra));
        },
        .boolean => |bv| {
            const tag: ValueTag = if (bv) .bool_true else .bool_false;
            try buf.appendSlice(allocator, std.mem.asBytes(&tag));
        },
        .char => |cv| {
            try buf.appendSlice(allocator, std.mem.asBytes(&ValueTag.char));
            try buf.appendSlice(allocator, std.mem.asBytes(&cv.codepoint));
        },
        .string => |sv| {
            try buf.appendSlice(allocator, std.mem.asBytes(&ValueTag.str));
            const bytes = sv.bytes();
            const len: u32 = @intCast(bytes.len);
            try buf.appendSlice(allocator, std.mem.asBytes(&len));
            try buf.appendSlice(allocator, bytes);
        },
        .unit => try buf.appendSlice(allocator, std.mem.asBytes(&ValueTag.unit)),
        .null_val => try buf.appendSlice(allocator, std.mem.asBytes(&ValueTag.null_val)),
        else => return error.UnsupportedValueKind,
    }
}

/// 从光标反序列化单个 Value
pub fn deserializeValue(allocator: std.mem.Allocator, cur: *reloc_mod.ByteCursor) !value.Value {
    var tag: ValueTag = undefined;
    try cur.read(std.mem.asBytes(&tag));
    switch (tag) {
        .int => {
            var type_tag: u8 = undefined;
            try cur.read(std.mem.asBytes(&type_tag));
            var lo: u64 = undefined;
            var hi: u64 = undefined;
            try cur.read(std.mem.asBytes(&lo));
            try cur.read(std.mem.asBytes(&hi));
            return value.Value.fromInt(.{
                .type = @enumFromInt(type_tag),
                .lo = lo,
                .hi = hi,
            });
        },
        .float => {
            var type_tag: u8 = undefined;
            try cur.read(std.mem.asBytes(&type_tag));
            var bits: u64 = undefined;
            var extra: u64 = undefined;
            try cur.read(std.mem.asBytes(&bits));
            try cur.read(std.mem.asBytes(&extra));
            return value.Value.fromFloat(.{
                .type = @enumFromInt(type_tag),
                .bits = bits,
                .extra = extra,
            });
        },
        .bool_true => return value.Value.fromBool(true),
        .bool_false => return value.Value.fromBool(false),
        .char => {
            var codepoint: u32 = undefined;
            try cur.read(std.mem.asBytes(&codepoint));
            const c = try value.Char.fromCodePoint(@intCast(codepoint));
            return value.Value.fromChar(c);
        },
        .str => {
            var len: u32 = undefined;
            try cur.read(std.mem.asBytes(&len));
            const str_bytes = try allocator.alloc(u8, len);
            try cur.read(str_bytes);
            const v = try value.Value.fromStringBytes(allocator, str_bytes);
            allocator.free(str_bytes);
            return v;
        },
        .unit => return value.Value.fromUnit(),
        .null_val => return value.Value.fromNull(),
    }
}

// ============================================================
// Chunk 序列化（code + constants + lines）
// ============================================================

/// 序列化 Chunk
pub fn serializeChunk(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, chunk: *const chunk_mod.Chunk) !void {
    // code: u32 len + bytes
    const code_len: u32 = @intCast(chunk.code.items.len);
    try buf.appendSlice(allocator, std.mem.asBytes(&code_len));
    try buf.appendSlice(allocator, chunk.code.items);

    // constants: u32 count + each Value
    const const_count: u32 = @intCast(chunk.constants.items.len);
    try buf.appendSlice(allocator, std.mem.asBytes(&const_count));
    for (chunk.constants.items) |c| {
        try serializeValue(buf, allocator, c);
    }

    // lines: u32 count + u32 bytes (PackedLoc)
    const lines_count: u32 = @intCast(chunk.lines.items.len);
    try buf.appendSlice(allocator, std.mem.asBytes(&lines_count));
    if (lines_count > 0) {
        try buf.appendSlice(allocator, std.mem.sliceAsBytes(chunk.lines.items));
    }
}

/// 反序列化 Chunk
pub fn deserializeChunk(allocator: std.mem.Allocator, cur: *reloc_mod.ByteCursor) !chunk_mod.Chunk {
    var chunk = chunk_mod.Chunk.init(allocator);

    // code
    var code_len: u32 = undefined;
    try cur.read(std.mem.asBytes(&code_len));
    try chunk.code.ensureTotalCapacity(allocator, code_len);
    var i: u32 = 0;
    while (i < code_len) : (i += 1) {
        var b: u8 = undefined;
        try cur.read(std.mem.asBytes(&b));
        try chunk.code.append(allocator, b);
    }

    // constants
    var const_count: u32 = undefined;
    try cur.read(std.mem.asBytes(&const_count));
    try chunk.constants.ensureTotalCapacity(allocator, const_count);
    i = 0;
    while (i < const_count) : (i += 1) {
        const v = try deserializeValue(allocator, cur);
        try chunk.constants.append(allocator, v);
    }

    // lines
    var lines_count: u32 = undefined;
    try cur.read(std.mem.asBytes(&lines_count));
    try chunk.lines.ensureTotalCapacity(allocator, lines_count);
    i = 0;
    while (i < lines_count) : (i += 1) {
        var loc: u32 = undefined;
        try cur.read(std.mem.asBytes(&loc));
        try chunk.lines.append(allocator, loc);
    }

    return chunk;
}

// ============================================================
// 字符串序列化辅助
// ============================================================

/// 写一个 owned 字符串（u32 len + bytes）
fn writeOwnedStr(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    const len: u32 = @intCast(s.len);
    try buf.appendSlice(allocator, std.mem.asBytes(&len));
    try buf.appendSlice(allocator, s);
}

/// 读一个 owned 字符串（alloc 新内存）
fn readOwnedStr(allocator: std.mem.Allocator, cur: *reloc_mod.ByteCursor) ![]const u8 {
    var len: u32 = undefined;
    try cur.read(std.mem.asBytes(&len));
    const result = try allocator.alloc(u8, len);
    try cur.read(result);
    return result;
}

/// 写字符串切片（u32 count + 每个 u32 len + bytes）
fn writeStrSlice(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, slice: []const []const u8) !void {
    const count: u32 = @intCast(slice.len);
    try buf.appendSlice(allocator, std.mem.asBytes(&count));
    for (slice) |s| try writeOwnedStr(buf, allocator, s);
}

/// 读字符串切片（alloc owned 外层 + 内层）
fn readStrSlice(allocator: std.mem.Allocator, cur: *reloc_mod.ByteCursor) ![][]const u8 {
    var count: u32 = undefined;
    try cur.read(std.mem.asBytes(&count));
    const result = try allocator.alloc([]const u8, count);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        result[i] = try readOwnedStr(allocator, cur);
    }
    return result;
}

/// 写可选字符串切片（?[]const u8 切片：u32 count + 每个 u8 has + ?str）
fn writeOptStrSlice(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, slice: []const ?[]const u8) !void {
    const count: u32 = @intCast(slice.len);
    try buf.appendSlice(allocator, std.mem.asBytes(&count));
    for (slice) |opt| {
        const has: u8 = if (opt) |_| 1 else 0;
        try buf.appendSlice(allocator, std.mem.asBytes(&has));
        if (opt) |s| try writeOwnedStr(buf, allocator, s);
    }
}

/// 读可选字符串切片
fn readOptStrSlice(allocator: std.mem.Allocator, cur: *reloc_mod.ByteCursor) ![]?[]const u8 {
    var count: u32 = undefined;
    try cur.read(std.mem.asBytes(&count));
    const result = try allocator.alloc(?[]const u8, count);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        var has: u8 = undefined;
        try cur.read(std.mem.asBytes(&has));
        result[i] = if (has == 1) try readOwnedStr(allocator, cur) else null;
    }
    return result;
}

// ============================================================
// Function 序列化
// ============================================================

/// 序列化 Function（chunk + arity + slot_count + release_mask + name_id + name）
pub fn serializeFunction(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, func: *const chunk_mod.Function) !void {
    try serializeChunk(buf, allocator, &func.chunk);
    try buf.appendSlice(allocator, std.mem.asBytes(&func.arity));
    try buf.appendSlice(allocator, std.mem.asBytes(&func.slot_count));
    try buf.appendSlice(allocator, std.mem.asBytes(&func.release_mask));
    try buf.appendSlice(allocator, std.mem.asBytes(&func.name_id));
    try writeOwnedStr(buf, allocator, func.name);
}

/// 反序列化 Function（name 为 owned，需调用方释放）
pub fn deserializeFunction(allocator: std.mem.Allocator, cur: *reloc_mod.ByteCursor) !chunk_mod.Function {
    const chunk = try deserializeChunk(allocator, cur);
    var arity: u8 = undefined;
    var slot_count: u16 = undefined;
    var release_mask: u64 = undefined;
    var name_id: u32 = undefined;
    try cur.read(std.mem.asBytes(&arity));
    try cur.read(std.mem.asBytes(&slot_count));
    try cur.read(std.mem.asBytes(&release_mask));
    try cur.read(std.mem.asBytes(&name_id));
    const name = try readOwnedStr(allocator, cur);
    return .{
        .chunk = chunk,
        .arity = arity,
        .slot_count = slot_count,
        .release_mask = release_mask,
        .name_id = name_id,
        .name = name,
    };
}

// ============================================================
// Desc 表序列化
// ============================================================

/// AdtCtorDesc 序列化（type_name + ctor_name + field_names + field_types + arity）
pub fn serializeAdtCtor(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, ctor: *const chunk_mod.AdtCtorDesc) !void {
    try writeOwnedStr(buf, allocator, ctor.type_name);
    try writeOwnedStr(buf, allocator, ctor.ctor_name);
    try writeOptStrSlice(buf, allocator, ctor.field_names);
    try writeOptStrSlice(buf, allocator, ctor.field_types);
    try buf.appendSlice(allocator, std.mem.asBytes(&ctor.arity));
}

pub fn deserializeAdtCtor(allocator: std.mem.Allocator, cur: *reloc_mod.ByteCursor) !chunk_mod.AdtCtorDesc {
    const type_name = try readOwnedStr(allocator, cur);
    const ctor_name = try readOwnedStr(allocator, cur);
    const field_names = try readOptStrSlice(allocator, cur);
    const field_types = try readOptStrSlice(allocator, cur);
    var arity: u8 = undefined;
    try cur.read(std.mem.asBytes(&arity));
    return .{
        .type_name = type_name,
        .ctor_name = ctor_name,
        .field_names = field_names,
        .field_types = field_types,
        .arity = arity,
    };
}

/// RecordShape 序列化
pub fn serializeRecordShape(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, shape: *const chunk_mod.RecordShape) !void {
    try writeStrSlice(buf, allocator, shape.field_names);
}

pub fn deserializeRecordShape(allocator: std.mem.Allocator, cur: *reloc_mod.ByteCursor) !chunk_mod.RecordShape {
    const field_names = try readStrSlice(allocator, cur);
    return .{ .field_names = field_names };
}

/// NewtypeCtorDesc 序列化
pub fn serializeNewtypeCtor(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, nt: *const chunk_mod.NewtypeCtorDesc) !void {
    try writeOwnedStr(buf, allocator, nt.type_name);
}

pub fn deserializeNewtypeCtor(allocator: std.mem.Allocator, cur: *reloc_mod.ByteCursor) !chunk_mod.NewtypeCtorDesc {
    const type_name = try readOwnedStr(allocator, cur);
    return .{ .type_name = type_name };
}

/// ErrorCtorDesc 序列化
pub fn serializeErrorCtor(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, ec: *const chunk_mod.ErrorCtorDesc) !void {
    try writeOwnedStr(buf, allocator, ec.type_name);
    try writeOwnedStr(buf, allocator, ec.default_prefix);
}

pub fn deserializeErrorCtor(allocator: std.mem.Allocator, cur: *reloc_mod.ByteCursor) !chunk_mod.ErrorCtorDesc {
    const type_name = try readOwnedStr(allocator, cur);
    const default_prefix = try readOwnedStr(allocator, cur);
    return .{ .type_name = type_name, .default_prefix = default_prefix };
}

/// TraitMethodDesc 序列化
pub fn serializeTraitMethod(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, m: *const chunk_mod.TraitMethodDesc) !void {
    try writeOwnedStr(buf, allocator, m.type_name);
    try writeOwnedStr(buf, allocator, m.method_name);
    try writeOwnedStr(buf, allocator, m.trait_name);
    try buf.appendSlice(allocator, std.mem.asBytes(&m.func_idx));
}

pub fn deserializeTraitMethod(allocator: std.mem.Allocator, cur: *reloc_mod.ByteCursor) !chunk_mod.TraitMethodDesc {
    const type_name = try readOwnedStr(allocator, cur);
    const method_name = try readOwnedStr(allocator, cur);
    const trait_name = try readOwnedStr(allocator, cur);
    var func_idx: u16 = undefined;
    try cur.read(std.mem.asBytes(&func_idx));
    return .{
        .type_name = type_name,
        .method_name = method_name,
        .trait_name = trait_name,
        .func_idx = func_idx,
    };
}

/// TraitDefaultDesc 序列化
pub fn serializeTraitDefault(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, d: *const chunk_mod.TraitDefaultDesc) !void {
    try writeOwnedStr(buf, allocator, d.trait_name);
    try writeOwnedStr(buf, allocator, d.method_name);
    try buf.appendSlice(allocator, std.mem.asBytes(&d.func_idx));
}

pub fn deserializeTraitDefault(allocator: std.mem.Allocator, cur: *reloc_mod.ByteCursor) !chunk_mod.TraitDefaultDesc {
    const trait_name = try readOwnedStr(allocator, cur);
    const method_name = try readOwnedStr(allocator, cur);
    var func_idx: u16 = undefined;
    try cur.read(std.mem.asBytes(&func_idx));
    return .{
        .trait_name = trait_name,
        .method_name = method_name,
        .func_idx = func_idx,
    };
}

/// TraitParentDesc 序列化
pub fn serializeTraitParent(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, p: *const chunk_mod.TraitParentDesc) !void {
    try writeOwnedStr(buf, allocator, p.trait_name);
    try writeOwnedStr(buf, allocator, p.parent_name);
}

pub fn deserializeTraitParent(allocator: std.mem.Allocator, cur: *reloc_mod.ByteCursor) !chunk_mod.TraitParentDesc {
    const trait_name = try readOwnedStr(allocator, cur);
    const parent_name = try readOwnedStr(allocator, cur);
    return .{ .trait_name = trait_name, .parent_name = parent_name };
}

/// TraitResolveDesc 序列化（含可选字段 override_func / delegate_trait / delegate_method）
pub fn serializeTraitResolve(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, r: *const chunk_mod.TraitResolveDesc) !void {
    try writeOwnedStr(buf, allocator, r.trait_name);
    try writeOwnedStr(buf, allocator, r.method_name);
    // override_func: u8 has + ?u16
    const has_override: u8 = if (r.override_func) |_| 1 else 0;
    try buf.appendSlice(allocator, std.mem.asBytes(&has_override));
    if (r.override_func) |of| try buf.appendSlice(allocator, std.mem.asBytes(&of));
    // delegate_trait: u8 has + ?str
    const has_dt: u8 = if (r.delegate_trait) |_| 1 else 0;
    try buf.appendSlice(allocator, std.mem.asBytes(&has_dt));
    if (r.delegate_trait) |dt| try writeOwnedStr(buf, allocator, dt);
    // delegate_method: u8 has + ?str
    const has_dm: u8 = if (r.delegate_method) |_| 1 else 0;
    try buf.appendSlice(allocator, std.mem.asBytes(&has_dm));
    if (r.delegate_method) |dm| try writeOwnedStr(buf, allocator, dm);
}

pub fn deserializeTraitResolve(allocator: std.mem.Allocator, cur: *reloc_mod.ByteCursor) !chunk_mod.TraitResolveDesc {
    const trait_name = try readOwnedStr(allocator, cur);
    const method_name = try readOwnedStr(allocator, cur);
    var has_override: u8 = undefined;
    try cur.read(std.mem.asBytes(&has_override));
    var override_func: ?u16 = null;
    if (has_override == 1) {
        var of: u16 = undefined;
        try cur.read(std.mem.asBytes(&of));
        override_func = of;
    }
    var has_dt: u8 = undefined;
    try cur.read(std.mem.asBytes(&has_dt));
    var delegate_trait: ?[]const u8 = null;
    if (has_dt == 1) delegate_trait = try readOwnedStr(allocator, cur);
    var has_dm: u8 = undefined;
    try cur.read(std.mem.asBytes(&has_dm));
    var delegate_method: ?[]const u8 = null;
    if (has_dm == 1) delegate_method = try readOwnedStr(allocator, cur);
    return .{
        .trait_name = trait_name,
        .method_name = method_name,
        .override_func = override_func,
        .delegate_trait = delegate_trait,
        .delegate_method = delegate_method,
    };
}

/// 释放反序列化的 Desc 表中 owned 字符串（BccFile.deinit 调用）
pub fn freeAdtCtor(allocator: std.mem.Allocator, ctor: *const chunk_mod.AdtCtorDesc) void {
    allocator.free(ctor.type_name);
    allocator.free(ctor.ctor_name);
    for (ctor.field_names) |opt| if (opt) |s| allocator.free(s);
    allocator.free(ctor.field_names);
    for (ctor.field_types) |opt| if (opt) |s| allocator.free(s);
    allocator.free(ctor.field_types);
}

pub fn freeRecordShape(allocator: std.mem.Allocator, shape: *const chunk_mod.RecordShape) void {
    for (shape.field_names) |s| allocator.free(s);
    allocator.free(shape.field_names);
}

pub fn freeNewtypeCtor(allocator: std.mem.Allocator, nt: *const chunk_mod.NewtypeCtorDesc) void {
    allocator.free(nt.type_name);
}

pub fn freeErrorCtor(allocator: std.mem.Allocator, ec: *const chunk_mod.ErrorCtorDesc) void {
    allocator.free(ec.type_name);
    allocator.free(ec.default_prefix);
}

pub fn freeTraitMethod(allocator: std.mem.Allocator, m: *const chunk_mod.TraitMethodDesc) void {
    allocator.free(m.type_name);
    allocator.free(m.method_name);
    allocator.free(m.trait_name);
}

pub fn freeTraitDefault(allocator: std.mem.Allocator, d: *const chunk_mod.TraitDefaultDesc) void {
    allocator.free(d.trait_name);
    allocator.free(d.method_name);
}

pub fn freeTraitParent(allocator: std.mem.Allocator, p: *const chunk_mod.TraitParentDesc) void {
    allocator.free(p.trait_name);
    allocator.free(p.parent_name);
}

pub fn freeTraitResolve(allocator: std.mem.Allocator, r: *const chunk_mod.TraitResolveDesc) void {
    allocator.free(r.trait_name);
    allocator.free(r.method_name);
    if (r.delegate_trait) |dt| allocator.free(dt);
    if (r.delegate_method) |dm| allocator.free(dm);
}

// ============================================================
// 测试
// ============================================================

test "Value Int 序列化往返" {
    const v = value.Value.fromInt(value.Int.fromNative(.i64, 42));
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(std.testing.allocator);
    try serializeValue(&buf, std.testing.allocator, v);

    var cur = reloc_mod.ByteCursor{ .data = buf.items };
    const v2 = try deserializeValue(std.testing.allocator, &cur);
    defer v2.release(std.testing.allocator);
    try std.testing.expect(value.equals(v, v2));
}

test "Value Str 序列化往返" {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(std.testing.allocator);
    const v = try value.Value.fromStringBytes(std.testing.allocator, "hello");
    defer v.release(std.testing.allocator);
    try serializeValue(&buf, std.testing.allocator, v);

    var cur = reloc_mod.ByteCursor{ .data = buf.items };
    const v2 = try deserializeValue(std.testing.allocator, &cur);
    defer v2.release(std.testing.allocator);
    try std.testing.expect(value.equals(v, v2));
}

test "Value Float 序列化往返" {
    const v = value.Value.fromFloat(value.Float.fromNative(.f64, @as(f64, 3.14)));
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(std.testing.allocator);
    try serializeValue(&buf, std.testing.allocator, v);

    var cur = reloc_mod.ByteCursor{ .data = buf.items };
    const v2 = try deserializeValue(std.testing.allocator, &cur);
    defer v2.release(std.testing.allocator);
    try std.testing.expect(value.equals(v, v2));
}

test "Value Bool/Char/Unit/Null 序列化往返" {
    const cases = [_]value.Value{
        value.Value.fromBool(true),
        value.Value.fromBool(false),
        value.Value.fromChar(try value.Char.fromCodePoint('A')),
        value.Value.fromChar(try value.Char.fromCodePoint('中')),
        value.Value.fromUnit(),
        value.Value.fromNull(),
    };
    for (cases) |v| {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(std.testing.allocator);
        try serializeValue(&buf, std.testing.allocator, v);
        var cur = reloc_mod.ByteCursor{ .data = buf.items };
        const v2 = try deserializeValue(std.testing.allocator, &cur);
        defer v2.release(std.testing.allocator);
        try std.testing.expect(value.equals(v, v2));
    }
}

test "Value 长字符串序列化往返（>20 字节触发堆模式）" {
    const long_str = "This is a long string that exceeds SSO_MAX of 20 bytes";
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(std.testing.allocator);
    const v = try value.Value.fromStringBytes(std.testing.allocator, long_str);
    defer v.release(std.testing.allocator);
    try serializeValue(&buf, std.testing.allocator, v);

    var cur = reloc_mod.ByteCursor{ .data = buf.items };
    const v2 = try deserializeValue(std.testing.allocator, &cur);
    defer v2.release(std.testing.allocator);
    try std.testing.expect(value.equals(v, v2));
}

test "Chunk 序列化往返" {
    var chunk = chunk_mod.Chunk.init(std.testing.allocator);
    defer chunk.deinit();

    const cidx = try chunk.addConstant(value.Value.fromInt(value.Int.fromNative(.i64, 42)));
    try chunk.writeOp(.op_const, .{ .line = 1, .column = 1 });
    try chunk.writeU16(cidx);
    try chunk.writeOp(.op_return, .{ .line = 1, .column = 2 });

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(std.testing.allocator);
    try serializeChunk(&buf, std.testing.allocator, &chunk);

    var cur = reloc_mod.ByteCursor{ .data = buf.items };
    var chunk2 = try deserializeChunk(std.testing.allocator, &cur);
    defer chunk2.deinit();

    try std.testing.expectEqual(chunk.code.items.len, chunk2.code.items.len);
    try std.testing.expectEqualSlices(u8, chunk.code.items, chunk2.code.items);
    try std.testing.expectEqual(chunk.constants.items.len, chunk2.constants.items.len);
    try std.testing.expectEqual(chunk.lines.items.len, chunk2.lines.items.len);
}

test "Function 序列化往返" {
    var func = chunk_mod.Function{
        .chunk = chunk_mod.Chunk.init(std.testing.allocator),
        .arity = 2,
        .slot_count = 5,
        .release_mask = 0b11,
        .name_id = 42,
        .name = "test_fn",
    };
    defer func.deinit();
    try func.chunk.writeOp(.op_return, .{ .line = 1, .column = 1 });
    const cidx = try func.chunk.addConstant(value.Value.fromInt(value.Int.fromNative(.i32, 7)));
    try func.chunk.writeOp(.op_const, .{ .line = 1, .column = 2 });
    try func.chunk.writeU16(cidx);

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(std.testing.allocator);
    try serializeFunction(&buf, std.testing.allocator, &func);

    var cur = reloc_mod.ByteCursor{ .data = buf.items };
    var func2 = try deserializeFunction(std.testing.allocator, &cur);
    defer {
        func2.deinit();
        std.testing.allocator.free(func2.name);
    }
    try std.testing.expectEqual(@as(u8, 2), func2.arity);
    try std.testing.expectEqual(@as(u16, 5), func2.slot_count);
    try std.testing.expectEqual(@as(u64, 0b11), func2.release_mask);
    try std.testing.expectEqual(@as(u32, 42), func2.name_id);
    try std.testing.expectEqualStrings("test_fn", func2.name);
    try std.testing.expectEqual(func.chunk.code.items.len, func2.chunk.code.items.len);
}

test "AdtCtorDesc 序列化往返" {
    const field_names = [_]?[]const u8{ "x", null, "z" };
    const field_types = [_]?[]const u8{ "i32", null, "String" };
    const ctor = chunk_mod.AdtCtorDesc{
        .type_name = "Foo",
        .ctor_name = "Bar",
        .field_names = &field_names,
        .field_types = &field_types,
        .arity = 3,
    };

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(std.testing.allocator);
    try serializeAdtCtor(&buf, std.testing.allocator, &ctor);

    var cur = reloc_mod.ByteCursor{ .data = buf.items };
    const ctor2 = try deserializeAdtCtor(std.testing.allocator, &cur);
    defer freeAdtCtor(std.testing.allocator, &ctor2);

    try std.testing.expectEqualStrings("Foo", ctor2.type_name);
    try std.testing.expectEqualStrings("Bar", ctor2.ctor_name);
    try std.testing.expectEqual(@as(u8, 3), ctor2.arity);
    try std.testing.expectEqual(@as(usize, 3), ctor2.field_names.len);
    try std.testing.expectEqualStrings("x", ctor2.field_names[0].?);
    try std.testing.expect(ctor2.field_names[1] == null);
    try std.testing.expectEqualStrings("z", ctor2.field_names[2].?);
    try std.testing.expectEqualStrings("i32", ctor2.field_types[0].?);
}

test "RecordShape 序列化往返" {
    const field_names = [_][]const u8{ "a", "b", "c" };
    const shape = chunk_mod.RecordShape{ .field_names = &field_names };

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(std.testing.allocator);
    try serializeRecordShape(&buf, std.testing.allocator, &shape);

    var cur = reloc_mod.ByteCursor{ .data = buf.items };
    const shape2 = try deserializeRecordShape(std.testing.allocator, &cur);
    defer freeRecordShape(std.testing.allocator, &shape2);
    try std.testing.expectEqual(@as(usize, 3), shape2.field_names.len);
    try std.testing.expectEqualStrings("a", shape2.field_names[0]);
    try std.testing.expectEqualStrings("b", shape2.field_names[1]);
    try std.testing.expectEqualStrings("c", shape2.field_names[2]);
}

test "TraitResolveDesc 序列化往返（含可选字段）" {
    // override_func 存在、delegate_trait 存在、delegate_method null
    const r1 = chunk_mod.TraitResolveDesc{
        .trait_name = "Combo",
        .method_name = "m1",
        .override_func = 5,
        .delegate_trait = "Parent",
        .delegate_method = null,
    };
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(std.testing.allocator);
    try serializeTraitResolve(&buf, std.testing.allocator, &r1);

    var cur = reloc_mod.ByteCursor{ .data = buf.items };
    const r2 = try deserializeTraitResolve(std.testing.allocator, &cur);
    defer freeTraitResolve(std.testing.allocator, &r2);
    try std.testing.expectEqualStrings("Combo", r2.trait_name);
    try std.testing.expectEqualStrings("m1", r2.method_name);
    try std.testing.expectEqual(@as(?u16, 5), r2.override_func);
    try std.testing.expectEqualStrings("Parent", r2.delegate_trait.?);
    try std.testing.expect(r2.delegate_method == null);
}

test "TraitResolveDesc 全 null 字段" {
    const r1 = chunk_mod.TraitResolveDesc{
        .trait_name = "T",
        .method_name = "m",
        .override_func = null,
        .delegate_trait = null,
        .delegate_method = null,
    };
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(std.testing.allocator);
    try serializeTraitResolve(&buf, std.testing.allocator, &r1);

    var cur = reloc_mod.ByteCursor{ .data = buf.items };
    const r2 = try deserializeTraitResolve(std.testing.allocator, &cur);
    defer freeTraitResolve(std.testing.allocator, &r2);
    try std.testing.expect(r2.override_func == null);
    try std.testing.expect(r2.delegate_trait == null);
    try std.testing.expect(r2.delegate_method == null);
}

test "ErrorCtorDesc 序列化往返" {
    const ec = chunk_mod.ErrorCtorDesc{
        .type_name = "FileError",
        .default_prefix = "file error",
    };
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(std.testing.allocator);
    try serializeErrorCtor(&buf, std.testing.allocator, &ec);

    var cur = reloc_mod.ByteCursor{ .data = buf.items };
    const ec2 = try deserializeErrorCtor(std.testing.allocator, &cur);
    defer freeErrorCtor(std.testing.allocator, &ec2);
    try std.testing.expectEqualStrings("FileError", ec2.type_name);
    try std.testing.expectEqualStrings("file error", ec2.default_prefix);
}

test "TraitMethodDesc 序列化往返" {
    const m = chunk_mod.TraitMethodDesc{
        .type_name = "Foo",
        .method_name = "bar",
        .trait_name = "Display",
        .func_idx = 7,
    };
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(std.testing.allocator);
    try serializeTraitMethod(&buf, std.testing.allocator, &m);

    var cur = reloc_mod.ByteCursor{ .data = buf.items };
    const m2 = try deserializeTraitMethod(std.testing.allocator, &cur);
    defer freeTraitMethod(std.testing.allocator, &m2);
    try std.testing.expectEqualStrings("Foo", m2.type_name);
    try std.testing.expectEqualStrings("bar", m2.method_name);
    try std.testing.expectEqualStrings("Display", m2.trait_name);
    try std.testing.expectEqual(@as(u16, 7), m2.func_idx);
}
