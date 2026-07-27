//! TypeDescriptor + ScalarOps vtable（运行时数据部分）
//!
//! v3 spec §4.1: 替代 TypeKind 枚举 + ConcreteType 的统一类型描述符。
//! 所有类型（标量/引用/复合/容器）统一表示，递归 slots 支持任意嵌套。
//! scalar_ops vtable 消除标量读写 switch，增加类型只需追加 scalar_ops_table 条目。
//!
//! 类型定义（TypeDescriptor/ScalarOps/Slot/SlotKind）已移至 src/ir/type_descriptor.zig，
//! 以便 ir 模块（如 sema_output.zig）直接引用，避免 ir → sema 循环依赖。
//! 本文件保留 ScalarKind 枚举、标量 vtable 实现、scalar_ops_table、
//! builtin_type_descriptors 与 lookupBuiltinByChan，并通过 ir 重导出上述类型。

const std = @import("std");
const value = @import("value");
const ir_mod = @import("ir");
const ChanType = ir_mod.ChanType;

// 类型定义已移至 ir/type_descriptor.zig，此处重导出以保持下游引用兼容
pub const TypeDescriptor = ir_mod.type_descriptor_mod.TypeDescriptor;
pub const ScalarOps = ir_mod.type_descriptor_mod.ScalarOps;
pub const Slot = ir_mod.type_descriptor_mod.Slot;
pub const SlotKind = ir_mod.type_descriptor_mod.SlotKind;

/// 标量种类（对应 scalar_ops_table 的 key）
pub const ScalarKind = enum {
    i8, u8, i16, u16, i32, u32, i64, u64, i128, u128, isize, usize,
    f16, f32, f64, f128, bool, char,
};

// ════════════════════════════════════════════════════════════
// 标量 vtable 实现：read/write/equal/format/hash
// ════════════════════════════════════════════════════════════

// ── i8 ──
fn readI8(ptr: *anyopaque) value.Value {
    const p: *i8 = @ptrCast(@alignCast(ptr));
    return value.Value{ .i8 = @bitCast(p.*) };
}
fn writeI8(ptr: *anyopaque, v: value.Value) void {
    const p: *i8 = @ptrCast(@alignCast(ptr));
    p.* = @bitCast(v.i8);
}
fn eqI8(a: *anyopaque, b: *anyopaque) bool {
    const pa: *i8 = @ptrCast(@alignCast(a));
    const pb: *i8 = @ptrCast(@alignCast(b));
    return pa.* == pb.*;
}
fn fmtI8(ptr: *anyopaque, buf: []u8) []const u8 {
    const p: *i8 = @ptrCast(@alignCast(ptr));
    return std.fmt.bufPrint(buf, "{d}", .{p.*}) catch buf[0..0];
}
fn hashI8(ptr: *anyopaque) u64 {
    const p: *i8 = @ptrCast(@alignCast(ptr));
    const bits: u8 = @bitCast(p.*);
    return @as(u64, bits);
}

// ── u8 ──
fn readU8(ptr: *anyopaque) value.Value {
    const p: *u8 = @ptrCast(@alignCast(ptr));
    return value.Value{ .u8 = .{p.*} };
}
fn writeU8(ptr: *anyopaque, v: value.Value) void {
    const p: *u8 = @ptrCast(@alignCast(ptr));
    p.* = v.u8[0];
}
fn eqU8(a: *anyopaque, b: *anyopaque) bool {
    const pa: *u8 = @ptrCast(@alignCast(a));
    const pb: *u8 = @ptrCast(@alignCast(b));
    return pa.* == pb.*;
}
fn fmtU8(ptr: *anyopaque, buf: []u8) []const u8 {
    const p: *u8 = @ptrCast(@alignCast(ptr));
    return std.fmt.bufPrint(buf, "{d}", .{p.*}) catch buf[0..0];
}
fn hashU8(ptr: *anyopaque) u64 {
    const p: *u8 = @ptrCast(@alignCast(ptr));
    return @as(u64, p.*);
}

// ── i16 ──
fn readI16(ptr: *anyopaque) value.Value {
    const p: *i16 = @ptrCast(@alignCast(ptr));
    return value.Value{ .i16 = @bitCast(p.*) };
}
fn writeI16(ptr: *anyopaque, v: value.Value) void {
    const p: *i16 = @ptrCast(@alignCast(ptr));
    p.* = @bitCast(v.i16);
}
fn eqI16(a: *anyopaque, b: *anyopaque) bool {
    const pa: *i16 = @ptrCast(@alignCast(a));
    const pb: *i16 = @ptrCast(@alignCast(b));
    return pa.* == pb.*;
}
fn fmtI16(ptr: *anyopaque, buf: []u8) []const u8 {
    const p: *i16 = @ptrCast(@alignCast(ptr));
    return std.fmt.bufPrint(buf, "{d}", .{p.*}) catch buf[0..0];
}
fn hashI16(ptr: *anyopaque) u64 {
    const p: *i16 = @ptrCast(@alignCast(ptr));
    const bits: u16 = @bitCast(p.*);
    return @as(u64, bits);
}

// ── u16 ──
fn readU16(ptr: *anyopaque) value.Value {
    const p: *u16 = @ptrCast(@alignCast(ptr));
    return value.Value{ .u16 = @bitCast(p.*) };
}
fn writeU16(ptr: *anyopaque, v: value.Value) void {
    const p: *u16 = @ptrCast(@alignCast(ptr));
    p.* = @bitCast(v.u16);
}
fn eqU16(a: *anyopaque, b: *anyopaque) bool {
    const pa: *u16 = @ptrCast(@alignCast(a));
    const pb: *u16 = @ptrCast(@alignCast(b));
    return pa.* == pb.*;
}
fn fmtU16(ptr: *anyopaque, buf: []u8) []const u8 {
    const p: *u16 = @ptrCast(@alignCast(ptr));
    return std.fmt.bufPrint(buf, "{d}", .{p.*}) catch buf[0..0];
}
fn hashU16(ptr: *anyopaque) u64 {
    const p: *u16 = @ptrCast(@alignCast(ptr));
    return @as(u64, p.*);
}

// ── i32 ──
fn readI32(ptr: *anyopaque) value.Value {
    const p: *i32 = @ptrCast(@alignCast(ptr));
    return value.Value{ .i32 = @bitCast(p.*) };
}
fn writeI32(ptr: *anyopaque, v: value.Value) void {
    const p: *i32 = @ptrCast(@alignCast(ptr));
    p.* = @bitCast(v.i32);
}
fn eqI32(a: *anyopaque, b: *anyopaque) bool {
    const pa: *i32 = @ptrCast(@alignCast(a));
    const pb: *i32 = @ptrCast(@alignCast(b));
    return pa.* == pb.*;
}
fn fmtI32(ptr: *anyopaque, buf: []u8) []const u8 {
    const p: *i32 = @ptrCast(@alignCast(ptr));
    return std.fmt.bufPrint(buf, "{d}", .{p.*}) catch buf[0..0];
}
fn hashI32(ptr: *anyopaque) u64 {
    const p: *i32 = @ptrCast(@alignCast(ptr));
    const bits: u32 = @bitCast(p.*);
    return @as(u64, bits);
}

// ── u32 ──
fn readU32(ptr: *anyopaque) value.Value {
    const p: *u32 = @ptrCast(@alignCast(ptr));
    return value.Value{ .u32 = @bitCast(p.*) };
}
fn writeU32(ptr: *anyopaque, v: value.Value) void {
    const p: *u32 = @ptrCast(@alignCast(ptr));
    p.* = @bitCast(v.u32);
}
fn eqU32(a: *anyopaque, b: *anyopaque) bool {
    const pa: *u32 = @ptrCast(@alignCast(a));
    const pb: *u32 = @ptrCast(@alignCast(b));
    return pa.* == pb.*;
}
fn fmtU32(ptr: *anyopaque, buf: []u8) []const u8 {
    const p: *u32 = @ptrCast(@alignCast(ptr));
    return std.fmt.bufPrint(buf, "{d}", .{p.*}) catch buf[0..0];
}
fn hashU32(ptr: *anyopaque) u64 {
    const p: *u32 = @ptrCast(@alignCast(ptr));
    return @as(u64, p.*);
}

// ── i64 ──
fn readI64(ptr: *anyopaque) value.Value {
    const p: *i64 = @ptrCast(@alignCast(ptr));
    return value.Value{ .i64 = @bitCast(p.*) };
}
fn writeI64(ptr: *anyopaque, v: value.Value) void {
    const p: *i64 = @ptrCast(@alignCast(ptr));
    p.* = @bitCast(v.i64);
}
fn eqI64(a: *anyopaque, b: *anyopaque) bool {
    const pa: *i64 = @ptrCast(@alignCast(a));
    const pb: *i64 = @ptrCast(@alignCast(b));
    return pa.* == pb.*;
}
fn fmtI64(ptr: *anyopaque, buf: []u8) []const u8 {
    const p: *i64 = @ptrCast(@alignCast(ptr));
    return std.fmt.bufPrint(buf, "{d}", .{p.*}) catch buf[0..0];
}
fn hashI64(ptr: *anyopaque) u64 {
    const p: *i64 = @ptrCast(@alignCast(ptr));
    return @as(u64, @bitCast(p.*));
}

// ── u64 ──
fn readU64(ptr: *anyopaque) value.Value {
    const p: *u64 = @ptrCast(@alignCast(ptr));
    return value.Value{ .u64 = @bitCast(p.*) };
}
fn writeU64(ptr: *anyopaque, v: value.Value) void {
    const p: *u64 = @ptrCast(@alignCast(ptr));
    p.* = @bitCast(v.u64);
}
fn eqU64(a: *anyopaque, b: *anyopaque) bool {
    const pa: *u64 = @ptrCast(@alignCast(a));
    const pb: *u64 = @ptrCast(@alignCast(b));
    return pa.* == pb.*;
}
fn fmtU64(ptr: *anyopaque, buf: []u8) []const u8 {
    const p: *u64 = @ptrCast(@alignCast(ptr));
    return std.fmt.bufPrint(buf, "{d}", .{p.*}) catch buf[0..0];
}
fn hashU64(ptr: *anyopaque) u64 {
    const p: *u64 = @ptrCast(@alignCast(ptr));
    return p.*;
}

// ── i128 (Value.i128 是 [16]u8，用 *[16]u8 指针) ──
fn readI128(ptr: *anyopaque) value.Value {
    const p: *[16]u8 = @ptrCast(@alignCast(ptr));
    return value.Value{ .i128 = p.* };
}
fn writeI128(ptr: *anyopaque, v: value.Value) void {
    const p: *[16]u8 = @ptrCast(@alignCast(ptr));
    p.* = v.i128;
}
fn eqI128(a: *anyopaque, b: *anyopaque) bool {
    const pa: *[16]u8 = @ptrCast(@alignCast(a));
    const pb: *[16]u8 = @ptrCast(@alignCast(b));
    return std.mem.eql(u8, pa, pb);
}
fn fmtI128(ptr: *anyopaque, buf: []u8) []const u8 {
    const p: *[16]u8 = @ptrCast(@alignCast(ptr));
    const v: i128 = @bitCast(p.*);
    return std.fmt.bufPrint(buf, "{d}", .{v}) catch buf[0..0];
}
fn hashI128(ptr: *anyopaque) u64 {
    const p: *[16]u8 = @ptrCast(@alignCast(ptr));
    // FNV-1a 64bit on 16 bytes
    var h: u64 = 0xcbf29ce484222325;
    for (p.*) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

// ── u128 ──
fn readU128(ptr: *anyopaque) value.Value {
    const p: *[16]u8 = @ptrCast(@alignCast(ptr));
    return value.Value{ .u128 = p.* };
}
fn writeU128(ptr: *anyopaque, v: value.Value) void {
    const p: *[16]u8 = @ptrCast(@alignCast(ptr));
    p.* = v.u128;
}
fn eqU128(a: *anyopaque, b: *anyopaque) bool {
    const pa: *[16]u8 = @ptrCast(@alignCast(a));
    const pb: *[16]u8 = @ptrCast(@alignCast(b));
    return std.mem.eql(u8, pa, pb);
}
fn fmtU128(ptr: *anyopaque, buf: []u8) []const u8 {
    const p: *[16]u8 = @ptrCast(@alignCast(ptr));
    const v: u128 = @bitCast(p.*);
    return std.fmt.bufPrint(buf, "{d}", .{v}) catch buf[0..0];
}
fn hashU128(ptr: *anyopaque) u64 {
    const p: *[16]u8 = @ptrCast(@alignCast(ptr));
    var h: u64 = 0xcbf29ce484222325;
    for (p.*) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

// ── isize ──
fn readIsize(ptr: *anyopaque) value.Value {
    const p: *isize = @ptrCast(@alignCast(ptr));
    return value.Value{ .isize = @bitCast(p.*) };
}
fn writeIsize(ptr: *anyopaque, v: value.Value) void {
    const p: *isize = @ptrCast(@alignCast(ptr));
    p.* = @bitCast(v.isize);
}
fn eqIsize(a: *anyopaque, b: *anyopaque) bool {
    const pa: *isize = @ptrCast(@alignCast(a));
    const pb: *isize = @ptrCast(@alignCast(b));
    return pa.* == pb.*;
}
fn fmtIsize(ptr: *anyopaque, buf: []u8) []const u8 {
    const p: *isize = @ptrCast(@alignCast(ptr));
    return std.fmt.bufPrint(buf, "{d}", .{p.*}) catch buf[0..0];
}
fn hashIsize(ptr: *anyopaque) u64 {
    const p: *isize = @ptrCast(@alignCast(ptr));
    const u: usize = @bitCast(p.*);
    return @as(u64, u);
}

// ── usize ──
fn readUsize(ptr: *anyopaque) value.Value {
    const p: *usize = @ptrCast(@alignCast(ptr));
    return value.Value{ .usize = @bitCast(p.*) };
}
fn writeUsize(ptr: *anyopaque, v: value.Value) void {
    const p: *usize = @ptrCast(@alignCast(ptr));
    p.* = @bitCast(v.usize);
}
fn eqUsize(a: *anyopaque, b: *anyopaque) bool {
    const pa: *usize = @ptrCast(@alignCast(a));
    const pb: *usize = @ptrCast(@alignCast(b));
    return pa.* == pb.*;
}
fn fmtUsize(ptr: *anyopaque, buf: []u8) []const u8 {
    const p: *usize = @ptrCast(@alignCast(ptr));
    return std.fmt.bufPrint(buf, "{d}", .{p.*}) catch buf[0..0];
}
fn hashUsize(ptr: *anyopaque) u64 {
    const p: *usize = @ptrCast(@alignCast(ptr));
    return @as(u64, p.*);
}

// ── f16 ──
fn readF16(ptr: *anyopaque) value.Value {
    const p: *f16 = @ptrCast(@alignCast(ptr));
    return value.Value{ .f16 = @bitCast(p.*) };
}
fn writeF16(ptr: *anyopaque, v: value.Value) void {
    const p: *f16 = @ptrCast(@alignCast(ptr));
    p.* = @bitCast(v.f16);
}
fn eqF16(a: *anyopaque, b: *anyopaque) bool {
    const pa: *f16 = @ptrCast(@alignCast(a));
    const pb: *f16 = @ptrCast(@alignCast(b));
    return pa.* == pb.*;
}
fn fmtF16(ptr: *anyopaque, buf: []u8) []const u8 {
    const p: *f16 = @ptrCast(@alignCast(ptr));
    return std.fmt.bufPrint(buf, "{d}", .{p.*}) catch buf[0..0];
}
fn hashF16(ptr: *anyopaque) u64 {
    const p: *f16 = @ptrCast(@alignCast(ptr));
    const bits: u16 = @bitCast(p.*);
    return @as(u64, bits);
}

// ── f32 ──
fn readF32(ptr: *anyopaque) value.Value {
    const p: *f32 = @ptrCast(@alignCast(ptr));
    return value.Value{ .f32 = @bitCast(p.*) };
}
fn writeF32(ptr: *anyopaque, v: value.Value) void {
    const p: *f32 = @ptrCast(@alignCast(ptr));
    p.* = @bitCast(v.f32);
}
fn eqF32(a: *anyopaque, b: *anyopaque) bool {
    const pa: *f32 = @ptrCast(@alignCast(a));
    const pb: *f32 = @ptrCast(@alignCast(b));
    return pa.* == pb.*;
}
fn fmtF32(ptr: *anyopaque, buf: []u8) []const u8 {
    const p: *f32 = @ptrCast(@alignCast(ptr));
    return std.fmt.bufPrint(buf, "{d}", .{p.*}) catch buf[0..0];
}
fn hashF32(ptr: *anyopaque) u64 {
    const p: *f32 = @ptrCast(@alignCast(ptr));
    const bits: u32 = @bitCast(p.*);
    return @as(u64, bits);
}

// ── f64 ──
fn readF64(ptr: *anyopaque) value.Value {
    const p: *f64 = @ptrCast(@alignCast(ptr));
    return value.Value{ .f64 = @bitCast(p.*) };
}
fn writeF64(ptr: *anyopaque, v: value.Value) void {
    const p: *f64 = @ptrCast(@alignCast(ptr));
    p.* = @bitCast(v.f64);
}
fn eqF64(a: *anyopaque, b: *anyopaque) bool {
    const pa: *f64 = @ptrCast(@alignCast(a));
    const pb: *f64 = @ptrCast(@alignCast(b));
    return pa.* == pb.*;
}
fn fmtF64(ptr: *anyopaque, buf: []u8) []const u8 {
    const p: *f64 = @ptrCast(@alignCast(ptr));
    return std.fmt.bufPrint(buf, "{d}", .{p.*}) catch buf[0..0];
}
fn hashF64(ptr: *anyopaque) u64 {
    const p: *f64 = @ptrCast(@alignCast(ptr));
    return @as(u64, @bitCast(p.*));
}

// ── f128 ──
fn readF128(ptr: *anyopaque) value.Value {
    const p: *[16]u8 = @ptrCast(@alignCast(ptr));
    return value.Value{ .f128 = p.* };
}
fn writeF128(ptr: *anyopaque, v: value.Value) void {
    const p: *[16]u8 = @ptrCast(@alignCast(ptr));
    p.* = v.f128;
}
fn eqF128(a: *anyopaque, b: *anyopaque) bool {
    const pa: *[16]u8 = @ptrCast(@alignCast(a));
    const pb: *[16]u8 = @ptrCast(@alignCast(b));
    return std.mem.eql(u8, pa, pb);
}
fn fmtF128(ptr: *anyopaque, buf: []u8) []const u8 {
    const p: *[16]u8 = @ptrCast(@alignCast(ptr));
    const v: f128 = @bitCast(p.*);
    return std.fmt.bufPrint(buf, "{d}", .{v}) catch buf[0..0];
}
fn hashF128(ptr: *anyopaque) u64 {
    const p: *[16]u8 = @ptrCast(@alignCast(ptr));
    var h: u64 = 0xcbf29ce484222325;
    for (p.*) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

// ── bool (Value.boolean 是 [1]u8) ──
fn readBool(ptr: *anyopaque) value.Value {
    const p: *bool = @ptrCast(@alignCast(ptr));
    return value.Value{ .boolean = .{@intFromBool(p.*)} };
}
fn writeBool(ptr: *anyopaque, v: value.Value) void {
    const p: *bool = @ptrCast(@alignCast(ptr));
    p.* = v.boolean[0] != 0;
}
fn eqBool(a: *anyopaque, b: *anyopaque) bool {
    const pa: *bool = @ptrCast(@alignCast(a));
    const pb: *bool = @ptrCast(@alignCast(b));
    return pa.* == pb.*;
}
fn fmtBool(ptr: *anyopaque, buf: []u8) []const u8 {
    const p: *bool = @ptrCast(@alignCast(ptr));
    return std.fmt.bufPrint(buf, "{s}", .{if (p.*) "true" else "false"}) catch buf[0..0];
}
fn hashBool(ptr: *anyopaque) u64 {
    const p: *bool = @ptrCast(@alignCast(ptr));
    return if (p.*) 1 else 0;
}

// ── char (Value.char 是 [4]u8，存储为 *u32) ──
fn readChar(ptr: *anyopaque) value.Value {
    const p: *u32 = @ptrCast(@alignCast(ptr));
    return value.Value{ .char = @bitCast(p.*) };
}
fn writeChar(ptr: *anyopaque, v: value.Value) void {
    const p: *u32 = @ptrCast(@alignCast(ptr));
    p.* = @bitCast(v.char);
}
fn eqChar(a: *anyopaque, b: *anyopaque) bool {
    const pa: *u32 = @ptrCast(@alignCast(a));
    const pb: *u32 = @ptrCast(@alignCast(b));
    return pa.* == pb.*;
}
fn fmtChar(ptr: *anyopaque, buf: []u8) []const u8 {
    const p: *u32 = @ptrCast(@alignCast(ptr));
    return std.fmt.bufPrint(buf, "{u}", .{@as(u21, @intCast(p.*))}) catch buf[0..0];
}
fn hashChar(ptr: *anyopaque) u64 {
    const p: *u32 = @ptrCast(@alignCast(ptr));
    return @as(u64, p.*);
}

// ════════════════════════════════════════════════════════════
// scalar_ops_table：所有 17 种标量的 ScalarOps 条目
// ════════════════════════════════════════════════════════════

pub const scalar_ops_table: std.EnumArray(ScalarKind, ScalarOps) = .init(.{
    .i8 = .{ .read = readI8, .write = writeI8, .equal = eqI8, .format = fmtI8, .hash = hashI8 },
    .u8 = .{ .read = readU8, .write = writeU8, .equal = eqU8, .format = fmtU8, .hash = hashU8 },
    .i16 = .{ .read = readI16, .write = writeI16, .equal = eqI16, .format = fmtI16, .hash = hashI16 },
    .u16 = .{ .read = readU16, .write = writeU16, .equal = eqU16, .format = fmtU16, .hash = hashU16 },
    .i32 = .{ .read = readI32, .write = writeI32, .equal = eqI32, .format = fmtI32, .hash = hashI32 },
    .u32 = .{ .read = readU32, .write = writeU32, .equal = eqU32, .format = fmtU32, .hash = hashU32 },
    .i64 = .{ .read = readI64, .write = writeI64, .equal = eqI64, .format = fmtI64, .hash = hashI64 },
    .u64 = .{ .read = readU64, .write = writeU64, .equal = eqU64, .format = fmtU64, .hash = hashU64 },
    .i128 = .{ .read = readI128, .write = writeI128, .equal = eqI128, .format = fmtI128, .hash = hashI128 },
    .u128 = .{ .read = readU128, .write = writeU128, .equal = eqU128, .format = fmtU128, .hash = hashU128 },
    .isize = .{ .read = readIsize, .write = writeIsize, .equal = eqIsize, .format = fmtIsize, .hash = hashIsize },
    .usize = .{ .read = readUsize, .write = writeUsize, .equal = eqUsize, .format = fmtUsize, .hash = hashUsize },
    .f16 = .{ .read = readF16, .write = writeF16, .equal = eqF16, .format = fmtF16, .hash = hashF16 },
    .f32 = .{ .read = readF32, .write = writeF32, .equal = eqF32, .format = fmtF32, .hash = hashF32 },
    .f64 = .{ .read = readF64, .write = writeF64, .equal = eqF64, .format = fmtF64, .hash = hashF64 },
    .f128 = .{ .read = readF128, .write = writeF128, .equal = eqF128, .format = fmtF128, .hash = hashF128 },
    .bool = .{ .read = readBool, .write = writeBool, .equal = eqBool, .format = fmtBool, .hash = hashBool },
    .char = .{ .read = readChar, .write = writeChar, .equal = eqChar, .format = fmtChar, .hash = hashChar },
});

// ════════════════════════════════════════════════════════════
// builtin_type_descriptors：所有 17 种标量的 TypeDescriptor
// type_id 与 singletonIdx（src/sema/type_check.zig:132）保持一致
// ════════════════════════════════════════════════════════════

pub const builtin_type_descriptors: std.EnumArray(ScalarKind, TypeDescriptor) = .init(.{
    .i8 = .{
        .size = 1,
        .alignment = 1,
        .is_ref = false,
        .scalar_ops = scalar_ops_table.getPtrConst(.i8),
        .type_id = 0,
        .type_name = "i8",
        .chan = .i8_chan,
    },
    .u8 = .{
        .size = 1,
        .alignment = 1,
        .is_ref = false,
        .scalar_ops = scalar_ops_table.getPtrConst(.u8),
        .type_id = 5,
        .type_name = "u8",
        .chan = .u8_chan,
    },
    .i16 = .{
        .size = 2,
        .alignment = 2,
        .is_ref = false,
        .scalar_ops = scalar_ops_table.getPtrConst(.i16),
        .type_id = 1,
        .type_name = "i16",
        .chan = .i16_chan,
    },
    .u16 = .{
        .size = 2,
        .alignment = 2,
        .is_ref = false,
        .scalar_ops = scalar_ops_table.getPtrConst(.u16),
        .type_id = 6,
        .type_name = "u16",
        .chan = .u16_chan,
    },
    .i32 = .{
        .size = 4,
        .alignment = 4,
        .is_ref = false,
        .scalar_ops = scalar_ops_table.getPtrConst(.i32),
        .type_id = 2,
        .type_name = "i32",
        .chan = .i32_chan,
    },
    .u32 = .{
        .size = 4,
        .alignment = 4,
        .is_ref = false,
        .scalar_ops = scalar_ops_table.getPtrConst(.u32),
        .type_id = 7,
        .type_name = "u32",
        .chan = .u32_chan,
    },
    .i64 = .{
        .size = 8,
        .alignment = 8,
        .is_ref = false,
        .scalar_ops = scalar_ops_table.getPtrConst(.i64),
        .type_id = 3,
        .type_name = "i64",
        .chan = .i64_chan,
    },
    .u64 = .{
        .size = 8,
        .alignment = 8,
        .is_ref = false,
        .scalar_ops = scalar_ops_table.getPtrConst(.u64),
        .type_id = 8,
        .type_name = "u64",
        .chan = .u64_chan,
    },
    .i128 = .{
        .size = 16,
        .alignment = 16,
        .is_ref = false,
        .scalar_ops = scalar_ops_table.getPtrConst(.i128),
        .type_id = 4,
        .type_name = "i128",
        .chan = .i128_chan,
    },
    .u128 = .{
        .size = 16,
        .alignment = 16,
        .is_ref = false,
        .scalar_ops = scalar_ops_table.getPtrConst(.u128),
        .type_id = 9,
        .type_name = "u128",
        .chan = .u128_chan,
    },
    .isize = .{
        .size = @sizeOf(isize),
        .alignment = @alignOf(isize),
        .is_ref = false,
        .scalar_ops = scalar_ops_table.getPtrConst(.isize),
        .type_id = 20,
        .type_name = "isize",
        .chan = .isize_chan,
    },
    .usize = .{
        .size = @sizeOf(usize),
        .alignment = @alignOf(usize),
        .is_ref = false,
        .scalar_ops = scalar_ops_table.getPtrConst(.usize),
        .type_id = 21,
        .type_name = "usize",
        .chan = .usize_chan,
    },
    .f16 = .{
        .size = 2,
        .alignment = 2,
        .is_ref = false,
        .scalar_ops = scalar_ops_table.getPtrConst(.f16),
        .type_id = 10,
        .type_name = "f16",
        .chan = .f16_chan,
    },
    .f32 = .{
        .size = 4,
        .alignment = 4,
        .is_ref = false,
        .scalar_ops = scalar_ops_table.getPtrConst(.f32),
        .type_id = 11,
        .type_name = "f32",
        .chan = .f32_chan,
    },
    .f64 = .{
        .size = 8,
        .alignment = 8,
        .is_ref = false,
        .scalar_ops = scalar_ops_table.getPtrConst(.f64),
        .type_id = 12,
        .type_name = "f64",
        .chan = .f64_chan,
    },
    .f128 = .{
        .size = 16,
        .alignment = 16,
        .is_ref = false,
        .scalar_ops = scalar_ops_table.getPtrConst(.f128),
        .type_id = 13,
        .type_name = "f128",
        .chan = .f128_chan,
    },
    .bool = .{
        .size = 1,
        .alignment = 1,
        .is_ref = false,
        .scalar_ops = scalar_ops_table.getPtrConst(.bool),
        .type_id = 14,
        .type_name = "bool",
        .chan = .bool_chan,
    },
    .char = .{
        .size = 4,
        .alignment = 4,
        .is_ref = false,
        .scalar_ops = scalar_ops_table.getPtrConst(.char),
        .type_id = 16,
        .type_name = "char",
        .chan = .char_chan,
    },
});

/// 按 ChanType 反查内置标量 TypeDescriptor
pub fn lookupBuiltinByChan(ct: ChanType) ?*const TypeDescriptor {
    inline for (@typeInfo(ScalarKind).@"enum".fields) |field| {
        const kind: ScalarKind = @enumFromInt(field.value);
        const d = builtin_type_descriptors.getPtrConst(kind);
        if (d.chan == ct) return d;
    }
    return null;
}

// ════════════════════════════════════════════════════════════
// 单元测试
// ════════════════════════════════════════════════════════════

test "scalar_ops_table: 所有 17 种标量均有条目" {
    inline for (@typeInfo(ScalarKind).@"enum".fields) |field| {
        const kind: ScalarKind = @enumFromInt(field.value);
        _ = scalar_ops_table.get(kind); // EnumArray.get 总返回值
    }
}

test "builtin_type_descriptors: 所有 17 种标量均有描述符" {
    inline for (@typeInfo(ScalarKind).@"enum".fields) |field| {
        const kind: ScalarKind = @enumFromInt(field.value);
        const d = builtin_type_descriptors.get(kind);
        try std.testing.expect(d.scalar_ops != null);
        try std.testing.expect(d.is_ref == false);
        try std.testing.expect(d.slot_kind == .none);
        try std.testing.expect(d.slots.len == 0);
    }
}

test "lookupBuiltinByChan: 标量类型往返查询" {
    inline for (@typeInfo(ScalarKind).@"enum".fields) |field| {
        const kind: ScalarKind = @enumFromInt(field.value);
        const d = builtin_type_descriptors.get(kind);
        const found = lookupBuiltinByChan(d.chan) orelse return error.LookupFailed;
        try std.testing.expect(found.type_id == d.type_id);
        try std.testing.expectEqualStrings(d.type_name, found.type_name);
    }
}

test "lookupBuiltinByChan: 非标量 chan 返回 null" {
    try std.testing.expect(lookupBuiltinByChan(.null_chan) == null);
    try std.testing.expect(lookupBuiltinByChan(.unit_chan) == null);
    try std.testing.expect(lookupBuiltinByChan(.ref_chan) == null);
    try std.testing.expect(lookupBuiltinByChan(.mask_chan) == null);
    try std.testing.expect(lookupBuiltinByChan(.nullable_chan) == null);
}

test "TypeDescriptor.elemWidth: 返回 size" {
    inline for (@typeInfo(ScalarKind).@"enum".fields) |field| {
        const kind: ScalarKind = @enumFromInt(field.value);
        const d = builtin_type_descriptors.get(kind);
        try std.testing.expect(d.elemWidth() == d.size);
    }
}

test "ScalarOps: i64 read/write 往返" {
    var v: i64 = -12345;
    const ops = scalar_ops_table.get(.i64);
    const val = ops.read(@ptrCast(&v));
    try std.testing.expectEqual(@as(i64, -12345), val.asI64());

    var out: i64 = 0;
    ops.write(@ptrCast(&out), val);
    try std.testing.expectEqual(@as(i64, -12345), out);
}

test "ScalarOps: bool read/write 往返" {
    var b: bool = true;
    const ops = scalar_ops_table.get(.bool);
    const val = ops.read(@ptrCast(&b));
    try std.testing.expect(val.asBool());

    var out: bool = false;
    ops.write(@ptrCast(&out), val);
    try std.testing.expect(out);
}

test "ScalarOps: i128 read/write/equal 往返" {
    const bytes = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10 };
    var src: [16]u8 = bytes;
    const ops = scalar_ops_table.get(.i128);
    const val = ops.read(@ptrCast(&src));
    try std.testing.expectEqualSlices(u8, &bytes, &val.i128);

    var out: [16]u8 = .{0} ** 16;
    ops.write(@ptrCast(&out), val);
    try std.testing.expect(ops.equal(@ptrCast(&src), @ptrCast(&out)));
}

test "ScalarOps: format 输出可读字符串" {
    var v: i64 = 42;
    const ops = scalar_ops_table.get(.i64);
    var buf: [32]u8 = undefined;
    const s = ops.format(@ptrCast(&v), &buf);
    try std.testing.expectEqualStrings("42", s);

    var b: bool = false;
    const bool_ops = scalar_ops_table.get(.bool);
    const bs = bool_ops.format(@ptrCast(&b), &buf);
    try std.testing.expectEqualStrings("false", bs);
}

test "ScalarOps: hash 同值同哈希" {
    var a: i64 = 99;
    var b: i64 = 99;
    const ops = scalar_ops_table.get(.i64);
    try std.testing.expect(ops.hash(@ptrCast(&a)) == ops.hash(@ptrCast(&b)));
}
