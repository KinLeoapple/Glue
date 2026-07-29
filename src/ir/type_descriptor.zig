//! TypeDescriptor + TypeOps vtable（类型定义 + 标量 vtable 实现）
//!
//! v3 spec §4.1: 替代 TypeKind 枚举 + ConcreteType 的统一类型描述符。
//! 所有类型（标量/引用/复合/容器）统一表示，递归 slots 支持任意嵌套。
//! ops vtable 消除标量读写 switch，增加类型只需追加 ops_table 条目。
//!
//! 本文件包含：
//! - 类型定义（TypeDescriptor/TypeOps）
//! - 标量 vtable 实现（read/write/equal/format/hash，18 种标量共 90 个函数）
//! - 静态 TypeDescriptor 常量（每个标量类型对应的 TypeDescriptor，标量类型已填充 ops）
//! - lookupByTypeId/lookupByIntKind/lookupByFloatKind（按 type_id/IntKind/FloatKind 查找）
//!
//! ops 实现已从 sema/type_descriptor.zig 迁入此文件，
//! 引擎通过 ChanSlot.type_desc.ops 即可获得统一的标量读写接口。

const std = @import("std");
const value = @import("value");

/// 使用 msync 系统调用安全检查地址是否可读。
/// msync 返回 -1（errno=ENOMEM）表示内存未映射，返回 0 表示已映射。
/// 避免直接解引用可能无效的指针（如标量位模式被误判为堆指针）。
extern "c" fn msync(addr: [*]const u8, len: usize, flags: c_int) c_int;

pub fn isReadable(addr: usize) bool {
    const ps = std.heap.page_size_min;
    const page_addr = addr & ~(@as(usize, ps) - 1);
    const result = msync(@ptrFromInt(page_addr), ps, 1); // MS_ASYNC = 1
    return result == 0;
}

/// 标量操作 vtable
pub const TypeOps = struct {
    read: *const fn (ptr: *anyopaque) value.Value,
    write: *const fn (ptr: *anyopaque, v: value.Value) void,
    /// 将任意 Value 强制转换为本类型的标准 Value（用于跨类型通道写入）
    coerce: *const fn (v: value.Value) value.Value,
    equal: *const fn (a: *anyopaque, b: *anyopaque) bool,
    format: *const fn (ptr: *anyopaque, buf: []u8) []const u8,
    hash: *const fn (ptr: *anyopaque) u64,
    /// 克隆本通道的值：标量类型直接返回 read（值语义，忽略 allocator）；
    /// ref 类型执行深拷贝。深拷贝决策内嵌到 ops，替代基于 is_ref 的运行时分支。
    clone: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) value.Value,
};

/// 统一类型描述符（替代 TypeKind 枚举 + ConcreteType）
/// 所有类型信息集中于此，运行时通过 type_desc 获取类型属性，
/// 通过 ops vtable 统一读写值，无任何通道派分。
pub const TypeDescriptor = struct {
    size: u8,
    ops: *const TypeOps,
    type_id: u16,
    type_name: []const u8,

    pub const NULL_TYPE_ID: u16 = 20;
    pub const UNIT_TYPE_ID: u16 = 21;

    pub fn elemWidth(self: *const TypeDescriptor) u8 {
        return self.size;
    }

    /// 是否为 null 类型（通过 type_id 判断）
    pub fn isNullType(self: *const TypeDescriptor) bool {
        return self.type_id == NULL_TYPE_ID;
    }

    /// 是否为 unit/void 类型（通过 type_id 判断）
    pub fn isUnitType(self: *const TypeDescriptor) bool {
        return self.type_id == UNIT_TYPE_ID;
    }

    /// 是否为引用类型（通过 type_id 判断，替代 is_ref 字段）
    /// type_id 1-18: 18 种标量（非引用）
    /// type_id 20: null（非引用）
    /// type_id 21: unit/void（非引用）
    /// type_id 19: str（引用）
    /// type_id 0: ref_descriptor / nullable_descriptor（引用/特殊）
    /// type_id 22+: 用户类型（引用）
    /// nullable<T> 类型（无论 inner 是否为引用）均不是 ref 通道：
    /// nullable 通道使用 [data|flag] 布局，由 nullable vtable 统一处理读写，
    /// 不走 ref_chan 的 8 字节指针路径。
    pub fn isRef(self: *const TypeDescriptor) bool {
        if (self.isNullable()) return false;
        return switch (self.type_id) {
            1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 20, 21 => false,
            else => true,
        };
    }

    /// 是否为 nullable<T> 类型（通过 type_name 前缀判断）
    pub fn isNullable(self: *const TypeDescriptor) bool {
        return std.mem.startsWith(u8, self.type_name, "nullable");
    }

    /// 是否为整数类型（i8..i128, u8..u128, isize, usize）
    pub fn isInt(self: *const TypeDescriptor) bool {
        const n = self.type_name;
        if (n.len < 2) return false;
        return (n[0] == 'i' or n[0] == 'u') and (std.ascii.isDigit(n[1]) or (n[1] == 's' and n.len == 5));
    }

    /// 是否为浮点类型（f16, f32, f64, f128）
    pub fn isFloat(self: *const TypeDescriptor) bool {
        const n = self.type_name;
        if (n.len < 2) return false;
        return n[0] == 'f' and std.ascii.isDigit(n[1]);
    }

    /// TypeDescriptor → IntKind（非整数类型返回 null）
    pub fn toIntKind(self: *const TypeDescriptor) ?value.scalar.IntKind {
        const n = self.type_name;
        if (std.mem.eql(u8, n, "i8")) return .i8;
        if (std.mem.eql(u8, n, "i16")) return .i16;
        if (std.mem.eql(u8, n, "i32")) return .i32;
        if (std.mem.eql(u8, n, "i64")) return .i64;
        if (std.mem.eql(u8, n, "i128")) return .i128;
        if (std.mem.eql(u8, n, "u8")) return .u8;
        if (std.mem.eql(u8, n, "u16")) return .u16;
        if (std.mem.eql(u8, n, "u32")) return .u32;
        if (std.mem.eql(u8, n, "u64")) return .u64;
        if (std.mem.eql(u8, n, "u128")) return .u128;
        if (std.mem.eql(u8, n, "isize")) return .isize;
        if (std.mem.eql(u8, n, "usize")) return .usize;
        return null;
    }

    /// TypeDescriptor → FloatKind（非浮点类型返回 null）
    pub fn toFloatKind(self: *const TypeDescriptor) ?value.scalar.FloatKind {
        const n = self.type_name;
        if (std.mem.eql(u8, n, "f16")) return .f16;
        if (std.mem.eql(u8, n, "f32")) return .f32;
        if (std.mem.eql(u8, n, "f64")) return .f64;
        if (std.mem.eql(u8, n, "f128")) return .f128;
        return null;
    }
};

// ════════════════════════════════════════════════════════════
// 标量 vtable 实现：read/write/equal/format/hash
// ════════════════════════════════════════════════════════════
// 18 种标量类型各 5 个函数，共 90 个函数。
// 函数均为 pub 以便 sema/type_descriptor.zig 引用（避免实现重复）。

// ── i8 ──
pub fn readI8(ptr: *anyopaque) value.Value {
    const p: *i8 = @ptrCast(@alignCast(ptr));
    return value.Value{ .i8 = @bitCast(p.*) };
}
pub fn writeI8(ptr: *anyopaque, v: value.Value) void {
    const p: *i8 = @ptrCast(@alignCast(ptr));
    p.* = @bitCast(v.i8);
}
pub fn eqI8(a: *anyopaque, b: *anyopaque) bool {
    const pa: *i8 = @ptrCast(@alignCast(a));
    const pb: *i8 = @ptrCast(@alignCast(b));
    return pa.* == pb.*;
}
pub fn fmtI8(ptr: *anyopaque, buf: []u8) []const u8 {
    const p: *i8 = @ptrCast(@alignCast(ptr));
    return std.fmt.bufPrint(buf, "{d}", .{p.*}) catch buf[0..0];
}
pub fn hashI8(ptr: *anyopaque) u64 {
    const p: *i8 = @ptrCast(@alignCast(ptr));
    const bits: u8 = @bitCast(p.*);
    return @as(u64, bits);
}

// ── u8 ──
pub fn readU8(ptr: *anyopaque) value.Value {
    const p: *u8 = @ptrCast(@alignCast(ptr));
    return value.Value{ .u8 = .{p.*} };
}
pub fn writeU8(ptr: *anyopaque, v: value.Value) void {
    const p: *u8 = @ptrCast(@alignCast(ptr));
    p.* = v.u8[0];
}
pub fn eqU8(a: *anyopaque, b: *anyopaque) bool {
    const pa: *u8 = @ptrCast(@alignCast(a));
    const pb: *u8 = @ptrCast(@alignCast(b));
    return pa.* == pb.*;
}
pub fn fmtU8(ptr: *anyopaque, buf: []u8) []const u8 {
    const p: *u8 = @ptrCast(@alignCast(ptr));
    return std.fmt.bufPrint(buf, "{d}", .{p.*}) catch buf[0..0];
}
pub fn hashU8(ptr: *anyopaque) u64 {
    const p: *u8 = @ptrCast(@alignCast(ptr));
    return @as(u64, p.*);
}

// ── i16 ──
pub fn readI16(ptr: *anyopaque) value.Value {
    const p: *i16 = @ptrCast(@alignCast(ptr));
    return value.Value{ .i16 = @bitCast(p.*) };
}
pub fn writeI16(ptr: *anyopaque, v: value.Value) void {
    const p: *i16 = @ptrCast(@alignCast(ptr));
    p.* = @bitCast(v.i16);
}
pub fn eqI16(a: *anyopaque, b: *anyopaque) bool {
    const pa: *i16 = @ptrCast(@alignCast(a));
    const pb: *i16 = @ptrCast(@alignCast(b));
    return pa.* == pb.*;
}
pub fn fmtI16(ptr: *anyopaque, buf: []u8) []const u8 {
    const p: *i16 = @ptrCast(@alignCast(ptr));
    return std.fmt.bufPrint(buf, "{d}", .{p.*}) catch buf[0..0];
}
pub fn hashI16(ptr: *anyopaque) u64 {
    const p: *i16 = @ptrCast(@alignCast(ptr));
    const bits: u16 = @bitCast(p.*);
    return @as(u64, bits);
}

// ── u16 ──
pub fn readU16(ptr: *anyopaque) value.Value {
    const p: *u16 = @ptrCast(@alignCast(ptr));
    return value.Value{ .u16 = @bitCast(p.*) };
}
pub fn writeU16(ptr: *anyopaque, v: value.Value) void {
    const p: *u16 = @ptrCast(@alignCast(ptr));
    p.* = @bitCast(v.u16);
}
pub fn eqU16(a: *anyopaque, b: *anyopaque) bool {
    const pa: *u16 = @ptrCast(@alignCast(a));
    const pb: *u16 = @ptrCast(@alignCast(b));
    return pa.* == pb.*;
}
pub fn fmtU16(ptr: *anyopaque, buf: []u8) []const u8 {
    const p: *u16 = @ptrCast(@alignCast(ptr));
    return std.fmt.bufPrint(buf, "{d}", .{p.*}) catch buf[0..0];
}
pub fn hashU16(ptr: *anyopaque) u64 {
    const p: *u16 = @ptrCast(@alignCast(ptr));
    return @as(u64, p.*);
}

// ── i32 ──
pub fn readI32(ptr: *anyopaque) value.Value {
    const p: *i32 = @ptrCast(@alignCast(ptr));
    return value.Value{ .i32 = @bitCast(p.*) };
}
pub fn writeI32(ptr: *anyopaque, v: value.Value) void {
    const p: *i32 = @ptrCast(@alignCast(ptr));
    p.* = @bitCast(v.i32);
}
pub fn eqI32(a: *anyopaque, b: *anyopaque) bool {
    const pa: *i32 = @ptrCast(@alignCast(a));
    const pb: *i32 = @ptrCast(@alignCast(b));
    return pa.* == pb.*;
}
pub fn fmtI32(ptr: *anyopaque, buf: []u8) []const u8 {
    const p: *i32 = @ptrCast(@alignCast(ptr));
    return std.fmt.bufPrint(buf, "{d}", .{p.*}) catch buf[0..0];
}
pub fn hashI32(ptr: *anyopaque) u64 {
    const p: *i32 = @ptrCast(@alignCast(ptr));
    const bits: u32 = @bitCast(p.*);
    return @as(u64, bits);
}

// ── u32 ──
pub fn readU32(ptr: *anyopaque) value.Value {
    const p: *u32 = @ptrCast(@alignCast(ptr));
    return value.Value{ .u32 = @bitCast(p.*) };
}
pub fn writeU32(ptr: *anyopaque, v: value.Value) void {
    const p: *u32 = @ptrCast(@alignCast(ptr));
    p.* = @bitCast(v.u32);
}
pub fn eqU32(a: *anyopaque, b: *anyopaque) bool {
    const pa: *u32 = @ptrCast(@alignCast(a));
    const pb: *u32 = @ptrCast(@alignCast(b));
    return pa.* == pb.*;
}
pub fn fmtU32(ptr: *anyopaque, buf: []u8) []const u8 {
    const p: *u32 = @ptrCast(@alignCast(ptr));
    return std.fmt.bufPrint(buf, "{d}", .{p.*}) catch buf[0..0];
}
pub fn hashU32(ptr: *anyopaque) u64 {
    const p: *u32 = @ptrCast(@alignCast(ptr));
    return @as(u64, p.*);
}

// ── i64 ──
pub fn readI64(ptr: *anyopaque) value.Value {
    const p: *i64 = @ptrCast(@alignCast(ptr));
    return value.Value{ .i64 = @bitCast(p.*) };
}
pub fn writeI64(ptr: *anyopaque, v: value.Value) void {
    const p: *i64 = @ptrCast(@alignCast(ptr));
    p.* = @bitCast(v.i64);
}
pub fn eqI64(a: *anyopaque, b: *anyopaque) bool {
    const pa: *i64 = @ptrCast(@alignCast(a));
    const pb: *i64 = @ptrCast(@alignCast(b));
    return pa.* == pb.*;
}
pub fn fmtI64(ptr: *anyopaque, buf: []u8) []const u8 {
    const p: *i64 = @ptrCast(@alignCast(ptr));
    return std.fmt.bufPrint(buf, "{d}", .{p.*}) catch buf[0..0];
}
pub fn hashI64(ptr: *anyopaque) u64 {
    const p: *i64 = @ptrCast(@alignCast(ptr));
    return @as(u64, @bitCast(p.*));
}

// ── u64 ──
pub fn readU64(ptr: *anyopaque) value.Value {
    const p: *u64 = @ptrCast(@alignCast(ptr));
    return value.Value{ .u64 = @bitCast(p.*) };
}
pub fn writeU64(ptr: *anyopaque, v: value.Value) void {
    const p: *u64 = @ptrCast(@alignCast(ptr));
    p.* = @bitCast(v.u64);
}
pub fn eqU64(a: *anyopaque, b: *anyopaque) bool {
    const pa: *u64 = @ptrCast(@alignCast(a));
    const pb: *u64 = @ptrCast(@alignCast(b));
    return pa.* == pb.*;
}
pub fn fmtU64(ptr: *anyopaque, buf: []u8) []const u8 {
    const p: *u64 = @ptrCast(@alignCast(ptr));
    return std.fmt.bufPrint(buf, "{d}", .{p.*}) catch buf[0..0];
}
pub fn hashU64(ptr: *anyopaque) u64 {
    const p: *u64 = @ptrCast(@alignCast(ptr));
    return p.*;
}

// ── i128 (Value.i128 是 [16]u8，用 *[16]u8 指针) ──
pub fn readI128(ptr: *anyopaque) value.Value {
    const p: *[16]u8 = @ptrCast(@alignCast(ptr));
    return value.Value{ .i128 = p.* };
}
pub fn writeI128(ptr: *anyopaque, v: value.Value) void {
    const p: *[16]u8 = @ptrCast(@alignCast(ptr));
    p.* = v.i128;
}
pub fn eqI128(a: *anyopaque, b: *anyopaque) bool {
    const pa: *[16]u8 = @ptrCast(@alignCast(a));
    const pb: *[16]u8 = @ptrCast(@alignCast(b));
    return std.mem.eql(u8, pa, pb);
}
pub fn fmtI128(ptr: *anyopaque, buf: []u8) []const u8 {
    const p: *[16]u8 = @ptrCast(@alignCast(ptr));
    const v: i128 = @bitCast(p.*);
    return std.fmt.bufPrint(buf, "{d}", .{v}) catch buf[0..0];
}
pub fn hashI128(ptr: *anyopaque) u64 {
    const p: *[16]u8 = @ptrCast(@alignCast(ptr));
    var h: u64 = 0xcbf29ce484222325;
    for (p.*) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

// ── u128 ──
pub fn readU128(ptr: *anyopaque) value.Value {
    const p: *[16]u8 = @ptrCast(@alignCast(ptr));
    return value.Value{ .u128 = p.* };
}
pub fn writeU128(ptr: *anyopaque, v: value.Value) void {
    const p: *[16]u8 = @ptrCast(@alignCast(ptr));
    p.* = v.u128;
}
pub fn eqU128(a: *anyopaque, b: *anyopaque) bool {
    const pa: *[16]u8 = @ptrCast(@alignCast(a));
    const pb: *[16]u8 = @ptrCast(@alignCast(b));
    return std.mem.eql(u8, pa, pb);
}
pub fn fmtU128(ptr: *anyopaque, buf: []u8) []const u8 {
    const p: *[16]u8 = @ptrCast(@alignCast(ptr));
    const v: u128 = @bitCast(p.*);
    return std.fmt.bufPrint(buf, "{d}", .{v}) catch buf[0..0];
}
pub fn hashU128(ptr: *anyopaque) u64 {
    const p: *[16]u8 = @ptrCast(@alignCast(ptr));
    var h: u64 = 0xcbf29ce484222325;
    for (p.*) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

// ── isize ──
pub fn readIsize(ptr: *anyopaque) value.Value {
    const p: *isize = @ptrCast(@alignCast(ptr));
    return value.Value{ .isize = @bitCast(p.*) };
}
pub fn writeIsize(ptr: *anyopaque, v: value.Value) void {
    const p: *isize = @ptrCast(@alignCast(ptr));
    p.* = @bitCast(v.isize);
}
pub fn eqIsize(a: *anyopaque, b: *anyopaque) bool {
    const pa: *isize = @ptrCast(@alignCast(a));
    const pb: *isize = @ptrCast(@alignCast(b));
    return pa.* == pb.*;
}
pub fn fmtIsize(ptr: *anyopaque, buf: []u8) []const u8 {
    const p: *isize = @ptrCast(@alignCast(ptr));
    return std.fmt.bufPrint(buf, "{d}", .{p.*}) catch buf[0..0];
}
pub fn hashIsize(ptr: *anyopaque) u64 {
    const p: *isize = @ptrCast(@alignCast(ptr));
    const u: usize = @bitCast(p.*);
    return @as(u64, u);
}

// ── usize ──
pub fn readUsize(ptr: *anyopaque) value.Value {
    const p: *usize = @ptrCast(@alignCast(ptr));
    return value.Value{ .usize = @bitCast(p.*) };
}
pub fn writeUsize(ptr: *anyopaque, v: value.Value) void {
    const p: *usize = @ptrCast(@alignCast(ptr));
    p.* = @bitCast(v.usize);
}
pub fn eqUsize(a: *anyopaque, b: *anyopaque) bool {
    const pa: *usize = @ptrCast(@alignCast(a));
    const pb: *usize = @ptrCast(@alignCast(b));
    return pa.* == pb.*;
}
pub fn fmtUsize(ptr: *anyopaque, buf: []u8) []const u8 {
    const p: *usize = @ptrCast(@alignCast(ptr));
    return std.fmt.bufPrint(buf, "{d}", .{p.*}) catch buf[0..0];
}
pub fn hashUsize(ptr: *anyopaque) u64 {
    const p: *usize = @ptrCast(@alignCast(ptr));
    return @as(u64, p.*);
}

// ── f16 ──
pub fn readF16(ptr: *anyopaque) value.Value {
    const p: *f16 = @ptrCast(@alignCast(ptr));
    return value.Value{ .f16 = @bitCast(p.*) };
}
pub fn writeF16(ptr: *anyopaque, v: value.Value) void {
    const p: *f16 = @ptrCast(@alignCast(ptr));
    p.* = @bitCast(v.f16);
}
pub fn eqF16(a: *anyopaque, b: *anyopaque) bool {
    const pa: *f16 = @ptrCast(@alignCast(a));
    const pb: *f16 = @ptrCast(@alignCast(b));
    return pa.* == pb.*;
}
pub fn fmtF16(ptr: *anyopaque, buf: []u8) []const u8 {
    const p: *f16 = @ptrCast(@alignCast(ptr));
    return std.fmt.bufPrint(buf, "{d}", .{p.*}) catch buf[0..0];
}
pub fn hashF16(ptr: *anyopaque) u64 {
    const p: *f16 = @ptrCast(@alignCast(ptr));
    const bits: u16 = @bitCast(p.*);
    return @as(u64, bits);
}

// ── f32 ──
pub fn readF32(ptr: *anyopaque) value.Value {
    const p: *f32 = @ptrCast(@alignCast(ptr));
    return value.Value{ .f32 = @bitCast(p.*) };
}
pub fn writeF32(ptr: *anyopaque, v: value.Value) void {
    const p: *f32 = @ptrCast(@alignCast(ptr));
    p.* = @bitCast(v.f32);
}
pub fn eqF32(a: *anyopaque, b: *anyopaque) bool {
    const pa: *f32 = @ptrCast(@alignCast(a));
    const pb: *f32 = @ptrCast(@alignCast(b));
    return pa.* == pb.*;
}
pub fn fmtF32(ptr: *anyopaque, buf: []u8) []const u8 {
    const p: *f32 = @ptrCast(@alignCast(ptr));
    return std.fmt.bufPrint(buf, "{d}", .{p.*}) catch buf[0..0];
}
pub fn hashF32(ptr: *anyopaque) u64 {
    const p: *f32 = @ptrCast(@alignCast(ptr));
    const bits: u32 = @bitCast(p.*);
    return @as(u64, bits);
}

// ── f64 ──
pub fn readF64(ptr: *anyopaque) value.Value {
    const p: *f64 = @ptrCast(@alignCast(ptr));
    return value.Value{ .f64 = @bitCast(p.*) };
}
pub fn writeF64(ptr: *anyopaque, v: value.Value) void {
    const p: *f64 = @ptrCast(@alignCast(ptr));
    p.* = @bitCast(v.f64);
}
pub fn eqF64(a: *anyopaque, b: *anyopaque) bool {
    const pa: *f64 = @ptrCast(@alignCast(a));
    const pb: *f64 = @ptrCast(@alignCast(b));
    return pa.* == pb.*;
}
pub fn fmtF64(ptr: *anyopaque, buf: []u8) []const u8 {
    const p: *f64 = @ptrCast(@alignCast(ptr));
    return std.fmt.bufPrint(buf, "{d}", .{p.*}) catch buf[0..0];
}
pub fn hashF64(ptr: *anyopaque) u64 {
    const p: *f64 = @ptrCast(@alignCast(ptr));
    return @as(u64, @bitCast(p.*));
}

// ── f128 ──
pub fn readF128(ptr: *anyopaque) value.Value {
    const p: *[16]u8 = @ptrCast(@alignCast(ptr));
    return value.Value{ .f128 = p.* };
}
pub fn writeF128(ptr: *anyopaque, v: value.Value) void {
    const p: *[16]u8 = @ptrCast(@alignCast(ptr));
    p.* = v.f128;
}
pub fn eqF128(a: *anyopaque, b: *anyopaque) bool {
    const pa: *[16]u8 = @ptrCast(@alignCast(a));
    const pb: *[16]u8 = @ptrCast(@alignCast(b));
    return std.mem.eql(u8, pa, pb);
}
pub fn fmtF128(ptr: *anyopaque, buf: []u8) []const u8 {
    const p: *[16]u8 = @ptrCast(@alignCast(ptr));
    const v: f128 = @bitCast(p.*);
    return std.fmt.bufPrint(buf, "{d}", .{v}) catch buf[0..0];
}
pub fn hashF128(ptr: *anyopaque) u64 {
    const p: *[16]u8 = @ptrCast(@alignCast(ptr));
    var h: u64 = 0xcbf29ce484222325;
    for (p.*) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

// ── bool (Value.boolean 是 [1]u8) ──
pub fn readBool(ptr: *anyopaque) value.Value {
    const p: *bool = @ptrCast(@alignCast(ptr));
    return value.Value{ .boolean = .{@intFromBool(p.*)} };
}
pub fn writeBool(ptr: *anyopaque, v: value.Value) void {
    const p: *bool = @ptrCast(@alignCast(ptr));
    p.* = v.boolean[0] != 0;
}
pub fn eqBool(a: *anyopaque, b: *anyopaque) bool {
    const pa: *bool = @ptrCast(@alignCast(a));
    const pb: *bool = @ptrCast(@alignCast(b));
    return pa.* == pb.*;
}
pub fn fmtBool(ptr: *anyopaque, buf: []u8) []const u8 {
    const p: *bool = @ptrCast(@alignCast(ptr));
    return std.fmt.bufPrint(buf, "{s}", .{if (p.*) "true" else "false"}) catch buf[0..0];
}
pub fn hashBool(ptr: *anyopaque) u64 {
    const p: *bool = @ptrCast(@alignCast(ptr));
    return if (p.*) 1 else 0;
}

// ── char (Value.char 是 [4]u8，存储为 *u32) ──
pub fn readChar(ptr: *anyopaque) value.Value {
    const p: *u32 = @ptrCast(@alignCast(ptr));
    return value.Value{ .char = @bitCast(p.*) };
}
pub fn writeChar(ptr: *anyopaque, v: value.Value) void {
    const p: *u32 = @ptrCast(@alignCast(ptr));
    p.* = @bitCast(v.char);
}
pub fn eqChar(a: *anyopaque, b: *anyopaque) bool {
    const pa: *u32 = @ptrCast(@alignCast(a));
    const pb: *u32 = @ptrCast(@alignCast(b));
    return pa.* == pb.*;
}
pub fn fmtChar(ptr: *anyopaque, buf: []u8) []const u8 {
    const p: *u32 = @ptrCast(@alignCast(ptr));
    return std.fmt.bufPrint(buf, "{u}", .{@as(u21, @intCast(p.*))}) catch buf[0..0];
}
pub fn hashChar(ptr: *anyopaque) u64 {
    const p: *u32 = @ptrCast(@alignCast(ptr));
    return @as(u64, p.*);
}

// ════════════════════════════════════════════════════════════
// clone 函数：克隆本通道的值
// ════════════════════════════════════════════════════════════
// 标量类型 clone = read（值语义，直接返回值，忽略 allocator）。
// 深拷贝决策内嵌到 ops，替代基于 is_ref 的运行时分支。

// ── 整数 clone ──
pub fn cloneI8(ptr: *anyopaque, allocator: std.mem.Allocator) value.Value {
    _ = allocator;
    return readI8(ptr);
}
pub fn cloneU8(ptr: *anyopaque, allocator: std.mem.Allocator) value.Value {
    _ = allocator;
    return readU8(ptr);
}
pub fn cloneI16(ptr: *anyopaque, allocator: std.mem.Allocator) value.Value {
    _ = allocator;
    return readI16(ptr);
}
pub fn cloneU16(ptr: *anyopaque, allocator: std.mem.Allocator) value.Value {
    _ = allocator;
    return readU16(ptr);
}
pub fn cloneI32(ptr: *anyopaque, allocator: std.mem.Allocator) value.Value {
    _ = allocator;
    return readI32(ptr);
}
pub fn cloneU32(ptr: *anyopaque, allocator: std.mem.Allocator) value.Value {
    _ = allocator;
    return readU32(ptr);
}
pub fn cloneI64(ptr: *anyopaque, allocator: std.mem.Allocator) value.Value {
    _ = allocator;
    return readI64(ptr);
}
pub fn cloneU64(ptr: *anyopaque, allocator: std.mem.Allocator) value.Value {
    _ = allocator;
    return readU64(ptr);
}
pub fn cloneI128(ptr: *anyopaque, allocator: std.mem.Allocator) value.Value {
    _ = allocator;
    return readI128(ptr);
}
pub fn cloneU128(ptr: *anyopaque, allocator: std.mem.Allocator) value.Value {
    _ = allocator;
    return readU128(ptr);
}
pub fn cloneIsize(ptr: *anyopaque, allocator: std.mem.Allocator) value.Value {
    _ = allocator;
    return readIsize(ptr);
}
pub fn cloneUsize(ptr: *anyopaque, allocator: std.mem.Allocator) value.Value {
    _ = allocator;
    return readUsize(ptr);
}

// ── 浮点 clone ──
pub fn cloneF16(ptr: *anyopaque, allocator: std.mem.Allocator) value.Value {
    _ = allocator;
    return readF16(ptr);
}
pub fn cloneF32(ptr: *anyopaque, allocator: std.mem.Allocator) value.Value {
    _ = allocator;
    return readF32(ptr);
}
pub fn cloneF64(ptr: *anyopaque, allocator: std.mem.Allocator) value.Value {
    _ = allocator;
    return readF64(ptr);
}
pub fn cloneF128(ptr: *anyopaque, allocator: std.mem.Allocator) value.Value {
    _ = allocator;
    return readF128(ptr);
}

// ── bool / char clone ──
pub fn cloneBool(ptr: *anyopaque, allocator: std.mem.Allocator) value.Value {
    _ = allocator;
    return readBool(ptr);
}
pub fn cloneChar(ptr: *anyopaque, allocator: std.mem.Allocator) value.Value {
    _ = allocator;
    return readChar(ptr);
}

// ════════════════════════════════════════════════════════════
// coerce 函数：将任意 Value 转换为本类型的标准 Value
// ════════════════════════════════════════════════════════════
// 用于 writeChannel：先将输入 Value coerce 为通道类型匹配的 Value，
// 再调用 write 写入。消除 engine 侧 writeScalarValue/valueToChan 的大 switch。
// 转换语义与原 writeScalarValue 完全一致（整数截断/扩展、浮点提升/降精度等）。

// ── 整数 coerce：统一先转为 i64，再截断为目标宽度 ──

pub fn coerceI8(v: value.Value) value.Value {
    const val: i8 = switch (v) {
        .i8 => |b| @bitCast(b[0]),
        .u8 => |b| @bitCast(b[0]),
        .i16 => |b| @truncate(@as(i16, @bitCast(b))),
        .u16 => |b| @bitCast(@as(u8, @truncate(@as(u16, @bitCast(b))))),
        .i32 => |b| @truncate(@as(i32, @bitCast(b))),
        .u32 => |b| @bitCast(@as(u8, @truncate(@as(u32, @bitCast(b))))),
        .i64 => |b| @truncate(@as(i64, @bitCast(b))),
        .u64 => |b| @bitCast(@as(u8, @truncate(@as(u64, @bitCast(b))))),
        .i128 => |b| @truncate(@as(i128, @bitCast(b))),
        .u128 => |b| @bitCast(@as(u8, @truncate(@as(u128, @bitCast(b))))),
        .isize => |b| @truncate(@as(isize, @bitCast(b))),
        .usize => |b| @bitCast(@as(u8, @truncate(@as(usize, @bitCast(b))))),
        .boolean => |b| @intFromBool(b[0] != 0),
        .null_val, .unit => 0,
        .ref => |r| @bitCast(@as(u8, @truncate(@intFromPtr(r)))),
        .f32 => |b| @intFromFloat(@as(f32, @bitCast(b))),
        .f64 => |b| @intFromFloat(@as(f64, @bitCast(b))),
        .f16 => |b| @intFromFloat(@as(f16, @bitCast(b))),
        .f128 => |b| @intFromFloat(@as(f128, @bitCast(b))),
        .char => |b| @bitCast(@as(u8, @truncate(@as(u32, @bitCast(b))))),
    };
    return .{ .i8 = .{@bitCast(val)} };
}

pub fn coerceU8(v: value.Value) value.Value {
    const val: u8 = switch (v) {
        .i8 => |b| @truncate(@as(u8, @bitCast(b[0]))),
        .u8 => |b| b[0],
        .i16 => |b| @truncate(@as(u16, @bitCast(b))),
        .u16 => |b| @truncate(@as(u16, @bitCast(b))),
        .i32 => |b| @truncate(@as(u32, @bitCast(b))),
        .u32 => |b| @truncate(@as(u32, @bitCast(b))),
        .i64 => |b| @truncate(@as(u64, @bitCast(b))),
        .u64 => |b| @truncate(@as(u64, @bitCast(b))),
        .i128 => |b| @bitCast(@as(u8, @truncate(@as(u128, @bitCast(@as(i128, @bitCast(b))))))),
        .u128 => |b| @truncate(@as(u128, @bitCast(b))),
        .usize => |b| @truncate(@as(usize, @bitCast(b))),
        .isize => |b| @truncate(@as(usize, @bitCast(@as(isize, @bitCast(b))))),
        .boolean => |b| b[0],
        .f32 => |b| @intFromFloat(@as(f32, @bitCast(b))),
        .f64 => |b| @intFromFloat(@as(f64, @bitCast(b))),
        .f16 => |b| @intFromFloat(@as(f16, @bitCast(b))),
        .f128 => |b| @intFromFloat(@as(f128, @bitCast(b))),
        else => 0,
    };
    return .{ .u8 = .{val} };
}

pub fn coerceI16(v: value.Value) value.Value {
    const val: i16 = switch (v) {
        .i16 => |b| @bitCast(b),
        .i32 => |b| @truncate(@as(i32, @bitCast(b))),
        .i64 => |b| @truncate(@as(i64, @bitCast(b))),
        .u16 => |b| @bitCast(@as(u16, @bitCast(b))),
        .u32 => |b| @truncate(@as(i32, @bitCast(@as(u32, @bitCast(b))))),
        .u64 => |b| @truncate(@as(i64, @bitCast(@as(u64, @bitCast(b))))),
        .i128 => |b| @truncate(@as(i128, @bitCast(b))),
        .u128 => |b| @bitCast(@as(u16, @truncate(@as(u128, @bitCast(b))))),
        .usize => |b| @truncate(@as(i64, @bitCast(@as(usize, @bitCast(b))))),
        .isize => |b| @truncate(@as(i64, @as(isize, @bitCast(b)))),
        .u8 => |b| @as(i16, b[0]),
        .i8 => |b| @as(i16, @as(i8, @bitCast(b[0]))),
        .boolean => |b| @intFromBool(b[0] != 0),
        .f32 => |b| @intFromFloat(@as(f32, @bitCast(b))),
        .f64 => |b| @intFromFloat(@as(f64, @bitCast(b))),
        .f16 => |b| @intFromFloat(@as(f16, @bitCast(b))),
        .f128 => |b| @intFromFloat(@as(f128, @bitCast(b))),
        else => 0,
    };
    return .{ .i16 = @bitCast(val) };
}

pub fn coerceU16(v: value.Value) value.Value {
    const val: u16 = switch (v) {
        .u16 => |b| @bitCast(b),
        .i16 => |b| @bitCast(@as(i16, @bitCast(b))),
        .i32 => |b| @truncate(@as(u32, @bitCast(b))),
        .u32 => |b| @truncate(@as(u32, @bitCast(b))),
        .i64 => |b| @truncate(@as(u64, @bitCast(b))),
        .u64 => |b| @truncate(@as(u64, @bitCast(b))),
        .i128 => |b| @truncate(@as(u128, @bitCast(@as(i128, @bitCast(b))))),
        .u128 => |b| @truncate(@as(u128, @bitCast(b))),
        .usize => |b| @truncate(@as(usize, @bitCast(b))),
        .isize => |b| @truncate(@as(usize, @bitCast(@as(isize, @bitCast(b))))),
        .u8 => |b| @as(u16, b[0]),
        .i8 => |b| @as(u16, @as(u8, @bitCast(b[0]))),
        .boolean => |b| @intFromBool(b[0] != 0),
        .f32 => |b| @intFromFloat(@as(f32, @bitCast(b))),
        .f64 => |b| @intFromFloat(@as(f64, @bitCast(b))),
        .f16 => |b| @intFromFloat(@as(f16, @bitCast(b))),
        .f128 => |b| @intFromFloat(@as(f128, @bitCast(b))),
        else => 0,
    };
    return .{ .u16 = @bitCast(val) };
}

pub fn coerceI32(v: value.Value) value.Value {
    const val: i32 = switch (v) {
        .i32 => |b| @bitCast(b),
        .i64 => |b| @truncate(@as(i64, @bitCast(b))),
        .i16 => |b| @as(i32, @as(i16, @bitCast(b))),
        .i8 => |b| @as(i32, @as(i8, @bitCast(b[0]))),
        .u32 => |b| @bitCast(@as(u32, @bitCast(b))),
        .u16 => |b| @as(i32, @as(u16, @bitCast(b))),
        .u8 => |b| @as(i32, b[0]),
        .u64 => |b| @truncate(@as(i64, @bitCast(@as(u64, @bitCast(b))))),
        .i128 => |b| @truncate(@as(i128, @bitCast(b))),
        .u128 => |b| @bitCast(@as(u32, @truncate(@as(u128, @bitCast(b))))),
        .usize => |b| @truncate(@as(i64, @bitCast(@as(usize, @bitCast(b))))),
        .isize => |b| @truncate(@as(i64, @as(isize, @bitCast(b)))),
        .boolean => |b| @intFromBool(b[0] != 0),
        .null_val, .unit => 0,
        .f32 => |b| @intFromFloat(@as(f32, @bitCast(b))),
        .f64 => |b| @intFromFloat(@as(f64, @bitCast(b))),
        .f16 => |b| @intFromFloat(@as(f16, @bitCast(b))),
        .f128 => |b| @intFromFloat(@as(f128, @bitCast(b))),
        else => 0,
    };
    return .{ .i32 = @bitCast(val) };
}

pub fn coerceU32(v: value.Value) value.Value {
    const val: u32 = switch (v) {
        .u32 => |b| @bitCast(b),
        .i32 => |b| @bitCast(@as(i32, @bitCast(b))),
        .i64 => |b| @truncate(@as(u64, @bitCast(b))),
        .u64 => |b| @truncate(@as(u64, @bitCast(b))),
        .i16 => |b| @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(b))))),
        .u16 => |b| @as(u32, @as(u16, @bitCast(b))),
        .i8 => |b| @as(u32, @bitCast(@as(i32, @as(i8, @bitCast(b[0]))))),
        .u8 => |b| @as(u32, b[0]),
        .i128 => |b| @truncate(@as(u128, @bitCast(@as(i128, @bitCast(b))))),
        .u128 => |b| @truncate(@as(u128, @bitCast(b))),
        .usize => |b| @truncate(@as(usize, @bitCast(b))),
        .isize => |b| @truncate(@as(usize, @bitCast(@as(isize, @bitCast(b))))),
        .boolean => |b| @intFromBool(b[0] != 0),
        .null_val, .unit => 0,
        .f32 => |b| @intFromFloat(@as(f32, @bitCast(b))),
        .f64 => |b| @intFromFloat(@as(f64, @bitCast(b))),
        .f16 => |b| @intFromFloat(@as(f16, @bitCast(b))),
        .f128 => |b| @intFromFloat(@as(f128, @bitCast(b))),
        else => 0,
    };
    return .{ .u32 = @bitCast(val) };
}

pub fn coerceI64(v: value.Value) value.Value {
    const val: i64 = switch (v) {
        .i64 => |b| @bitCast(b),
        .i32 => |b| @as(i64, @as(i32, @bitCast(b))),
        .i16 => |b| @as(i64, @as(i16, @bitCast(b))),
        .i8 => |b| @as(i64, @as(i8, @bitCast(b[0]))),
        .u64 => |b| @bitCast(@as(u64, @bitCast(b))),
        .u32 => |b| @as(i64, @as(u32, @bitCast(b))),
        .u16 => |b| @as(i64, @as(u16, @bitCast(b))),
        .u8 => |b| @as(i64, b[0]),
        .i128 => |b| @truncate(@as(i128, @bitCast(b))),
        .u128 => |b| @bitCast(@as(u64, @truncate(@as(u128, @bitCast(b))))),
        .isize => |b| @as(i64, @as(isize, @bitCast(b))),
        .usize => |b| @bitCast(@as(usize, @bitCast(b))),
        .boolean => |b| @intFromBool(b[0] != 0),
        .null_val, .unit => 0,
        .ref => |r| @intCast(@intFromPtr(r)),
        .f32 => |b| @intFromFloat(@as(f32, @bitCast(b))),
        .f64 => |b| @intFromFloat(@as(f64, @bitCast(b))),
        .f16 => |b| @intFromFloat(@as(f16, @bitCast(b))),
        .f128 => |b| @intFromFloat(@as(f128, @bitCast(b))),
        else => 0,
    };
    return .{ .i64 = @bitCast(val) };
}

pub fn coerceU64(v: value.Value) value.Value {
    const val: u64 = switch (v) {
        .u64 => |b| @bitCast(b),
        .i64 => |b| @bitCast(@as(i64, @bitCast(b))),
        .i32 => |b| @as(u64, @bitCast(@as(i64, @as(i32, @bitCast(b))))),
        .u32 => |b| @as(u64, @as(u32, @bitCast(b))),
        .i16 => |b| @as(u64, @bitCast(@as(i64, @as(i16, @bitCast(b))))),
        .u16 => |b| @as(u64, @as(u16, @bitCast(b))),
        .i8 => |b| @as(u64, @bitCast(@as(i64, @as(i8, @bitCast(b[0]))))),
        .u8 => |b| @as(u64, b[0]),
        .i128 => |b| @bitCast(@as(u64, @truncate(@as(u128, @bitCast(@as(i128, @bitCast(b))))))),
        .u128 => |b| @truncate(@as(u128, @bitCast(b))),
        .isize => |b| @bitCast(@as(isize, @bitCast(b))),
        .usize => |b| @as(u64, @as(usize, @bitCast(b))),
        .boolean => |b| @intFromBool(b[0] != 0),
        .null_val, .unit => 0,
        .ref => |r| @intCast(@intFromPtr(r)),
        .f32 => |b| @intFromFloat(@as(f32, @bitCast(b))),
        .f64 => |b| @intFromFloat(@as(f64, @bitCast(b))),
        .f16 => |b| @intFromFloat(@as(f16, @bitCast(b))),
        .f128 => |b| @intFromFloat(@as(f128, @bitCast(b))),
        else => 0,
    };
    return .{ .u64 = @bitCast(val) };
}

pub fn coerceI128(v: value.Value) value.Value {
    // i128/u128 通道：按 16 字节原样拷贝标量位模式
    const val: i128 = switch (v) {
        .i128 => |b| @bitCast(b),
        .u128 => |b| @bitCast(@as(u128, @bitCast(b))),
        .i64 => |b| @as(i128, @as(i64, @bitCast(b))),
        .u64 => |b| @as(i128, @as(i64, @bitCast(@as(u64, @bitCast(b))))),
        .i32 => |b| @as(i128, @as(i32, @bitCast(b))),
        .u32 => |b| @as(i128, @as(u32, @bitCast(b))),
        .i16 => |b| @as(i128, @as(i16, @bitCast(b))),
        .u16 => |b| @as(i128, @as(u16, @bitCast(b))),
        .i8 => |b| @as(i128, @as(i8, @bitCast(b[0]))),
        .u8 => |b| @as(i128, b[0]),
        .isize => |b| @as(i128, @as(isize, @bitCast(b))),
        .usize => |b| @as(i128, @as(isize, @bitCast(@as(usize, @bitCast(b))))),
        .boolean => |b| @intFromBool(b[0] != 0),
        .null_val, .unit => 0,
        .f32 => |b| @intFromFloat(@as(f32, @bitCast(b))),
        .f64 => |b| @intFromFloat(@as(f64, @bitCast(b))),
        .f16 => |b| @intFromFloat(@as(f16, @bitCast(b))),
        .f128 => |b| @intFromFloat(@as(f128, @bitCast(b))),
        else => 0,
    };
    return .{ .i128 = @bitCast(val) };
}

pub fn coerceU128(v: value.Value) value.Value {
    const val: u128 = switch (v) {
        .u128 => |b| @bitCast(b),
        .i128 => |b| @bitCast(@as(i128, @bitCast(b))),
        .i64 => |b| @as(u128, @as(u64, @bitCast(@as(i64, @bitCast(b))))),
        .u64 => |b| @as(u128, @as(u64, @bitCast(b))),
        .i32 => |b| @as(u128, @as(u64, @bitCast(@as(i64, @as(i32, @bitCast(b)))))),
        .u32 => |b| @as(u128, @as(u32, @bitCast(b))),
        .i16 => |b| @as(u128, @as(u64, @bitCast(@as(i64, @as(i16, @bitCast(b)))))),
        .u16 => |b| @as(u128, @as(u16, @bitCast(b))),
        .i8 => |b| @as(u128, @as(u64, @bitCast(@as(i64, @as(i8, @bitCast(b[0])))))),
        .u8 => |b| @as(u128, b[0]),
        .isize => |b| @as(u128, @as(u64, @bitCast(@as(isize, @bitCast(b))))),
        .usize => |b| @as(u128, @as(usize, @bitCast(b))),
        .boolean => |b| @intFromBool(b[0] != 0),
        .null_val, .unit => 0,
        .f32 => |b| @intFromFloat(@as(f32, @bitCast(b))),
        .f64 => |b| @intFromFloat(@as(f64, @bitCast(b))),
        .f16 => |b| @intFromFloat(@as(f16, @bitCast(b))),
        .f128 => |b| @intFromFloat(@as(f128, @bitCast(b))),
        else => 0,
    };
    return .{ .u128 = @bitCast(val) };
}

pub fn coerceIsize(v: value.Value) value.Value {
    const val: isize = switch (v) {
        .isize => |b| @bitCast(b),
        .usize => |b| @bitCast(@as(usize, @bitCast(b))),
        .i64 => |b| @intCast(@as(i64, @bitCast(b))),
        .u64 => |b| @intCast(@as(u64, @bitCast(b))),
        .i32 => |b| @as(isize, @as(i32, @bitCast(b))),
        .u32 => |b| @as(isize, @as(u32, @bitCast(b))),
        .i16 => |b| @as(isize, @as(i16, @bitCast(b))),
        .u16 => |b| @as(isize, @as(u16, @bitCast(b))),
        .i8 => |b| @as(isize, @as(i8, @bitCast(b[0]))),
        .u8 => |b| @as(isize, b[0]),
        .i128 => |b| @intCast(@as(i128, @bitCast(b))),
        .u128 => |b| @intCast(@as(u128, @bitCast(b))),
        .boolean => |b| @intFromBool(b[0] != 0),
        .null_val, .unit => 0,
        .ref => |r| @intCast(@intFromPtr(r)),
        .f32 => |b| @intFromFloat(@as(f32, @bitCast(b))),
        .f64 => |b| @intFromFloat(@as(f64, @bitCast(b))),
        .f16 => |b| @intFromFloat(@as(f16, @bitCast(b))),
        .f128 => |b| @intFromFloat(@as(f128, @bitCast(b))),
        else => 0,
    };
    return .{ .isize = @bitCast(val) };
}

pub fn coerceUsize(v: value.Value) value.Value {
    const val: usize = switch (v) {
        .usize => |b| @bitCast(b),
        .isize => |b| @bitCast(@as(isize, @bitCast(b))),
        .i64 => |b| @intCast(@as(i64, @bitCast(b))),
        .u64 => |b| @intCast(@as(u64, @bitCast(b))),
        .i32 => |b| @as(usize, @bitCast(@as(isize, @as(i32, @bitCast(b))))),
        .u32 => |b| @as(usize, @as(u32, @bitCast(b))),
        .i16 => |b| @as(usize, @bitCast(@as(isize, @as(i16, @bitCast(b))))),
        .u16 => |b| @as(usize, @as(u16, @bitCast(b))),
        .i8 => |b| @as(usize, @bitCast(@as(isize, @as(i8, @bitCast(b[0]))))),
        .u8 => |b| @as(usize, b[0]),
        .i128 => |b| @intCast(@as(i128, @bitCast(b))),
        .u128 => |b| @intCast(@as(u128, @bitCast(b))),
        .boolean => |b| @intFromBool(b[0] != 0),
        .null_val, .unit => 0,
        .ref => |r| @intCast(@intFromPtr(r)),
        .f32 => |b| @intFromFloat(@as(f32, @bitCast(b))),
        .f64 => |b| @intFromFloat(@as(f64, @bitCast(b))),
        .f16 => |b| @intFromFloat(@as(f16, @bitCast(b))),
        .f128 => |b| @intFromFloat(@as(f128, @bitCast(b))),
        else => 0,
    };
    return .{ .usize = @bitCast(val) };
}

// ── 浮点 coerce：统一先转为 f64/f128，再降精度为目标宽度 ──

pub fn coerceF16(v: value.Value) value.Value {
    const val: f16 = switch (v) {
        .f16 => |b| @bitCast(b),
        .f32 => |b| @floatCast(@as(f32, @bitCast(b))),
        .f64 => |b| @floatCast(@as(f64, @bitCast(b))),
        .f128 => |b| @floatCast(@as(f128, @bitCast(b))),
        .i8 => |b| @floatFromInt(@as(i8, @bitCast(b[0]))),
        .i16 => |b| @floatFromInt(@as(i16, @bitCast(b))),
        .i32 => |b| @floatFromInt(@as(i32, @bitCast(b))),
        .i64 => |b| @floatFromInt(@as(i64, @bitCast(b))),
        .i128 => |b| @floatFromInt(@as(i128, @bitCast(b))),
        .u8 => |b| @floatFromInt(b[0]),
        .u16 => |b| @floatFromInt(@as(u16, @bitCast(b))),
        .u32 => |b| @floatFromInt(@as(u32, @bitCast(b))),
        .u64 => |b| @floatFromInt(@as(u64, @bitCast(b))),
        .u128 => |b| @floatFromInt(@as(u128, @bitCast(b))),
        .boolean => |b| @floatFromInt(@intFromBool(b[0] != 0)),
        else => 0,
    };
    return .{ .f16 = @bitCast(val) };
}

pub fn coerceF32(v: value.Value) value.Value {
    const val: f32 = switch (v) {
        .f32 => |b| @bitCast(b),
        .f64 => |b| @floatCast(@as(f64, @bitCast(b))),
        .f16 => |b| @floatCast(@as(f16, @bitCast(b))),
        .f128 => |b| @floatCast(@as(f128, @bitCast(b))),
        .i8 => |b| @floatFromInt(@as(i8, @bitCast(b[0]))),
        .i16 => |b| @floatFromInt(@as(i16, @bitCast(b))),
        .i32 => |b| @floatFromInt(@as(i32, @bitCast(b))),
        .i64 => |b| @floatFromInt(@as(i64, @bitCast(b))),
        .i128 => |b| @floatFromInt(@as(i128, @bitCast(b))),
        .u8 => |b| @floatFromInt(b[0]),
        .u16 => |b| @floatFromInt(@as(u16, @bitCast(b))),
        .u32 => |b| @floatFromInt(@as(u32, @bitCast(b))),
        .u64 => |b| @floatFromInt(@as(u64, @bitCast(b))),
        .u128 => |b| @floatFromInt(@as(u128, @bitCast(b))),
        .boolean => |b| @floatFromInt(@intFromBool(b[0] != 0)),
        else => 0,
    };
    return .{ .f32 = @bitCast(val) };
}

pub fn coerceF64(v: value.Value) value.Value {
    const val: f64 = switch (v) {
        .f64 => |b| @bitCast(b),
        .f32 => |b| @floatCast(@as(f32, @bitCast(b))),
        .f16 => |b| @floatCast(@as(f16, @bitCast(b))),
        .f128 => |b| @floatCast(@as(f128, @bitCast(b))),
        .i8 => |b| @floatFromInt(@as(i8, @bitCast(b[0]))),
        .i16 => |b| @floatFromInt(@as(i16, @bitCast(b))),
        .i32 => |b| @floatFromInt(@as(i32, @bitCast(b))),
        .i64 => |b| @floatFromInt(@as(i64, @bitCast(b))),
        .i128 => |b| @floatFromInt(@as(i128, @bitCast(b))),
        .u8 => |b| @floatFromInt(b[0]),
        .u16 => |b| @floatFromInt(@as(u16, @bitCast(b))),
        .u32 => |b| @floatFromInt(@as(u32, @bitCast(b))),
        .u64 => |b| @floatFromInt(@as(u64, @bitCast(b))),
        .u128 => |b| @floatFromInt(@as(u128, @bitCast(b))),
        .boolean => |b| @floatFromInt(@intFromBool(b[0] != 0)),
        else => 0,
    };
    return .{ .f64 = @bitCast(val) };
}

pub fn coerceF128(v: value.Value) value.Value {
    const val: f128 = switch (v) {
        .f128 => |b| @bitCast(b),
        .f16 => |b| @floatCast(@as(f16, @bitCast(b))),
        .f32 => |b| @floatCast(@as(f32, @bitCast(b))),
        .f64 => |b| @floatCast(@as(f64, @bitCast(b))),
        .i8 => |b| @floatFromInt(@as(i8, @bitCast(b[0]))),
        .i16 => |b| @floatFromInt(@as(i16, @bitCast(b))),
        .i32 => |b| @floatFromInt(@as(i32, @bitCast(b))),
        .i64 => |b| @floatFromInt(@as(i64, @bitCast(b))),
        .i128 => |b| @floatFromInt(@as(i128, @bitCast(b))),
        .u8 => |b| @floatFromInt(b[0]),
        .u16 => |b| @floatFromInt(@as(u16, @bitCast(b))),
        .u32 => |b| @floatFromInt(@as(u32, @bitCast(b))),
        .u64 => |b| @floatFromInt(@as(u64, @bitCast(b))),
        .u128 => |b| @floatFromInt(@as(u128, @bitCast(b))),
        .boolean => |b| @floatFromInt(@intFromBool(b[0] != 0)),
        else => 0,
    };
    return .{ .f128 = @bitCast(val) };
}

// ── bool / char coerce ──

pub fn coerceBool(v: value.Value) value.Value {
    const val: bool = switch (v) {
        .boolean => |b| b[0] != 0,
        .i64 => |b| @as(i64, @bitCast(b)) != 0,
        .i32 => |b| @as(i32, @bitCast(b)) != 0,
        .u64 => |b| @as(u64, @bitCast(b)) != 0,
        .u32 => |b| @as(u32, @bitCast(b)) != 0,
        .i8 => |b| @as(i8, @bitCast(b[0])) != 0,
        .u8 => |b| b[0] != 0,
        .i16 => |b| @as(i16, @bitCast(b)) != 0,
        .u16 => |b| @as(u16, @bitCast(b)) != 0,
        .i128 => |b| @as(i128, @bitCast(b)) != 0,
        .u128 => |b| @as(u128, @bitCast(b)) != 0,
        .isize => |b| @as(isize, @bitCast(b)) != 0,
        .usize => |b| @as(usize, @bitCast(b)) != 0,
        .f32 => |b| @as(f32, @bitCast(b)) != 0,
        .f64 => |b| @as(f64, @bitCast(b)) != 0,
        .f16 => |b| @as(f16, @bitCast(b)) != 0,
        .f128 => |b| @as(f128, @bitCast(b)) != 0,
        .null_val, .unit => false,
        .ref => true,
        else => false,
    };
    return .{ .boolean = .{@intFromBool(val)} };
}

pub fn coerceChar(v: value.Value) value.Value {
    const val: u32 = switch (v) {
        .char => |b| @bitCast(b),
        .i32 => |b| @bitCast(@as(i32, @bitCast(b))),
        .u32 => |b| @bitCast(b),
        .i64 => |b| @truncate(@as(u64, @bitCast(b))),
        .u64 => |b| @truncate(@as(u64, @bitCast(b))),
        .i16 => |b| @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(b))))),
        .u16 => |b| @as(u32, @as(u16, @bitCast(b))),
        .i8 => |b| @as(u32, @bitCast(@as(i32, @as(i8, @bitCast(b[0]))))),
        .u8 => |b| @as(u32, b[0]),
        .boolean => |b| @intFromBool(b[0] != 0),
        else => 0,
    };
    return .{ .char = @bitCast(val) };
}

// ════════════════════════════════════════════════════════════
// 标量 TypeOps 常量（每个标量类型一个，供静态 TypeDescriptor 引用）
// ════════════════════════════════════════════════════════════

pub const i8_ops: TypeOps = .{ .read = readI8, .write = writeI8, .coerce = coerceI8, .equal = eqI8, .format = fmtI8, .hash = hashI8, .clone = cloneI8 };
pub const u8_ops: TypeOps = .{ .read = readU8, .write = writeU8, .coerce = coerceU8, .equal = eqU8, .format = fmtU8, .hash = hashU8, .clone = cloneU8 };
pub const i16_ops: TypeOps = .{ .read = readI16, .write = writeI16, .coerce = coerceI16, .equal = eqI16, .format = fmtI16, .hash = hashI16, .clone = cloneI16 };
pub const u16_ops: TypeOps = .{ .read = readU16, .write = writeU16, .coerce = coerceU16, .equal = eqU16, .format = fmtU16, .hash = hashU16, .clone = cloneU16 };
pub const i32_ops: TypeOps = .{ .read = readI32, .write = writeI32, .coerce = coerceI32, .equal = eqI32, .format = fmtI32, .hash = hashI32, .clone = cloneI32 };
pub const u32_ops: TypeOps = .{ .read = readU32, .write = writeU32, .coerce = coerceU32, .equal = eqU32, .format = fmtU32, .hash = hashU32, .clone = cloneU32 };
pub const i64_ops: TypeOps = .{ .read = readI64, .write = writeI64, .coerce = coerceI64, .equal = eqI64, .format = fmtI64, .hash = hashI64, .clone = cloneI64 };
pub const u64_ops: TypeOps = .{ .read = readU64, .write = writeU64, .coerce = coerceU64, .equal = eqU64, .format = fmtU64, .hash = hashU64, .clone = cloneU64 };
pub const i128_ops: TypeOps = .{ .read = readI128, .write = writeI128, .coerce = coerceI128, .equal = eqI128, .format = fmtI128, .hash = hashI128, .clone = cloneI128 };
pub const u128_ops: TypeOps = .{ .read = readU128, .write = writeU128, .coerce = coerceU128, .equal = eqU128, .format = fmtU128, .hash = hashU128, .clone = cloneU128 };
pub const isize_ops: TypeOps = .{ .read = readIsize, .write = writeIsize, .coerce = coerceIsize, .equal = eqIsize, .format = fmtIsize, .hash = hashIsize, .clone = cloneIsize };
pub const usize_ops: TypeOps = .{ .read = readUsize, .write = writeUsize, .coerce = coerceUsize, .equal = eqUsize, .format = fmtUsize, .hash = hashUsize, .clone = cloneUsize };
pub const f16_ops: TypeOps = .{ .read = readF16, .write = writeF16, .coerce = coerceF16, .equal = eqF16, .format = fmtF16, .hash = hashF16, .clone = cloneF16 };
pub const f32_ops: TypeOps = .{ .read = readF32, .write = writeF32, .coerce = coerceF32, .equal = eqF32, .format = fmtF32, .hash = hashF32, .clone = cloneF32 };
pub const f64_ops: TypeOps = .{ .read = readF64, .write = writeF64, .coerce = coerceF64, .equal = eqF64, .format = fmtF64, .hash = hashF64, .clone = cloneF64 };
pub const f128_ops: TypeOps = .{ .read = readF128, .write = writeF128, .coerce = coerceF128, .equal = eqF128, .format = fmtF128, .hash = hashF128, .clone = cloneF128 };
pub const bool_ops: TypeOps = .{ .read = readBool, .write = writeBool, .coerce = coerceBool, .equal = eqBool, .format = fmtBool, .hash = hashBool, .clone = cloneBool };
pub const char_ops: TypeOps = .{ .read = readChar, .write = writeChar, .coerce = coerceChar, .equal = eqChar, .format = fmtChar, .hash = hashChar, .clone = cloneChar };

// ════════════════════════════════════════════════════════════
// ref_chan TypeOps：统一引用通道的读写路径
// ════════════════════════════════════════════════════════════
// ref_chan 为多态通道，8 字节槽可持有：
//   - 堆对象指针（真实 ref Value）
//   - null（0）
//   - 标量位模式（泛型 T 实例化为标量时，i64 位直接存储）
// readRef 通过 ObjHeader.isValidHeapObj 区分堆指针与标量位模式；
// writeRef 通过 valueToI64Bits 将任意 Value 转为 8 字节位模式写入。
// 废除 tagged scalar ref 机制后，不再有 (chan_idx << 1) | 1 编码。

/// 将任意 Value 转为 i64 位模式（用于 ref_chan 8 字节存储）
/// 整数符号扩展为 i64，浮点按位模式写入（f16/f32 提升为 f64 再转位模式）。
/// ref → 指针地址；null_val/unit → 0；i128/u128/f128 截断到低 64 位（lossy）。
pub fn valueToI64Bits(v: value.Value) i64 {
    return switch (v) {
        .ref => |r| @bitCast(@intFromPtr(r)),
        .null_val, .unit => 0,
        .i8 => |b| @as(i64, @as(i8, @bitCast(b[0]))),
        .u8 => |b| @as(i64, b[0]),
        .i16 => |b| @as(i64, @as(i16, @bitCast(b))),
        .u16 => |b| @as(i64, @as(u16, @bitCast(b))),
        .i32 => |b| @as(i64, @as(i32, @bitCast(b))),
        .u32 => |b| @as(i64, @as(u32, @bitCast(b))),
        .i64 => |b| @bitCast(b),
        .u64 => |b| @bitCast(@as(u64, @bitCast(b))),
        .isize => |b| @as(i64, @as(isize, @bitCast(b))),
        .usize => |b| @bitCast(@as(u64, @as(usize, @bitCast(b)))),
        .boolean => |b| @intFromBool(b[0] != 0),
        .char => |b| @as(i64, @intCast(@as(u32, @bitCast(b)))),
        .f16 => |b| @bitCast(@as(f64, @floatCast(@as(f16, @bitCast(b))))),
        .f32 => |b| @bitCast(@as(f64, @floatCast(@as(f32, @bitCast(b))))),
        .f64 => |b| @bitCast(@as(f64, @bitCast(b))),
        .i128 => |b| @truncate(@as(i128, @bitCast(b))),
        .u128 => |b| @bitCast(@as(u64, @truncate(@as(u128, @bitCast(b))))),
        .f128 => |b| @bitCast(@as(f64, @floatCast(@as(f128, @bitCast(b))))),
    };
}

/// 读取 ref_chan 8 字节为 Value
/// - 有效堆对象：返回 Value.fromRef(header)
/// - null（0）：返回 Value.fromNull()
/// - 标量位模式：返回 Value.fromI64(bits)
pub fn readRef(ptr: *anyopaque) value.Value {
    const p: *?*anyopaque = @ptrCast(@alignCast(ptr));
    if (p.*) |rp| {
        const addr = @intFromPtr(rp);
        // 过滤无效地址：低地址（< 0x1000）和内核空间（高位置 1，含负 i64 符号扩展）
        // 后者防止标量位模式（如 -128i8 → 0xffffffffffffff80）被误判为堆指针
        if (addr >= 0x1000 and addr < 0x8000000000000000 and addr % @alignOf(value.obj_header.ObjHeader) == 0) {
            // 使用 msync 安全检查页面是否映射，避免对标量位模式调用 isValidHeapObj 导致段错误
            if (isReadable(addr)) {
                const header: *value.obj_header.ObjHeader = @ptrCast(@alignCast(rp));
                if (header.isValidHeapObj()) {
                    return value.Value.fromRef(header);
                }
            }
        }
    }
    // null 指针（0）或标量位模式
    const ip: *i64 = @ptrCast(@alignCast(ptr));
    if (ip.* == 0) return value.Value.fromNull();
    return value.Value.fromI64(ip.*);
}

/// 将 Value 写入 ref_chan 8 字节
/// - ref：写指针地址
/// - null_val/unit：写 0
/// - 标量：通过 valueToI64Bits 转为位模式写入
pub fn writeRef(ptr: *anyopaque, v: value.Value) void {
    const ip: *i64 = @ptrCast(@alignCast(ptr));
    ip.* = valueToI64Bits(v);
}

/// ref_chan coerce：identity（writeRef 内部处理类型转换）
pub fn coerceRef(v: value.Value) value.Value {
    return v;
}

pub fn eqRef(a: *anyopaque, b: *anyopaque) bool {
    const pa: *i64 = @ptrCast(@alignCast(a));
    const pb: *i64 = @ptrCast(@alignCast(b));
    return pa.* == pb.*;
}

pub fn fmtRef(ptr: *anyopaque, buf: []u8) []const u8 {
    const p: *?*anyopaque = @ptrCast(@alignCast(ptr));
    if (p.*) |rp| {
        return std.fmt.bufPrint(buf, "ref:{*}", .{rp}) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "ref:null", .{}) catch buf[0..0];
}

pub fn hashRef(ptr: *anyopaque) u64 {
    const p: *i64 = @ptrCast(@alignCast(ptr));
    return @as(u64, @bitCast(p.*));
}

/// ref_chan clone：深拷贝堆对象。
/// 现有 Value.deepCopy 需 *ThreadContext（非 std.mem.Allocator），签名不兼容；
/// 在不修改 engine/value 调用点的前提下，此处暂时返回浅拷贝（readRef），
/// 后续步骤将桥接 allocator 与 ThreadContext 后再实现真正深拷贝。
pub fn cloneRef(ptr: *anyopaque, allocator: std.mem.Allocator) value.Value {
    _ = allocator;
    return readRef(ptr);
}

pub const ref_ops: TypeOps = .{ .read = readRef, .write = writeRef, .coerce = coerceRef, .equal = eqRef, .format = fmtRef, .hash = hashRef, .clone = cloneRef };

// ════════════════════════════════════════════════════════════
// heap_ref_ops：具体引用类型的简化 vtable
// ════════════════════════════════════════════════════════════
// 用于 str/Record/Closure/Array 等具体引用类型（通过 getOrCreateRefDesc 创建）。
// 以及 nullable<ref<T>> 的 inner read。
// 由于 nullable 数据区可能是字节对齐，使用 align(1) 读取。
// 保留 msync/isValidHeapObj 检查以处理单态化回退路径中标量位模式残留。

pub fn readHeapRef(ptr: *anyopaque) value.Value {
    // 使用 align(1) 指针读取，因为 nullable 数据区可能是字节对齐
    const p: *align(1) ?*anyopaque = @ptrCast(ptr);
    if (p.*) |rp| {
        const addr = @intFromPtr(rp);
        if (addr == 0) return value.Value.fromNull();
        // 过滤无效地址：低地址（< 0x1000）和内核空间（高位置 1，含负 i64 符号扩展）
        if (addr < 0x1000 or addr >= 0x8000000000000000) {
            const ip: *align(1) i64 = @ptrCast(ptr);
            return value.Value.fromI64(ip.*);
        }
        // 检查对齐：未对齐地址说明不是合法堆指针
        if (addr % @alignOf(value.obj_header.ObjHeader) != 0) {
            const ip: *align(1) i64 = @ptrCast(ptr);
            return value.Value.fromI64(ip.*);
        }
        // 使用 msync 安全检查页面是否映射，避免对标量位模式调用 isValidHeapObj 导致段错误
        if (!isReadable(addr)) {
            const ip: *align(1) i64 = @ptrCast(ptr);
            return value.Value.fromI64(ip.*);
        }
        const header: *value.obj_header.ObjHeader = @ptrCast(@alignCast(rp));
        if (header.isValidHeapObj()) {
            return value.Value.fromRef(header);
        }
        // 有效对齐但非堆对象：可能是标量位模式
        const ip: *align(1) i64 = @ptrCast(ptr);
        return value.Value.fromI64(ip.*);
    }
    return value.Value.fromNull();
}

pub fn cloneHeapRef(ptr: *anyopaque, allocator: std.mem.Allocator) value.Value {
    _ = allocator;
    return readHeapRef(ptr);
}

pub const heap_ref_ops: TypeOps = .{
    .read = readHeapRef,
    .write = writeRef,
    .coerce = coerceRef,
    .equal = eqRef,
    .format = fmtRef,
    .hash = hashRef,
    .clone = cloneHeapRef,
};

// ════════════════════════════════════════════════════════════
// nullable<T> TypeOps：nullable 通道的专属 vtable
// ════════════════════════════════════════════════════════════
// nullable<T> 内存布局：[data (inner_size bytes) | 1 byte flag]
// flag != 0 表示 null。read/write/coerce/equal/format/hash/clone 均先检查 flag，
// 非 null 时委托给 inner 类型的对应函数。消除 is_nullable 运行时分支。

fn nullableOps(
    comptime inner_size: u8,
    comptime inner_read: *const fn (*anyopaque) value.Value,
    comptime inner_write: *const fn (*anyopaque, value.Value) void,
    comptime inner_coerce: *const fn (value.Value) value.Value,
    comptime inner_equal: *const fn (*anyopaque, *anyopaque) bool,
    comptime inner_format: *const fn (*anyopaque, []u8) []const u8,
    comptime inner_hash: *const fn (*anyopaque) u64,
    comptime inner_clone: *const fn (*anyopaque, std.mem.Allocator) value.Value,
) TypeOps {
    return .{
        .read = struct {
            fn f(ptr: *anyopaque) value.Value {
                const p: [*]u8 = @ptrCast(ptr);
                if (p[inner_size] != 0) return value.Value.fromNull();
                return inner_read(@ptrCast(p));
            }
        }.f,
        .write = struct {
            fn f(ptr: *anyopaque, v: value.Value) void {
                const p: [*]u8 = @ptrCast(ptr);
                switch (v) {
                    .null_val, .unit => p[inner_size] = 1,
                    else => {
                        inner_write(@ptrCast(p), v);
                        p[inner_size] = 0;
                    },
                }
            }
        }.f,
        .coerce = struct {
            fn f(v: value.Value) value.Value {
                switch (v) {
                    .null_val, .unit => return value.Value.fromNull(),
                    else => return inner_coerce(v),
                }
            }
        }.f,
        .equal = struct {
            fn f(a: *anyopaque, b: *anyopaque) bool {
                const pa: [*]u8 = @ptrCast(a);
                const pb: [*]u8 = @ptrCast(b);
                const a_null = pa[inner_size] != 0;
                const b_null = pb[inner_size] != 0;
                if (a_null and b_null) return true;
                if (a_null or b_null) return false;
                return inner_equal(@ptrCast(pa), @ptrCast(pb));
            }
        }.f,
        .format = struct {
            fn f(ptr: *anyopaque, buf: []u8) []const u8 {
                const p: [*]u8 = @ptrCast(ptr);
                if (p[inner_size] != 0) return std.fmt.bufPrint(buf, "null", .{}) catch buf[0..0];
                return inner_format(@ptrCast(p), buf);
            }
        }.f,
        .hash = struct {
            fn f(ptr: *anyopaque) u64 {
                const p: [*]u8 = @ptrCast(ptr);
                if (p[inner_size] != 0) return 0;
                return inner_hash(@ptrCast(p));
            }
        }.f,
        .clone = struct {
            fn f(ptr: *anyopaque, allocator: std.mem.Allocator) value.Value {
                const p: [*]u8 = @ptrCast(ptr);
                if (p[inner_size] != 0) return value.Value.fromNull();
                return inner_clone(@ptrCast(p), allocator);
            }
        }.f,
    };
}

pub const nullable_i8_ops = nullableOps(1, readI8, writeI8, coerceI8, eqI8, fmtI8, hashI8, cloneI8);
pub const nullable_i16_ops = nullableOps(2, readI16, writeI16, coerceI16, eqI16, fmtI16, hashI16, cloneI16);
pub const nullable_i32_ops = nullableOps(4, readI32, writeI32, coerceI32, eqI32, fmtI32, hashI32, cloneI32);
pub const nullable_i64_ops = nullableOps(8, readI64, writeI64, coerceI64, eqI64, fmtI64, hashI64, cloneI64);
pub const nullable_i128_ops = nullableOps(16, readI128, writeI128, coerceI128, eqI128, fmtI128, hashI128, cloneI128);
pub const nullable_u8_ops = nullableOps(1, readU8, writeU8, coerceU8, eqU8, fmtU8, hashU8, cloneU8);
pub const nullable_u16_ops = nullableOps(2, readU16, writeU16, coerceU16, eqU16, fmtU16, hashU16, cloneU16);
pub const nullable_u32_ops = nullableOps(4, readU32, writeU32, coerceU32, eqU32, fmtU32, hashU32, cloneU32);
pub const nullable_u64_ops = nullableOps(8, readU64, writeU64, coerceU64, eqU64, fmtU64, hashU64, cloneU64);
pub const nullable_u128_ops = nullableOps(16, readU128, writeU128, coerceU128, eqU128, fmtU128, hashU128, cloneU128);
pub const nullable_isize_ops = nullableOps(@sizeOf(isize), readIsize, writeIsize, coerceIsize, eqIsize, fmtIsize, hashIsize, cloneIsize);
pub const nullable_usize_ops = nullableOps(@sizeOf(usize), readUsize, writeUsize, coerceUsize, eqUsize, fmtUsize, hashUsize, cloneUsize);
pub const nullable_f16_ops = nullableOps(2, readF16, writeF16, coerceF16, eqF16, fmtF16, hashF16, cloneF16);
pub const nullable_f32_ops = nullableOps(4, readF32, writeF32, coerceF32, eqF32, fmtF32, hashF32, cloneF32);
pub const nullable_f64_ops = nullableOps(8, readF64, writeF64, coerceF64, eqF64, fmtF64, hashF64, cloneF64);
pub const nullable_f128_ops = nullableOps(16, readF128, writeF128, coerceF128, eqF128, fmtF128, hashF128, cloneF128);
pub const nullable_bool_ops = nullableOps(1, readBool, writeBool, coerceBool, eqBool, fmtBool, hashBool, cloneBool);
pub const nullable_char_ops = nullableOps(4, readChar, writeChar, coerceChar, eqChar, fmtChar, hashChar, cloneChar);
pub const nullable_ref_ops = nullableOps(8, readHeapRef, writeRef, coerceRef, eqRef, fmtRef, hashRef, cloneHeapRef);

// ════════════════════════════════════════════════════════════
// unit/null TypeOps：零字节类型的统一读写
// ════════════════════════════════════════════════════════════
// unit/null 通道 size=0，无数据。read 返回 fromUnit/fromNull，write 为 no-op。

pub fn readUnit(ptr: *anyopaque) value.Value {
    _ = ptr;
    return value.Value.fromUnit();
}
pub fn writeUnit(ptr: *anyopaque, v: value.Value) void {
    _ = ptr;
    _ = v;
}
pub fn coerceUnit(v: value.Value) value.Value {
    _ = v;
    return value.Value.fromUnit();
}
pub fn eqUnit(a: *anyopaque, b: *anyopaque) bool {
    _ = a;
    _ = b;
    return true;
}
pub fn fmtUnit(ptr: *anyopaque, buf: []u8) []const u8 {
    _ = ptr;
    return std.fmt.bufPrint(buf, "void", .{}) catch buf[0..0];
}
pub fn hashUnit(ptr: *anyopaque) u64 {
    _ = ptr;
    return 0;
}
pub fn cloneUnit(ptr: *anyopaque, allocator: std.mem.Allocator) value.Value {
    _ = allocator;
    return readUnit(ptr);
}
pub const unit_ops: TypeOps = .{ .read = readUnit, .write = writeUnit, .coerce = coerceUnit, .equal = eqUnit, .format = fmtUnit, .hash = hashUnit, .clone = cloneUnit };

pub fn readNull(ptr: *anyopaque) value.Value {
    _ = ptr;
    return value.Value.fromNull();
}
pub fn writeNull(ptr: *anyopaque, v: value.Value) void {
    _ = ptr;
    _ = v;
}
pub fn coerceNull(v: value.Value) value.Value {
    _ = v;
    return value.Value.fromNull();
}
pub fn eqNull(a: *anyopaque, b: *anyopaque) bool {
    _ = a;
    _ = b;
    return true;
}
pub fn fmtNull(ptr: *anyopaque, buf: []u8) []const u8 {
    _ = ptr;
    return std.fmt.bufPrint(buf, "null", .{}) catch buf[0..0];
}
pub fn hashNull(ptr: *anyopaque) u64 {
    _ = ptr;
    return 0;
}
pub fn cloneNull(ptr: *anyopaque, allocator: std.mem.Allocator) value.Value {
    _ = allocator;
    return readNull(ptr);
}
pub const null_ops: TypeOps = .{ .read = readNull, .write = writeNull, .coerce = coerceNull, .equal = eqNull, .format = fmtNull, .hash = hashNull, .clone = cloneNull };

// ════════════════════════════════════════════════════════════
// 静态 TypeDescriptor 常量（替代原 builtin_chan_descriptors EnumArray）
// ════════════════════════════════════════════════════════════
// 所有类型的 ops 已填充，引擎通过 ChanSlot.type_desc.ops
// 即可获得统一的读写接口（read/write/equal/format/hash）。
// - 标量类型（18 种）：各自的 ops vtable
// - ref：ref_ops 处理多态 8 字节槽（堆指针/null/标量位模式）
// - null/unit：null_ops/unit_ops 零字节类型
// - mask：bool_ops（与 bool 相同）
// - nullable：null_ops（is_nullable=true，通过 type_desc.is_nullable 分支处理）
// nullable 的 size=0（占位），实际宽度由 ChanSlot.width 持有。

const i8_descriptor_val: TypeDescriptor = .{ .size = 1, .type_id = 1, .type_name = "i8", .ops = &i8_ops };
const i16_descriptor_val: TypeDescriptor = .{ .size = 2, .type_id = 2, .type_name = "i16", .ops = &i16_ops };
const i32_descriptor_val: TypeDescriptor = .{ .size = 4, .type_id = 3, .type_name = "i32", .ops = &i32_ops };
const i64_descriptor_val: TypeDescriptor = .{ .size = 8, .type_id = 4, .type_name = "i64", .ops = &i64_ops };
const i128_descriptor_val: TypeDescriptor = .{ .size = 16, .type_id = 5, .type_name = "i128", .ops = &i128_ops };
const u8_descriptor_val: TypeDescriptor = .{ .size = 1, .type_id = 6, .type_name = "u8", .ops = &u8_ops };
const u16_descriptor_val: TypeDescriptor = .{ .size = 2, .type_id = 7, .type_name = "u16", .ops = &u16_ops };
const u32_descriptor_val: TypeDescriptor = .{ .size = 4, .type_id = 8, .type_name = "u32", .ops = &u32_ops };
const u64_descriptor_val: TypeDescriptor = .{ .size = 8, .type_id = 9, .type_name = "u64", .ops = &u64_ops };
const u128_descriptor_val: TypeDescriptor = .{ .size = 16, .type_id = 10, .type_name = "u128", .ops = &u128_ops };
const isize_descriptor_val: TypeDescriptor = .{ .size = @sizeOf(isize), .type_id = 11, .type_name = "isize", .ops = &isize_ops };
const usize_descriptor_val: TypeDescriptor = .{ .size = @sizeOf(usize), .type_id = 12, .type_name = "usize", .ops = &usize_ops };
const f16_descriptor_val: TypeDescriptor = .{ .size = 2, .type_id = 13, .type_name = "f16", .ops = &f16_ops };
const f32_descriptor_val: TypeDescriptor = .{ .size = 4, .type_id = 14, .type_name = "f32", .ops = &f32_ops };
const f64_descriptor_val: TypeDescriptor = .{ .size = 8, .type_id = 15, .type_name = "f64", .ops = &f64_ops };
const f128_descriptor_val: TypeDescriptor = .{ .size = 16, .type_id = 16, .type_name = "f128", .ops = &f128_ops };
const bool_descriptor_val: TypeDescriptor = .{ .size = 1, .type_id = 17, .type_name = "bool", .ops = &bool_ops };
const char_descriptor_val: TypeDescriptor = .{ .size = 4, .type_id = 18, .type_name = "char", .ops = &char_ops };
/// str 类型：具体引用类型（8 字节堆指针），type_id=19
const str_descriptor_val: TypeDescriptor = .{ .size = 8, .type_id = 19, .type_name = "str", .ops = &heap_ref_ops };
const null_descriptor_val: TypeDescriptor = .{ .size = 0, .type_id = 20, .type_name = "Null", .ops = &null_ops };
const unit_descriptor_val: TypeDescriptor = .{ .size = 0, .type_id = 21, .type_name = "void", .ops = &unit_ops };
/// 通用引用描述符（废除 ref_chan 过渡期保留）：8 字节堆指针，isRef()=true
/// 新代码应使用 TypeDescriptorPool.getOrCreateRefDesc(name) 获取具体类型描述符
const ref_descriptor_val: TypeDescriptor = .{ .size = 8, .type_id = 0, .type_name = "ref", .ops = &ref_ops };
const nullable_descriptor_val: TypeDescriptor = .{ .size = 0, .type_id = 0, .type_name = "nullable", .ops = &null_ops };

/// 所有标量 TypeDescriptor 指针（type_id 1-18），供 lookupByTypeId 线性查找
const scalar_descriptors = [_]*const TypeDescriptor{
    &i8_descriptor_val,  &i16_descriptor_val, &i32_descriptor_val,  &i64_descriptor_val, &i128_descriptor_val,
    &u8_descriptor_val,  &u16_descriptor_val, &u32_descriptor_val,  &u64_descriptor_val, &u128_descriptor_val,
    &isize_descriptor_val, &usize_descriptor_val,
    &f16_descriptor_val, &f32_descriptor_val,  &f64_descriptor_val,  &f128_descriptor_val,
    &bool_descriptor_val, &char_descriptor_val,
};

/// 按 type_id 查找静态 TypeDescriptor（仅标量类型有 type_id 1-18）。
/// 非 type_id=0 的类型（ref/null/unit/mask/nullable）不通过此函数查找。
pub fn lookupByTypeId(type_id: u16) ?*const TypeDescriptor {
    if (type_id == 0) return null;
    for (scalar_descriptors) |d| {
        if (d.type_id == type_id) return d;
    }
    return null;
}

/// IntKind → *const TypeDescriptor（用于整数字面量编译）
pub fn lookupByIntKind(kind: value.scalar.IntKind) *const TypeDescriptor {
    return switch (kind) {
        .i8 => &i8_descriptor_val,
        .i16 => &i16_descriptor_val,
        .i32 => &i32_descriptor_val,
        .i64 => &i64_descriptor_val,
        .i128 => &i128_descriptor_val,
        .u8 => &u8_descriptor_val,
        .u16 => &u16_descriptor_val,
        .u32 => &u32_descriptor_val,
        .u64 => &u64_descriptor_val,
        .u128 => &u128_descriptor_val,
        .isize => &isize_descriptor_val,
        .usize => &usize_descriptor_val,
    };
}

/// FloatKind → *const TypeDescriptor（用于浮点字面量编译）
pub fn lookupByFloatKind(kind: value.scalar.FloatKind) *const TypeDescriptor {
    return switch (kind) {
        .f16 => &f16_descriptor_val,
        .f32 => &f32_descriptor_val,
        .f64 => &f64_descriptor_val,
        .f128 => &f128_descriptor_val,
    };
}

/// null 类型描述符
pub const null_descriptor: *const TypeDescriptor = &null_descriptor_val;
/// unit 类型描述符
pub const unit_descriptor: *const TypeDescriptor = &unit_descriptor_val;
/// ref 类型描述符（8 字节堆引用）
pub const ref_descriptor: *const TypeDescriptor = &ref_descriptor_val;
/// nullable 类型描述符（is_nullable=true，实际宽度由 inner_type_desc 决定）
pub const nullable_descriptor: *const TypeDescriptor = &nullable_descriptor_val;
/// bool 类型描述符
pub const bool_descriptor: *const TypeDescriptor = &bool_descriptor_val;
/// char 类型描述符
pub const char_descriptor: *const TypeDescriptor = &char_descriptor_val;
/// 整数类型描述符
pub const i8_descriptor: *const TypeDescriptor = &i8_descriptor_val;
pub const i16_descriptor: *const TypeDescriptor = &i16_descriptor_val;
pub const i32_descriptor: *const TypeDescriptor = &i32_descriptor_val;
pub const i64_descriptor: *const TypeDescriptor = &i64_descriptor_val;
pub const i128_descriptor: *const TypeDescriptor = &i128_descriptor_val;
pub const u8_descriptor: *const TypeDescriptor = &u8_descriptor_val;
pub const u16_descriptor: *const TypeDescriptor = &u16_descriptor_val;
pub const u32_descriptor: *const TypeDescriptor = &u32_descriptor_val;
pub const u64_descriptor: *const TypeDescriptor = &u64_descriptor_val;
pub const u128_descriptor: *const TypeDescriptor = &u128_descriptor_val;
pub const isize_descriptor: *const TypeDescriptor = &isize_descriptor_val;
pub const usize_descriptor: *const TypeDescriptor = &usize_descriptor_val;
/// 浮点类型描述符
pub const f16_descriptor: *const TypeDescriptor = &f16_descriptor_val;
pub const f32_descriptor: *const TypeDescriptor = &f32_descriptor_val;
pub const f64_descriptor: *const TypeDescriptor = &f64_descriptor_val;
pub const f128_descriptor: *const TypeDescriptor = &f128_descriptor_val;
/// str 类型描述符（具体引用类型，type_id=19）
pub const str_descriptor: *const TypeDescriptor = &str_descriptor_val;

// ════════════════════════════════════════════════════════════
// 动态类型描述符池（废除 ref_chan：为每个用户类型创建具体引用描述符）
// ════════════════════════════════════════════════════════════
// 所有引用类型（ADT/record/newtype/array/fn/closure 等）均为 8 字节指针通道，
// 但各自拥有唯一的 type_id 和 type_name，消除多态 ref_descriptor。
// ops 统一使用 ref_ops（读写 8 字节指针），行为一致。

/// 动态类型描述符池：为用户自定义类型创建具体引用类型描述符
pub const TypeDescriptorPool = struct {
    arena: std.heap.ArenaAllocator,
    cache: std.StringHashMap(*const TypeDescriptor),
    /// 下一个可分配的 type_id（1-18: 标量, 19: str, 20: null, 21: unit, 22+: 用户类型）
    next_type_id: u16 = 22,

    pub fn init(backing: std.mem.Allocator) TypeDescriptorPool {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing),
            .cache = std.StringHashMap(*const TypeDescriptor).init(backing),
        };
    }

    pub fn deinit(self: *TypeDescriptorPool) void {
        self.cache.deinit();
        self.arena.deinit();
    }

    /// 获取或创建具名引用类型描述符（8 字节指针通道，isRef()=true）
    /// 相同 name 返回相同指针（缓存去重）
    pub fn getOrCreateRefDesc(self: *TypeDescriptorPool, name: []const u8) !*const TypeDescriptor {
        if (self.cache.get(name)) |td| return td;
        const td = try self.arena.allocator().create(TypeDescriptor);
        const name_copy = try self.arena.allocator().dupe(u8, name);
        td.* = .{
            .size = 8,
            .type_id = self.next_type_id,
            .type_name = name_copy,
            .ops = &heap_ref_ops,
        };
        self.next_type_id += 1;
        try self.cache.put(name_copy, td);
        return td;
    }

    /// 获取或创建 nullable<T> 具名描述符
    /// inner_size + 1 byte flag，ops 为对应的 nullable ops
    pub fn getOrCreateNullableDesc(self: *TypeDescriptorPool, inner: *const TypeDescriptor) !*const TypeDescriptor {
        const ops: *const TypeOps = if (inner.isRef()) &nullable_ref_ops else selectNullableTypeOps(inner);
        const name = try std.fmt.allocPrint(self.arena.allocator(), "nullable<{s}>", .{inner.type_name});
        if (self.cache.get(name)) |td| return td;
        const td = try self.arena.allocator().create(TypeDescriptor);
        td.* = .{
            .size = inner.size + 1,
            .type_id = self.next_type_id,
            .type_name = name,
            .ops = ops,
        };
        self.next_type_id += 1;
        try self.cache.put(name, td);
        return td;
    }

    fn selectNullableTypeOps(inner: *const TypeDescriptor) *const TypeOps {
        // 按 type_id 选择（1-18 对应标量）
        return switch (inner.type_id) {
            1 => &nullable_i8_ops,
            2 => &nullable_i16_ops,
            3 => &nullable_i32_ops,
            4 => &nullable_i64_ops,
            5 => &nullable_i128_ops,
            6 => &nullable_u8_ops,
            7 => &nullable_u16_ops,
            8 => &nullable_u32_ops,
            9 => &nullable_u64_ops,
            10 => &nullable_u128_ops,
            11 => &nullable_isize_ops,
            12 => &nullable_usize_ops,
            13 => &nullable_f16_ops,
            14 => &nullable_f32_ops,
            15 => &nullable_f64_ops,
            16 => &nullable_f128_ops,
            17 => &nullable_bool_ops,
            18 => &nullable_char_ops,
            else => &nullable_ref_ops, // 默认按引用处理
        };
    }
};
