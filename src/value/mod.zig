//! Value 值类型模块
//!
//! 定义 Glue 语言的核心值类型 Value 联合体。
//! 标量值（null、unit、布尔、字符、整数、浮点数）以 [N]u8 字节数组
//! 按实际宽度内联存储，无 padding，可直接 SIMD 加载。
//! 22 种堆分配值统一为 ref: *ObjHeader，通过 type_tag 区分类型。
//! 提供值的构造、访问、引用计数管理、深拷贝、格式化和相等性比较。

const std = @import("std");
const obj_header = @import("obj_header.zig");
const ObjHeader = obj_header.ObjHeader;
const RefKind = obj_header.RefKind;

// ── 标量运算系统 ──
pub const scalar = @import("scalar.zig");
pub const ScalarTag = scalar.ScalarTag;
pub const ops = @import("ops.zig");
pub const batch = @import("batch.zig");

// ── 字符类型 ──
pub const char_mod = @import("char.zig");
pub const Char = char_mod.Char;

// ── 字符串类型 ──
pub const str_mod = @import("str.zig");
pub const Str = str_mod.Str;

// ── 复合类型 ──
pub const composite = @import("composite.zig");
pub const ArrayValue = composite.ArrayValue;
pub const RecordValue = composite.RecordValue;
pub const AdtValue = composite.AdtValue;
pub const AdtField = composite.AdtField;
pub const NewtypeValue = composite.NewtypeValue;
pub const Cell = composite.Cell;
pub const Range = composite.Range;

// ── 可调用类型 ──
pub const callable = @import("callable.zig");
pub const VmClosure = callable.VmClosure;
pub const TraitValue = callable.TraitValue;
pub const LazyValue = callable.LazyValue;
const BuiltinFn = callable.BuiltinFn;
const Builtin = callable.Builtin;
const PartialApplication = callable.PartialApplication;

// ── 控制流类型 ──
pub const control = @import("control.zig");
pub const ErrorValue = control.ErrorValue;
pub const ThrowValue = control.ThrowValue;

// ── 迭代器类型 ──
pub const iterator = @import("iterator.zig");
const ArrayIterator = iterator.ArrayIterator;
const StringIterator = iterator.StringIterator;
const RangeIterator = iterator.RangeIterator;

// ── 并发类型 ──
pub const concurrent = @import("concurrent.zig");
pub const AtomicValue = concurrent.AtomicValue;
pub const SpawnHandle = concurrent.SpawnHandle;
pub const ChannelValue = concurrent.ChannelValue;
pub const SenderValue = concurrent.SenderValue;
pub const ReceiverValue = concurrent.ReceiverValue;

/// Glue 语言的核心值类型联合体
///
/// 标量变体以 [N]u8 字节数组按实际宽度内联存储，对齐为 1，无 padding。
/// 22 种堆对象统一为 ref: *ObjHeader，通过 ObjHeader.type_tag 区分类型。
/// @sizeOf(Value) = 24B（16B 最大 payload + 8B tag 对齐）
pub const Value = union(enum) {
    // ── 零字节特殊值 ──
    null_val,
    unit,

    // ── 标量：按实际宽度的 u8 数组 ──
    boolean: [1]u8,
    char: [4]u8,

    i8: [1]u8,
    u8: [1]u8,
    i16: [2]u8,
    u16: [2]u8,
    i32: [4]u8,
    u32: [4]u8,
    i64: [8]u8,
    u64: [8]u8,
    i128: [16]u8,
    u128: [16]u8,

    f16: [2]u8,
    f32: [4]u8,
    f64: [8]u8,
    f128: [16]u8,

    // ── 堆引用：统一指针 ──
    ref: *ObjHeader,

    // ════════════════════════════════════════════
    // 标量值构造
    // ════════════════════════════════════════════

    /// 构造 null 值
    pub inline fn fromNull() Value {
        return .null_val;
    }

    /// 构造 unit 值
    pub inline fn fromUnit() Value {
        return .unit;
    }

    /// 构造布尔值
    pub inline fn fromBool(b: bool) Value {
        return .{ .boolean = .{@intFromBool(b)} };
    }

    /// 构造字符值
    pub inline fn fromChar(c: Char) Value {
        return .{ .char = @bitCast(c.codepoint) };
    }

    // ── 整数构造 ──

    pub inline fn fromI8(v: i8) Value {
        return .{ .i8 = @bitCast(v) };
    }
    pub inline fn fromI16(v: i16) Value {
        return .{ .i16 = @bitCast(v) };
    }
    pub inline fn fromI32(v: i32) Value {
        return .{ .i32 = @bitCast(v) };
    }
    pub inline fn fromI64(v: i64) Value {
        return .{ .i64 = @bitCast(v) };
    }
    pub inline fn fromI128(v: i128) Value {
        return .{ .i128 = @bitCast(v) };
    }
    pub inline fn fromU8(v: u8) Value {
        return .{ .u8 = .{v} };
    }
    pub inline fn fromU16(v: u16) Value {
        return .{ .u16 = @bitCast(v) };
    }
    pub inline fn fromU32(v: u32) Value {
        return .{ .u32 = @bitCast(v) };
    }
    pub inline fn fromU64(v: u64) Value {
        return .{ .u64 = @bitCast(v) };
    }
    pub inline fn fromU128(v: u128) Value {
        return .{ .u128 = @bitCast(v) };
    }

    // ── 浮点数构造 ──

    pub inline fn fromF16(v: f16) Value {
        return .{ .f16 = @bitCast(v) };
    }
    pub inline fn fromF32(v: f32) Value {
        return .{ .f32 = @bitCast(v) };
    }
    pub inline fn fromF64(v: f64) Value {
        return .{ .f64 = @bitCast(v) };
    }
    pub inline fn fromF128(v: f128) Value {
        return .{ .f128 = @bitCast(v) };
    }

    // ════════════════════════════════════════════
    // 堆引用构造
    // ════════════════════════════════════════════

    /// 从 ObjHeader 指针构造引用值
    pub inline fn fromRef(obj: *ObjHeader) Value {
        return .{ .ref = obj };
    }

    /// 从字节切片构造字符串值，在堆上分配 Str
    pub fn fromStringBytes(allocator: std.mem.Allocator, bytes: []const u8) !Value {
        const s = try allocator.create(Str);
        s.* = try Str.fromLiteral(allocator, bytes);
        return .{ .ref = &s.header };
    }

    /// 构造数组值，可选固定大小
    pub fn makeArray(allocator: std.mem.Allocator, elements: []Value, fixed_size: ?u64) !Value {
        const arr = try allocator.create(ArrayValue);
        arr.* = .{ .elements = elements, .capacity = elements.len, .fixed_size = fixed_size };
        return .{ .ref = &arr.header };
    }

    /// 构造记录值，携带类型名和字段映射
    pub fn makeRecord(allocator: std.mem.Allocator, type_name: []const u8, fields: std.StringHashMap(Value)) !Value {
        const rec = try allocator.create(RecordValue);
        rec.* = .{ .type_name = type_name, .fields = fields };
        return .{ .ref = &rec.header };
    }

    /// 构造代数数据类型（ADT）值，携带类型名、构造子和字段
    pub fn makeAdt(allocator: std.mem.Allocator, type_name: []const u8, constructor: []const u8, fields: []AdtField) !Value {
        const adt = try allocator.create(AdtValue);
        adt.* = .{ .type_name = type_name, .constructor = constructor, .fields = fields };
        return .{ .ref = &adt.header };
    }

    /// 构造新类型值，包裹一个内部值
    pub fn makeNewtype(allocator: std.mem.Allocator, type_name: []const u8, inner: Value) !Value {
        const nt = try allocator.create(NewtypeValue);
        nt.* = .{ .type_name = type_name, .inner = inner };
        return .{ .ref = &nt.header };
    }

    /// 构造可变单元，持有对内部值的可变引用
    pub fn makeCell(allocator: std.mem.Allocator, inner: Value) !Value {
        const cell = try allocator.create(Cell);
        cell.* = .{ .inner = inner };
        return .{ .ref = &cell.header };
    }

    /// 构造区间值
    pub fn makeRange(allocator: std.mem.Allocator, start: [16]u8, end: [16]u8, inclusive: bool) !Value {
        const r = try allocator.create(Range);
        r.* = .{ .start = start, .end = end, .inclusive = inclusive };
        return .{ .ref = &r.header };
    }

    /// 构造虚拟机闭包值
    pub fn makeVmClosure(allocator: std.mem.Allocator, closure: VmClosure) !Value {
        const c = try allocator.create(VmClosure);
        c.* = closure;
        return .{ .ref = &c.header };
    }

    /// 构造部分应用值，绑定部分参数
    pub fn makePartial(allocator: std.mem.Allocator, func: Value, bound_args: []Value, remaining_arity: u8) !Value {
        const p = try allocator.create(PartialApplication);
        p.* = .{ .func = func, .bound_args = bound_args, .remaining_arity = remaining_arity };
        return .{ .ref = &p.header };
    }

    /// 构造内置函数值
    pub fn makeBuiltin(allocator: std.mem.Allocator, fn_ptr: BuiltinFn, user_ctx: ?*anyopaque) !Value {
        const b = try allocator.create(Builtin);
        b.* = .{ .fn_ptr = fn_ptr, .user_ctx = user_ctx };
        return .{ .ref = &b.header };
    }

    /// 构造错误值，携带类型名和消息
    pub fn makeError(allocator: std.mem.Allocator, type_name: []const u8, message: []const u8, is_error_subtype: bool) !Value {
        const e = try allocator.create(ErrorValue);
        e.* = .{ .type_name = type_name, .message = message, .is_error_subtype = is_error_subtype };
        return .{ .ref = &e.header };
    }

    /// 构造抛出值，封装成功值或错误载荷
    pub fn makeThrow(allocator: std.mem.Allocator, payload: ThrowValue.Payload) !Value {
        const t = try allocator.create(ThrowValue);
        t.* = .{ .payload = payload };
        return .{ .ref = &t.header };
    }

    /// 包装通道发送端为值
    pub fn fromSender(sv: *SenderValue) Value {
        return .{ .ref = &sv.header };
    }

    /// 包装通道接收端为值
    pub fn fromReceiver(rv: *ReceiverValue) Value {
        return .{ .ref = &rv.header };
    }

    // ════════════════════════════════════════════
    // 标量值访问器
    // ════════════════════════════════════════════

    /// 取布尔值
    pub inline fn asBool(self: Value) bool {
        return self.boolean[0] != 0;
    }

    /// 取字符值
    pub inline fn asChar(self: Value) Char {
        return .{ .codepoint = @bitCast(self.char) };
    }

    // ── 整数访问器 ──

    pub inline fn asI8(self: Value) i8 {
        return @bitCast(self.i8);
    }
    pub inline fn asI16(self: Value) i16 {
        return @bitCast(self.i16);
    }
    pub inline fn asI32(self: Value) i32 {
        return @bitCast(self.i32);
    }
    pub inline fn asI64(self: Value) i64 {
        return @bitCast(self.i64);
    }
    pub inline fn asI128(self: Value) i128 {
        return @bitCast(self.i128);
    }
    pub inline fn asU8(self: Value) u8 {
        return self.u8[0];
    }
    pub inline fn asU16(self: Value) u16 {
        return @bitCast(self.u16);
    }
    pub inline fn asU32(self: Value) u32 {
        return @bitCast(self.u32);
    }
    pub inline fn asU64(self: Value) u64 {
        return @bitCast(self.u64);
    }
    pub inline fn asU128(self: Value) u128 {
        return @bitCast(self.u128);
    }

    // ── 浮点数访问器 ──

    pub inline fn asF16(self: Value) f16 {
        return @bitCast(self.f16);
    }
    pub inline fn asF32(self: Value) f32 {
        return @bitCast(self.f32);
    }
    pub inline fn asF64(self: Value) f64 {
        return @bitCast(self.f64);
    }
    pub inline fn asF128(self: Value) f128 {
        return @bitCast(self.f128);
    }

    /// 取堆引用指针
    pub inline fn asRef(self: Value) *ObjHeader {
        return self.ref;
    }

    // ════════════════════════════════════════════
    // 类型判断
    // ════════════════════════════════════════════

    /// 判断是否为堆分配（装箱）值
    pub inline fn isBoxed(self: Value) bool {
        return self == .ref;
    }

    /// 判断是否为整数
    pub inline fn isInteger(self: Value) bool {
        return switch (self) {
            .i8, .i16, .i32, .i64, .i128,
            .u8, .u16, .u32, .u64, .u128 => true,
            else => false,
        };
    }

    /// 判断是否为浮点数
    pub inline fn isFloat(self: Value) bool {
        return switch (self) {
            .f16, .f32, .f64, .f128 => true,
            else => false,
        };
    }

    /// 判断是否为数值（整数或浮点数）
    pub inline fn isNumeric(self: Value) bool {
        return self.isInteger() or self.isFloat();
    }

    /// 判断是否为字符串
    pub inline fn isString(self: Value) bool {
        return self == .ref and self.ref.type_tag == .str;
    }

    /// 判断是否可作为 memo 表的键（不可变且可序列化）
    pub inline fn isMemoizableValue(self: Value) bool {
        if (self.isBoxed()) {
            return switch (self.ref.type_tag) {
                .str, .array, .record, .adt, .newtype, .range, .error_val, .throw_val => true,
                else => false,
            };
        }
        return true;
    }

    // ════════════════════════════════════════════
    // 引用计数与生命周期
    // ════════════════════════════════════════════

    /// 增加引用计数，返回自身以便链式调用
    ///
    /// 标量值无引用计数（no-op）。堆对象通过 ObjHeader 统一管理。
    /// Str SSO 模式使用 sso_flags 中的独立引用计数。
    pub inline fn retain(self: Value) Value {
        switch (self) {
            // 标量值无需引用计数
            .null_val, .unit, .boolean, .char,
            .i8, .i16, .i32, .i64, .i128,
            .u8, .u16, .u32, .u64, .u128,
            .f16, .f32, .f64, .f128 => {},
            .ref => |obj| {
                // Str SSO 模式使用 sso_flags 中的独立引用计数
                if (obj.type_tag == .str) {
                    const s: *Str = @alignCast(@fieldParentPtr("header", obj));
                    if (s.isSso()) {
                        s.ssoRetain();
                        return self;
                    }
                }
                _ = obj_header.retain(obj);
            },
        }
        return self;
    }

    /// 递减引用计数，归零时释放堆内存
    ///
    /// 标量值无引用计数（no-op）。堆对象通过 ObjHeader 统一管理。
    /// Str SSO 模式归零时由 strDeinit 销毁对象本体。
    pub fn release(self: Value, allocator: std.mem.Allocator) void {
        switch (self) {
            // 标量值无需释放
            .null_val, .unit, .boolean, .char,
            .i8, .i16, .i32, .i64, .i128,
            .u8, .u16, .u32, .u64, .u128,
            .f16, .f32, .f64, .f128 => {},
            .ref => |obj| {
                // Str SSO 模式使用 sso_flags 中的独立引用计数
                if (obj.type_tag == .str) {
                    const s: *Str = @alignCast(@fieldParentPtr("header", obj));
                    if (s.isSso()) {
                        if (s.ssoRelease()) {
                            s.deinit(allocator);
                            allocator.destroy(s);
                        }
                        return;
                    }
                }
                obj_header.release(obj, allocator);
            },
        }
    }

    // ════════════════════════════════════════════
    // 深拷贝
    // ════════════════════════════════════════════

    /// 深拷贝值：标量值原样返回，堆分配值递归复制其内容
    pub fn deepCopy(self: Value, allocator: std.mem.Allocator) !Value {
        switch (self) {
            .null_val, .unit, .boolean, .char,
            .i8, .i16, .i32, .i64, .i128,
            .u8, .u16, .u32, .u64, .u128,
            .f16, .f32, .f64, .f128 => return self,

            .ref => |obj| {
                return switch (obj.type_tag) {
                    .str => try deepCopyStr(obj, allocator),
                    .array => try deepCopyArray(obj, allocator),
                    .record => try deepCopyRecord(obj, allocator),
                    .adt => try deepCopyAdt(obj, allocator),
                    .newtype => try deepCopyNewtype(obj, allocator),
                    .cell => try deepCopyCell(obj, allocator),
                    .range => try deepCopyRange(obj, allocator),
                    .vm_closure => try deepCopyVmClosure(obj, allocator),
                    .partial => try deepCopyPartial(obj, allocator),
                    .builtin => try deepCopyBuiltin(obj, allocator),
                    .error_val => try deepCopyError(obj, allocator),
                    .throw_val => try deepCopyThrow(obj, allocator),
                    .trait_val => try deepCopyTrait(obj, allocator),
                    // 迭代器、惰性值、并发对象：引用语义，retain 即可
                    .array_iter, .string_iter, .range_iter,
                    .lazy_val,
                    .atomic_val, .spawn_val, .channel_val, .sender_val, .receiver_val => self.retain(),
                };
            },
        }
    }

    fn deepCopyStr(obj: *ObjHeader, allocator: std.mem.Allocator) !Value {
        const s: *Str = @alignCast(@fieldParentPtr("header", obj));
        return try Value.fromStringBytes(allocator, s.bytes());
    }

    fn deepCopyArray(obj: *ObjHeader, allocator: std.mem.Allocator) !Value {
        const p: *ArrayValue = @alignCast(@fieldParentPtr("header", obj));
        const new_elems: []Value = if (p.elements.len > 0)
            try allocator.alloc(Value, p.elements.len)
        else
            &.{};
        errdefer if (new_elems.len > 0) allocator.free(new_elems);
        var copied: usize = 0;
        errdefer {
            for (new_elems[0..copied]) |e| e.release(allocator);
        }
        for (p.elements, 0..) |elem, i| {
            new_elems[i] = try elem.deepCopy(allocator);
            copied += 1;
        }
        const arr = try allocator.create(ArrayValue);
        arr.* = .{
            .elements = new_elems,
            .capacity = new_elems.len,
            .fixed_size = p.fixed_size,
        };
        return .{ .ref = &arr.header };
    }

    fn deepCopyRecord(obj: *ObjHeader, allocator: std.mem.Allocator) !Value {
        const p: *RecordValue = @alignCast(@fieldParentPtr("header", obj));
        var new_fields = std.StringHashMap(Value).init(allocator);
        errdefer {
            var it = new_fields.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                entry.value_ptr.release(allocator);
            }
            new_fields.deinit();
        }
        var it = p.fields.iterator();
        while (it.next()) |entry| {
            const dup_key = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(dup_key);
            const dup_val = try entry.value_ptr.deepCopy(allocator);
            errdefer dup_val.release(allocator);
            try new_fields.put(dup_key, dup_val);
        }
        const rec = try allocator.create(RecordValue);
        rec.* = .{ .type_name = p.type_name, .fields = new_fields };
        return .{ .ref = &rec.header };
    }

    fn deepCopyAdt(obj: *ObjHeader, allocator: std.mem.Allocator) !Value {
        const p: *AdtValue = @alignCast(@fieldParentPtr("header", obj));
        const new_fields: []AdtField = if (p.fields.len > 0)
            try allocator.alloc(AdtField, p.fields.len)
        else
            &.{};
        errdefer if (new_fields.len > 0) allocator.free(new_fields);
        var copied: usize = 0;
        errdefer {
            for (new_fields[0..copied]) |*f| f.value.release(allocator);
        }
        for (p.fields, 0..) |f, i| {
            new_fields[i] = .{
                .name = f.name,
                .value = try f.value.deepCopy(allocator),
            };
            copied += 1;
        }
        const adt = try allocator.create(AdtValue);
        adt.* = .{
            .type_name = p.type_name,
            .constructor = p.constructor,
            .fields = new_fields,
        };
        return .{ .ref = &adt.header };
    }

    fn deepCopyNewtype(obj: *ObjHeader, allocator: std.mem.Allocator) !Value {
        const p: *NewtypeValue = @alignCast(@fieldParentPtr("header", obj));
        const nt = try allocator.create(NewtypeValue);
        nt.* = .{
            .type_name = p.type_name,
            .inner = try p.inner.deepCopy(allocator),
        };
        return .{ .ref = &nt.header };
    }

    fn deepCopyCell(obj: *ObjHeader, allocator: std.mem.Allocator) !Value {
        const p: *Cell = @alignCast(@fieldParentPtr("header", obj));
        const cell = try allocator.create(Cell);
        cell.* = .{ .inner = try p.inner.deepCopy(allocator) };
        return .{ .ref = &cell.header };
    }

    fn deepCopyRange(obj: *ObjHeader, allocator: std.mem.Allocator) !Value {
        const p: *Range = @alignCast(@fieldParentPtr("header", obj));
        const r = try allocator.create(Range);
        r.* = .{
            .start = p.start,
            .end = p.end,
            .inclusive = p.inclusive,
            .start_i64 = p.start_i64,
            .end_i64 = p.end_i64,
        };
        return .{ .ref = &r.header };
    }

    fn deepCopyVmClosure(obj: *ObjHeader, allocator: std.mem.Allocator) !Value {
        const p: *VmClosure = @alignCast(@fieldParentPtr("header", obj));
        const new_upvalues: []Value = if (p.upvalues.len > 0)
            try allocator.alloc(Value, p.upvalues.len)
        else
            &.{};
        errdefer if (p.upvalues.len > 0) allocator.free(new_upvalues);
        var uv_copied: usize = 0;
        errdefer {
            for (new_upvalues[0..uv_copied]) |e| e.release(allocator);
        }
        for (p.upvalues, 0..) |uv, i| {
            new_upvalues[i] = try uv.deepCopy(allocator);
            uv_copied += 1;
        }
        const new_bound_args: []Value = if (p.bound_args.len > 0)
            try allocator.alloc(Value, p.bound_args.len)
        else
            &.{};
        errdefer if (p.bound_args.len > 0) allocator.free(new_bound_args);
        var ba_copied: usize = 0;
        errdefer {
            for (new_bound_args[0..ba_copied]) |e| e.release(allocator);
        }
        for (p.bound_args, 0..) |ba, i| {
            new_bound_args[i] = try ba.deepCopy(allocator);
            ba_copied += 1;
        }
        const c = try allocator.create(VmClosure);
        c.* = .{
            .func = p.func,
            .arity = p.arity,
            .upvalues = new_upvalues,
            .bound_args = new_bound_args,
            .allocator = allocator,
            .self_upvalue_idx = p.self_upvalue_idx,
        };
        return .{ .ref = &c.header };
    }

    fn deepCopyPartial(obj: *ObjHeader, allocator: std.mem.Allocator) !Value {
        const p: *PartialApplication = @alignCast(@fieldParentPtr("header", obj));
        const new_func = try p.func.deepCopy(allocator);
        errdefer new_func.release(allocator);
        const new_bound_args: []Value = if (p.bound_args.len > 0)
            try allocator.alloc(Value, p.bound_args.len)
        else
            &.{};
        errdefer if (p.bound_args.len > 0) allocator.free(new_bound_args);
        var ba_copied: usize = 0;
        errdefer {
            for (new_bound_args[0..ba_copied]) |e| e.release(allocator);
        }
        for (p.bound_args, 0..) |ba, i| {
            new_bound_args[i] = try ba.deepCopy(allocator);
            ba_copied += 1;
        }
        const pa = try allocator.create(PartialApplication);
        pa.* = .{
            .func = new_func,
            .bound_args = new_bound_args,
            .remaining_arity = p.remaining_arity,
        };
        return .{ .ref = &pa.header };
    }

    fn deepCopyBuiltin(obj: *ObjHeader, allocator: std.mem.Allocator) !Value {
        const p: *Builtin = @alignCast(@fieldParentPtr("header", obj));
        const b = try allocator.create(Builtin);
        b.* = .{ .fn_ptr = p.fn_ptr, .user_ctx = p.user_ctx };
        return .{ .ref = &b.header };
    }

    fn deepCopyError(obj: *ObjHeader, allocator: std.mem.Allocator) !Value {
        const p: *ErrorValue = @alignCast(@fieldParentPtr("header", obj));
        const e = try allocator.create(ErrorValue);
        errdefer allocator.destroy(e);
        const dup_type = try allocator.dupe(u8, p.type_name);
        errdefer allocator.free(dup_type);
        const dup_msg = try allocator.dupe(u8, p.message);
        errdefer allocator.free(dup_msg);
        e.* = .{
            .type_name = dup_type,
            .message = dup_msg,
            .is_error_subtype = p.is_error_subtype,
        };
        return .{ .ref = &e.header };
    }

    fn deepCopyThrow(obj: *ObjHeader, allocator: std.mem.Allocator) !Value {
        const p: *ThrowValue = @alignCast(@fieldParentPtr("header", obj));
        const t = try allocator.create(ThrowValue);
        errdefer allocator.destroy(t);
        t.* = .{ .payload = switch (p.payload) {
            .ok => |v| .{ .ok = try v.deepCopy(allocator) },
            .err => |e| blk: {
                const dup_type = try allocator.dupe(u8, e.type_name);
                errdefer allocator.free(dup_type);
                const dup_msg = try allocator.dupe(u8, e.message);
                errdefer allocator.free(dup_msg);
                const new_e = try allocator.create(ErrorValue);
                errdefer allocator.destroy(new_e);
                new_e.* = .{
                    .type_name = dup_type,
                    .message = dup_msg,
                    .is_error_subtype = e.is_error_subtype,
                };
                break :blk .{ .err = new_e };
            },
        } };
        return .{ .ref = &t.header };
    }

    fn deepCopyTrait(obj: *ObjHeader, allocator: std.mem.Allocator) !Value {
        const p: *TraitValue = @alignCast(@fieldParentPtr("header", obj));
        if (!p.vm_owned) return Value.fromRef(obj).retain();
        var new_methods = std.StringHashMap(Value).init(allocator);
        errdefer {
            var it = new_methods.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                entry.value_ptr.release(allocator);
            }
            new_methods.deinit();
        }
        var it = p.methods.iterator();
        while (it.next()) |entry| {
            const dup_key = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(dup_key);
            const dup_val = try entry.value_ptr.deepCopy(allocator);
            errdefer dup_val.release(allocator);
            try new_methods.put(dup_key, dup_val);
        }
        const new_data: ?Value = if (p.data) |d| try d.deepCopy(allocator) else null;
        errdefer if (new_data) |d| d.release(allocator);
        const tv = try allocator.create(TraitValue);
        tv.* = .{
            .trait_name = p.trait_name,
            .methods = new_methods,
            .data = new_data,
            .allocator = allocator,
            .vm_owned = true,
        };
        return .{ .ref = &tv.header };
    }

    // ════════════════════════════════════════════
    // 格式化
    // ════════════════════════════════════════════

    /// 将值格式化为可读字符串，追加到 buf
    pub fn format(self: Value, allocator: std.mem.Allocator, buf: *std.ArrayList(u8)) !void {
        switch (self) {
            .null_val => try buf.appendSlice(allocator, "null"),
            .unit => try buf.appendSlice(allocator, "()"),
            .boolean => try buf.appendSlice(allocator, if (self.asBool()) "true" else "false"),
            .char => {
                var temp: [16]u8 = undefined;
                const s = std.fmt.bufPrint(&temp, "'{u}'", .{self.asChar().toNative()}) catch unreachable;
                try buf.appendSlice(allocator, s);
            },
            .i8 => try formatInt(self.asI8(), allocator, buf),
            .i16 => try formatInt(self.asI16(), allocator, buf),
            .i32 => try formatInt(self.asI32(), allocator, buf),
            .i64 => try formatInt(self.asI64(), allocator, buf),
            .i128 => try formatInt(self.asI128(), allocator, buf),
            .u8 => try formatInt(self.asU8(), allocator, buf),
            .u16 => try formatInt(self.asU16(), allocator, buf),
            .u32 => try formatInt(self.asU32(), allocator, buf),
            .u64 => try formatInt(self.asU64(), allocator, buf),
            .u128 => try formatInt(self.asU128(), allocator, buf),
            .f16 => try formatFloat(self.asF16(), allocator, buf),
            .f32 => try formatFloat(self.asF32(), allocator, buf),
            .f64 => try formatFloat(self.asF64(), allocator, buf),
            .f128 => try formatFloat(self.asF128(), allocator, buf),

            .ref => |obj| {
                switch (obj.type_tag) {
                    .str => {
                        const s: *Str = @alignCast(@fieldParentPtr("header", obj));
                        try buf.append(allocator, '"');
                        try buf.appendSlice(allocator, s.bytes());
                        try buf.append(allocator, '"');
                    },
                    .array => {
                        const arr: *ArrayValue = @alignCast(@fieldParentPtr("header", obj));
                        try buf.append(allocator, '[');
                        for (arr.elements, 0..) |elem, i| {
                            if (i > 0) try buf.appendSlice(allocator, ", ");
                            try elem.format(allocator, buf);
                        }
                        try buf.append(allocator, ']');
                    },
                    .record => {
                        const rec: *RecordValue = @alignCast(@fieldParentPtr("header", obj));
                        try buf.appendSlice(allocator, rec.type_name);
                        try buf.append(allocator, '{');
                        var it = rec.fields.iterator();
                        var first = true;
                        while (it.next()) |entry| {
                            if (!first) try buf.appendSlice(allocator, ", ");
                            first = false;
                            try buf.appendSlice(allocator, entry.key_ptr.*);
                            try buf.appendSlice(allocator, ": ");
                            try entry.value_ptr.format(allocator, buf);
                        }
                        try buf.append(allocator, '}');
                    },
                    .adt => {
                        const adt: *AdtValue = @alignCast(@fieldParentPtr("header", obj));
                        try buf.appendSlice(allocator, adt.type_name);
                        try buf.appendSlice(allocator, "::");
                        try buf.appendSlice(allocator, adt.constructor);
                        if (adt.fields.len > 0) {
                            try buf.append(allocator, '(');
                            for (adt.fields, 0..) |field, i| {
                                if (i > 0) try buf.appendSlice(allocator, ", ");
                                try field.value.format(allocator, buf);
                            }
                            try buf.append(allocator, ')');
                        }
                    },
                    .newtype => {
                        const nt: *NewtypeValue = @alignCast(@fieldParentPtr("header", obj));
                        try buf.appendSlice(allocator, nt.type_name);
                        try buf.append(allocator, '(');
                        try nt.inner.format(allocator, buf);
                        try buf.append(allocator, ')');
                    },
                    .cell => {
                        const cell: *Cell = @alignCast(@fieldParentPtr("header", obj));
                        try buf.appendSlice(allocator, "Cell(");
                        try cell.inner.format(allocator, buf);
                        try buf.append(allocator, ')');
                    },
                    .range => {
                        const r: *Range = @alignCast(@fieldParentPtr("header", obj));
                        try buf.appendSlice(allocator, "<range>");
                        _ = r;
                    },
                    .vm_closure => try buf.appendSlice(allocator, "<closure>"),
                    .partial => try buf.appendSlice(allocator, "<partial>"),
                    .builtin => try buf.appendSlice(allocator, "<builtin>"),
                    .error_val => {
                        const e: *ErrorValue = @alignCast(@fieldParentPtr("header", obj));
                        try buf.appendSlice(allocator, "Error(");
                        try buf.appendSlice(allocator, e.type_name);
                        try buf.appendSlice(allocator, ": ");
                        try buf.appendSlice(allocator, e.message);
                        try buf.append(allocator, ')');
                    },
                    .throw_val => try buf.appendSlice(allocator, "<throw>"),
                    .array_iter => try buf.appendSlice(allocator, "<array_iter>"),
                    .string_iter => try buf.appendSlice(allocator, "<string_iter>"),
                    .range_iter => try buf.appendSlice(allocator, "<range_iter>"),
                    .atomic_val => try buf.appendSlice(allocator, "<atomic>"),
                    .spawn_val => try buf.appendSlice(allocator, "<spawn>"),
                    .channel_val => try buf.appendSlice(allocator, "<channel>"),
                    .sender_val => try buf.appendSlice(allocator, "<sender>"),
                    .receiver_val => try buf.appendSlice(allocator, "<receiver>"),
                    .trait_val => try buf.appendSlice(allocator, "<trait>"),
                    .lazy_val => try buf.appendSlice(allocator, "<lazy>"),
                }
            },
        }
    }

    /// 格式化值并返回新分配的字符串切片
    pub fn formatAlloc(self: Value, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try self.format(allocator, &buf);
        return buf.toOwnedSlice(allocator);
    }
};

// ════════════════════════════════════════════════════════════
// 模块级工具函数
// ════════════════════════════════════════════════════════════

/// 格式化整数到 buf
fn formatInt(v: anytype, allocator: std.mem.Allocator, buf: *std.ArrayList(u8)) !void {
    var temp: [41]u8 = undefined;
    const s = std.fmt.bufPrint(&temp, "{d}", .{v}) catch unreachable;
    try buf.appendSlice(allocator, s);
}

/// 格式化浮点数到 buf
fn formatFloat(v: anytype, allocator: std.mem.Allocator, buf: *std.ArrayList(u8)) !void {
    var temp: [80]u8 = undefined;
    const s = std.fmt.bufPrint(&temp, "{d}", .{v}) catch unreachable;
    try buf.appendSlice(allocator, s);
}

/// 值的相等性比较：标量按值比较，容器递归比较，其余按引用相等
pub fn equals(a: Value, b: Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null_val, .unit => true,
        .boolean => a.asBool() == b.asBool(),
        .char => a.asChar().equals(b.asChar()),
        .i8 => a.asI8() == b.asI8(),
        .i16 => a.asI16() == b.asI16(),
        .i32 => a.asI32() == b.asI32(),
        .i64 => a.asI64() == b.asI64(),
        .i128 => a.asI128() == b.asI128(),
        .u8 => a.asU8() == b.asU8(),
        .u16 => a.asU16() == b.asU16(),
        .u32 => a.asU32() == b.asU32(),
        .u64 => a.asU64() == b.asU64(),
        .u128 => a.asU128() == b.asU128(),
        .f16 => a.asF16() == b.asF16(),
        .f32 => a.asF32() == b.asF32(),
        .f64 => a.asF64() == b.asF64(),
        .f128 => a.asF128() == b.asF128(),

        .ref => |obj| {
            if (obj == b.ref) return true; // 同一对象
            if (obj.type_tag != b.ref.type_tag) return false;
            return switch (obj.type_tag) {
                .str => blk: {
                    const sa: *Str = @alignCast(@fieldParentPtr("header", obj));
                    const sb: *Str = @alignCast(@fieldParentPtr("header", b.ref));
                    break :blk std.mem.eql(u8, sa.bytes(), sb.bytes());
                },
                .array => blk: {
                    const aa: *ArrayValue = @alignCast(@fieldParentPtr("header", obj));
                    const ab: *ArrayValue = @alignCast(@fieldParentPtr("header", b.ref));
                    if (aa.elements.len != ab.elements.len) break :blk false;
                    for (aa.elements, ab.elements) |x, y| {
                        if (!equals(x, y)) break :blk false;
                    }
                    break :blk true;
                },
                .record => blk: {
                    const ra: *RecordValue = @alignCast(@fieldParentPtr("header", obj));
                    const rb: *RecordValue = @alignCast(@fieldParentPtr("header", b.ref));
                    if (ra.fields.count() != rb.fields.count()) break :blk false;
                    var it = ra.fields.iterator();
                    while (it.next()) |e| {
                        const bv = rb.fields.get(e.key_ptr.*) orelse break :blk false;
                        if (!equals(e.value_ptr.*, bv)) break :blk false;
                    }
                    break :blk true;
                },
                .adt => blk: {
                    const va: *AdtValue = @alignCast(@fieldParentPtr("header", obj));
                    const vb: *AdtValue = @alignCast(@fieldParentPtr("header", b.ref));
                    if (!std.mem.eql(u8, va.type_name, vb.type_name)) break :blk false;
                    if (!std.mem.eql(u8, va.constructor, vb.constructor)) break :blk false;
                    if (va.fields.len != vb.fields.len) break :blk false;
                    for (va.fields, vb.fields) |fa, fb| {
                        if (!equals(fa.value, fb.value)) break :blk false;
                    }
                    break :blk true;
                },
                .newtype => blk: {
                    const na: *NewtypeValue = @alignCast(@fieldParentPtr("header", obj));
                    const nb: *NewtypeValue = @alignCast(@fieldParentPtr("header", b.ref));
                    break :blk std.mem.eql(u8, na.type_name, nb.type_name) and equals(na.inner, nb.inner);
                },
                .range => blk: {
                    const ra: *Range = @alignCast(@fieldParentPtr("header", obj));
                    const rb: *Range = @alignCast(@fieldParentPtr("header", b.ref));
                    break :blk std.mem.eql(u8, &ra.start, &rb.start) and
                        std.mem.eql(u8, &ra.end, &rb.end) and ra.inclusive == rb.inclusive;
                },
                .error_val => blk: {
                    const ea: *ErrorValue = @alignCast(@fieldParentPtr("header", obj));
                    const eb: *ErrorValue = @alignCast(@fieldParentPtr("header", b.ref));
                    break :blk std.mem.eql(u8, ea.type_name, eb.type_name) and
                        std.mem.eql(u8, ea.message, eb.message);
                },
                // 其余类型按引用相等
                else => obj == b.ref,
            };
        },
    };
}

/// 注册所有堆对象类型的 deinit 函数
///
/// 应在运行时初始化阶段调用，使 obj_header.release 能正确分派到各类型的析构函数。
pub fn registerAllDeinits() void {
    composite.registerDeinits();
    callable.registerDeinits();
    control.registerDeinits();
    iterator.registerDeinits();
    concurrent.registerDeinits();
    obj_header.registerDeinit(.str, str_mod.strDeinit);
}

test {
    std.testing.refAllDecls(@This());
}
