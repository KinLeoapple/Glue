//! Value 值类型模块
//!
//! 定义 Glue 语言的核心值类型 Value 联合体。
//! 标量值（null、unit、布尔、字符、整数、浮点数）以 [N]u8 字节数组
//! 按实际宽度内联存储，无 padding，可直接 SIMD 加载。
//! 22 种堆分配值统一为 ref: *ObjHeader，通过 type_tag 区分类型。
//! 提供值的构造、访问、引用计数管理、深拷贝、格式化和相等性比较。

const std = @import("std");
pub const obj_header = @import("obj_header.zig");
const ObjHeader = obj_header.ObjHeader;
const RefKind = obj_header.RefKind;
const ThreadContext = obj_header.ThreadContext;

// ── 标量运算系统 ──
pub const scalar = @import("scalar.zig");
pub const ScalarTag = scalar.ScalarTag;
pub const ops = @import("ops.zig");
pub const batch = @import("batch.zig");
pub const cast = @import("cast.zig");

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
pub const Closure = callable.Closure;
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
pub const AsyncHandle = concurrent.AsyncHandle;
pub const ChannelValue = concurrent.ChannelValue;
pub const SenderValue = concurrent.SenderValue;
pub const ReceiverValue = concurrent.ReceiverValue;

/// Glue 语言的核心值类型联合体
///
/// 标量变体以 [N]u8 字节数组按实际宽度内联存储，对齐为 1，无 padding。
/// 22 种堆对象统一为 ref: *ObjHeader，通过 ObjHeader.type_tag 区分类型。
/// @sizeOf(Value) = 24B（16B 最大 payload + 8B tag 对齐）

/// 深拷贝/分配操作的错误集（显式定义，避免推断错误集循环依赖）
/// 包含 ThreadContext.allocObj 和 fromStringBytes 的所有可能错误
pub const AllocError = error{ OutOfMemory, Overflow, TooManyPools, AllocFailed };

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

    /// 从字节切片构造字符串值（连续内存：[Str header | byte buffer]）
    pub fn fromStringBytes(tctx: *ThreadContext, bytes: []const u8) !Value {
        const s = try Str.createContiguous(tctx, bytes);
        return .{ .ref = &s.header };
    }

    /// 构造数组值，可选固定大小
    /// header 和 elements 分离分配：header 走页池，elements 独立分配（支持后续 push/pop 替换切片）
    pub fn makeArray(tctx: *ThreadContext, elements: []Value, fixed_size: ?u64) !Value {
        const arr = try tctx.createObj(ArrayValue);
        const elems: []Value = if (elements.len > 0) blk: {
            const buf = try tctx.allocObj(elements.len * @sizeOf(Value));
            break :blk @as([*]Value, @ptrCast(@alignCast(buf.ptr)))[0..elements.len];
        } else &.{};
        @memcpy(elems, elements);
        arr.* = .{ .elements = elems, .capacity = elems.len, .fixed_size = fixed_size };
        return .{ .ref = &arr.header };
    }

    /// 构造记录值，携带类型名和字段切片
    /// 连续内存布局：[RecordValue header | Value fields[]]
    /// fields 切片指向尾部连续区域，单次分配单次释放
    pub fn makeRecord(tctx: *ThreadContext, type_name: []const u8, fields: []Value) !Value {
        const f_size = fields.len * @sizeOf(Value);
        const total = @sizeOf(RecordValue) + f_size;
        const mem = try tctx.allocObj(total);
        const rec: *RecordValue = @ptrCast(@alignCast(mem.ptr));
        const f_ptr: [*]Value = @ptrCast(@alignCast(mem.ptr + @sizeOf(RecordValue)));
        @memcpy(f_ptr[0..fields.len], fields);
        rec.* = .{ .type_name = type_name, .fields = f_ptr[0..fields.len] };
        return .{ .ref = &rec.header };
    }

    /// 构造记录值（带字段名表，用于 format 输出）
    /// 连续内存布局：[RecordValue header | Value fields[]]
    /// field_names 指向源码 arena 或 string_pool，无需释放
    pub fn makeRecordWithNames(
        tctx: *ThreadContext,
        type_name: []const u8,
        fields: []Value,
        field_names: []const ?[]const u8,
    ) !Value {
        const f_size = fields.len * @sizeOf(Value);
        const total = @sizeOf(RecordValue) + f_size;
        const mem = try tctx.allocObj(total);
        const rec: *RecordValue = @ptrCast(@alignCast(mem.ptr));
        const f_ptr: [*]Value = @ptrCast(@alignCast(mem.ptr + @sizeOf(RecordValue)));
        @memcpy(f_ptr[0..fields.len], fields);
        rec.* = .{ .type_name = type_name, .fields = f_ptr[0..fields.len], .field_names = field_names };
        return .{ .ref = &rec.header };
    }

    /// 构造代数数据类型（ADT）值，携带类型名、构造子和字段
    /// 连续内存布局：[AdtValue header | AdtField fields[]]
    pub fn makeAdt(tctx: *ThreadContext, type_name: []const u8, constructor: []const u8, fields: []AdtField) !Value {
        const f_size = fields.len * @sizeOf(AdtField);
        const total = @sizeOf(AdtValue) + f_size;
        const mem = try tctx.allocObj(total);
        const adt: *AdtValue = @ptrCast(@alignCast(mem.ptr));
        const f_ptr: [*]AdtField = @ptrCast(@alignCast(mem.ptr + @sizeOf(AdtValue)));
        @memcpy(f_ptr[0..fields.len], fields);
        adt.* = .{ .type_name = type_name, .constructor = constructor, .fields = f_ptr[0..fields.len] };
        return .{ .ref = &adt.header };
    }

    /// 构造新类型值，包裹一个内部值（固定大小）
    pub fn makeNewtype(tctx: *ThreadContext, type_name: []const u8, inner: Value) !Value {
        const nt = try tctx.createObj(NewtypeValue);
        nt.* = .{ .type_name = type_name, .inner = inner };
        return .{ .ref = &nt.header };
    }

    /// 构造可变单元，持有对内部值的可变引用（固定大小）
    pub fn makeCell(tctx: *ThreadContext, inner: Value) !Value {
        const cell = try tctx.createObj(Cell);
        cell.* = .{ .inner = inner };
        return .{ .ref = &cell.header };
    }

    /// 构造区间值（固定大小）
    pub fn makeRange(tctx: *ThreadContext, start: [16]u8, end: [16]u8, inclusive: bool) !Value {
        const r = try tctx.createObj(Range);
        r.* = .{ .start = start, .end = end, .inclusive = inclusive };
        return .{ .ref = &r.header };
    }

    /// 构造闭包值
    /// 连续内存布局：[Closure header | upvalues[] | bound_args[]]
    /// upvalues 和 bound_args 切片指向尾部连续区域，单次分配单次释放
    pub fn makeClosure(tctx: *ThreadContext, closure: Closure) !Value {
        const uv_size = closure.upvalues.len * @sizeOf(Value);
        const ba_size = closure.bound_args.len * @sizeOf(Value);
        const total = @sizeOf(Closure) + uv_size + ba_size;
        const mem = try tctx.allocObj(total);
        const c: *Closure = @ptrCast(@alignCast(mem.ptr));
        const uv_ptr: [*]Value = @ptrCast(@alignCast(mem.ptr + @sizeOf(Closure)));
        const ba_ptr: [*]Value = @ptrCast(@alignCast(mem.ptr + @sizeOf(Closure) + uv_size));
        @memcpy(uv_ptr[0..closure.upvalues.len], closure.upvalues);
        @memcpy(ba_ptr[0..closure.bound_args.len], closure.bound_args);
        c.* = .{
            .func = closure.func,
            .arity = closure.arity,
            .upvalues = uv_ptr[0..closure.upvalues.len],
            .bound_args = ba_ptr[0..closure.bound_args.len],
            .self_upvalue_idx = closure.self_upvalue_idx,
        };
        return .{ .ref = &c.header };
    }

    /// 构造部分应用值，绑定部分参数
    /// 连续内存布局：[PartialApplication header | bound_args[]]
    pub fn makePartial(tctx: *ThreadContext, func: Value, bound_args: []Value, remaining_arity: u8) !Value {
        const ba_size = bound_args.len * @sizeOf(Value);
        const total = @sizeOf(PartialApplication) + ba_size;
        const mem = try tctx.allocObj(total);
        const p: *PartialApplication = @ptrCast(@alignCast(mem.ptr));
        const ba_ptr: [*]Value = @ptrCast(@alignCast(mem.ptr + @sizeOf(PartialApplication)));
        @memcpy(ba_ptr[0..bound_args.len], bound_args);
        p.* = .{ .func = func, .bound_args = ba_ptr[0..bound_args.len], .remaining_arity = remaining_arity };
        return .{ .ref = &p.header };
    }

    /// 构造内置函数值（固定大小）
    pub fn makeBuiltin(tctx: *ThreadContext, fn_ptr: BuiltinFn, user_ctx: ?*anyopaque) !Value {
        const b = try tctx.createObj(Builtin);
        b.* = .{ .fn_ptr = fn_ptr, .user_ctx = user_ctx };
        return .{ .ref = &b.header };
    }

    /// 构造错误值，携带类型名和消息
    /// 连续内存布局：[ErrorValue header | type_name bytes | message bytes]
    /// type_name 和 message 切片指向尾部连续区域，单次分配单次释放
    pub fn makeError(tctx: *ThreadContext, type_name: []const u8, message: []const u8, is_error_subtype: bool) !Value {
        const total = @sizeOf(ErrorValue) + type_name.len + message.len;
        const mem = try tctx.allocObj(total);
        const e: *ErrorValue = @ptrCast(@alignCast(mem.ptr));
        const tn_ptr: [*]u8 = mem.ptr + @sizeOf(ErrorValue);
        const msg_ptr: [*]u8 = tn_ptr + type_name.len;
        @memcpy(tn_ptr[0..type_name.len], type_name);
        @memcpy(msg_ptr[0..message.len], message);
        e.* = .{
            .type_name = tn_ptr[0..type_name.len],
            .message = msg_ptr[0..message.len],
            .is_error_subtype = is_error_subtype,
        };
        return .{ .ref = &e.header };
    }

    /// 构造抛出值，封装成功值或错误载荷（固定大小）
    pub fn makeThrow(tctx: *ThreadContext, payload: ThrowValue.Payload) !Value {
        const t = try tctx.createObj(ThrowValue);
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
    pub fn release(self: Value, tctx: *ThreadContext) void {
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
                            s.deinit(tctx);
                            tctx.freeObj(@ptrCast(s));
                        }
                        return;
                    }
                }
                obj_header.release(obj, tctx);
            },
        }
    }

    // ════════════════════════════════════════════
    // 深拷贝
    // ════════════════════════════════════════════

    /// 深拷贝值：标量值原样返回，堆分配值递归复制其内容
    pub fn deepCopy(self: Value, tctx: *ThreadContext) AllocError!Value {
        switch (self) {
            .null_val, .unit, .boolean, .char,
            .i8, .i16, .i32, .i64, .i128,
            .u8, .u16, .u32, .u64, .u128,
            .f16, .f32, .f64, .f128 => return self,

            .ref => |obj| {
                return switch (obj.type_tag) {
                    .str => try deepCopyStr(obj, tctx),
                    .array => try deepCopyArray(obj, tctx),
                    .record => try deepCopyRecord(obj, tctx),
                    .adt => try deepCopyAdt(obj, tctx),
                    .newtype => try deepCopyNewtype(obj, tctx),
                    .cell => try deepCopyCell(obj, tctx),
                    .range => try deepCopyRange(obj, tctx),
                    .closure => try deepCopyClosure(obj, tctx),
                    .partial => try deepCopyPartial(obj, tctx),
                    .builtin => try deepCopyBuiltin(obj, tctx),
                    .error_val => try deepCopyError(obj, tctx),
                    .throw_val => try deepCopyThrow(obj, tctx),
                    .trait_val => try deepCopyTrait(obj, tctx),
                    // 迭代器、惰性值、并发对象：引用语义，retain 即可
                    .array_iter, .string_iter, .range_iter,
                    .lazy_val,
                    .atomic_val, .async_val, .channel_val, .sender_val, .receiver_val => self.retain(),
                };
            },
        }
    }

    fn deepCopyStr(obj: *ObjHeader, tctx: *ThreadContext) AllocError!Value {
        const s: *Str = @alignCast(@fieldParentPtr("header", obj));
        return try Value.fromStringBytes(tctx, s.bytes());
    }

    fn deepCopyArray(obj: *ObjHeader, tctx: *ThreadContext) AllocError!Value {
        const p: *ArrayValue = @alignCast(@fieldParentPtr("header", obj));
        // header 和 elements 分离分配（支持后续 push/pop 替换切片）
        const new_elems: []Value = if (p.elements.len > 0) blk: {
            const buf = try tctx.allocObj(p.elements.len * @sizeOf(Value));
            break :blk @as([*]Value, @ptrCast(@alignCast(buf.ptr)))[0..p.elements.len];
        } else &.{};
        errdefer if (p.elements.len > 0) tctx.freeObj(@ptrCast(new_elems.ptr));
        var copied: usize = 0;
        errdefer {
            for (new_elems[0..copied]) |e| e.release(tctx);
        }
        for (p.elements, 0..) |elem, i| {
            new_elems[i] = try elem.deepCopy(tctx);
            copied += 1;
        }
        const arr = try tctx.createObj(ArrayValue);
        arr.* = .{
            .elements = new_elems,
            .capacity = new_elems.len,
            .fixed_size = p.fixed_size,
        };
        return .{ .ref = &arr.header };
    }

    fn deepCopyRecord(obj: *ObjHeader, tctx: *ThreadContext) AllocError!Value {
        const p: *RecordValue = @alignCast(@fieldParentPtr("header", obj));
        // 连续内存布局：[RecordValue header | Value fields[]]
        const f_size = p.fields.len * @sizeOf(Value);
        const total = @sizeOf(RecordValue) + f_size;
        const mem = try tctx.allocObj(total);
        const rec: *RecordValue = @ptrCast(@alignCast(mem.ptr));
        const f_ptr: [*]Value = @ptrCast(@alignCast(mem.ptr + @sizeOf(RecordValue)));
        const new_fields = f_ptr[0..p.fields.len];
        var copied: usize = 0;
        errdefer {
            for (new_fields[0..copied]) |*v| v.release(tctx);
            tctx.freeObj(@ptrCast(rec));
        }
        for (p.fields, 0..) |src, i| {
            new_fields[i] = try src.deepCopy(tctx);
            copied = i + 1;
        }
        rec.* = .{ .type_name = p.type_name, .fields = new_fields, .field_names = p.field_names };
        return .{ .ref = &rec.header };
    }

    fn deepCopyAdt(obj: *ObjHeader, tctx: *ThreadContext) AllocError!Value {
        const p: *AdtValue = @alignCast(@fieldParentPtr("header", obj));
        // 连续内存布局：[AdtValue header | AdtField fields[]]
        const f_size = p.fields.len * @sizeOf(AdtField);
        const total = @sizeOf(AdtValue) + f_size;
        const mem = try tctx.allocObj(total);
        const adt: *AdtValue = @ptrCast(@alignCast(mem.ptr));
        const f_ptr: [*]AdtField = @ptrCast(@alignCast(mem.ptr + @sizeOf(AdtValue)));
        const new_fields = f_ptr[0..p.fields.len];
        var copied: usize = 0;
        errdefer {
            for (new_fields[0..copied]) |*f| f.value.release(tctx);
            tctx.freeObj(@ptrCast(adt));
        }
        for (p.fields, 0..) |f, i| {
            new_fields[i] = .{
                .name = f.name,
                .value = try f.value.deepCopy(tctx),
            };
            copied += 1;
        }
        adt.* = .{
            .type_name = p.type_name,
            .constructor = p.constructor,
            .fields = new_fields,
        };
        return .{ .ref = &adt.header };
    }

    fn deepCopyNewtype(obj: *ObjHeader, tctx: *ThreadContext) AllocError!Value {
        const p: *NewtypeValue = @alignCast(@fieldParentPtr("header", obj));
        return try Value.makeNewtype(tctx, p.type_name, try p.inner.deepCopy(tctx));
    }

    fn deepCopyCell(obj: *ObjHeader, tctx: *ThreadContext) AllocError!Value {
        const p: *Cell = @alignCast(@fieldParentPtr("header", obj));
        return try Value.makeCell(tctx, try p.inner.deepCopy(tctx));
    }

    fn deepCopyRange(obj: *ObjHeader, tctx: *ThreadContext) AllocError!Value {
        const p: *Range = @alignCast(@fieldParentPtr("header", obj));
        return try Value.makeRange(tctx, p.start, p.end, p.inclusive);
    }

    fn deepCopyClosure(obj: *ObjHeader, tctx: *ThreadContext) AllocError!Value {
        const p: *Closure = @alignCast(@fieldParentPtr("header", obj));
        // 连续内存布局：[Closure header | upvalues[] | bound_args[]]
        const uv_size = p.upvalues.len * @sizeOf(Value);
        const ba_size = p.bound_args.len * @sizeOf(Value);
        const total = @sizeOf(Closure) + uv_size + ba_size;
        const mem = try tctx.allocObj(total);
        const c: *Closure = @ptrCast(@alignCast(mem.ptr));
        const uv_ptr: [*]Value = @ptrCast(@alignCast(mem.ptr + @sizeOf(Closure)));
        const ba_ptr: [*]Value = @ptrCast(@alignCast(mem.ptr + @sizeOf(Closure) + uv_size));
        const new_upvalues = uv_ptr[0..p.upvalues.len];
        const new_bound_args = ba_ptr[0..p.bound_args.len];
        var uv_copied: usize = 0;
        var ba_copied: usize = 0;
        errdefer {
            for (new_upvalues[0..uv_copied]) |e| e.release(tctx);
            for (new_bound_args[0..ba_copied]) |e| e.release(tctx);
            tctx.freeObj(@ptrCast(c));
        }
        for (p.upvalues, 0..) |uv, i| {
            new_upvalues[i] = try uv.deepCopy(tctx);
            uv_copied += 1;
        }
        for (p.bound_args, 0..) |ba, i| {
            new_bound_args[i] = try ba.deepCopy(tctx);
            ba_copied += 1;
        }
        c.* = .{
            .func = p.func,
            .arity = p.arity,
            .upvalues = new_upvalues,
            .bound_args = new_bound_args,
            .self_upvalue_idx = p.self_upvalue_idx,
        };
        return .{ .ref = &c.header };
    }

    fn deepCopyPartial(obj: *ObjHeader, tctx: *ThreadContext) AllocError!Value {
        const p: *PartialApplication = @alignCast(@fieldParentPtr("header", obj));
        // 连续内存布局：[PartialApplication header | bound_args[]]
        const ba_size = p.bound_args.len * @sizeOf(Value);
        const total = @sizeOf(PartialApplication) + ba_size;
        const mem = try tctx.allocObj(total);
        const pa: *PartialApplication = @ptrCast(@alignCast(mem.ptr));
        const ba_ptr: [*]Value = @ptrCast(@alignCast(mem.ptr + @sizeOf(PartialApplication)));
        const new_bound_args = ba_ptr[0..p.bound_args.len];
        const new_func = try p.func.deepCopy(tctx);
        var ba_copied: usize = 0;
        errdefer {
            new_func.release(tctx);
            for (new_bound_args[0..ba_copied]) |e| e.release(tctx);
            tctx.freeObj(@ptrCast(pa));
        }
        for (p.bound_args, 0..) |ba, i| {
            new_bound_args[i] = try ba.deepCopy(tctx);
            ba_copied += 1;
        }
        pa.* = .{
            .func = new_func,
            .bound_args = new_bound_args,
            .remaining_arity = p.remaining_arity,
        };
        return .{ .ref = &pa.header };
    }

    fn deepCopyBuiltin(obj: *ObjHeader, tctx: *ThreadContext) AllocError!Value {
        const p: *Builtin = @alignCast(@fieldParentPtr("header", obj));
        return try Value.makeBuiltin(tctx, p.fn_ptr, p.user_ctx);
    }

    fn deepCopyError(obj: *ObjHeader, tctx: *ThreadContext) AllocError!Value {
        const p: *ErrorValue = @alignCast(@fieldParentPtr("header", obj));
        // 连续内存布局：[ErrorValue header | type_name | message]
        return try Value.makeError(tctx, p.type_name, p.message, p.is_error_subtype);
    }

    fn deepCopyThrow(obj: *ObjHeader, tctx: *ThreadContext) AllocError!Value {
        const p: *ThrowValue = @alignCast(@fieldParentPtr("header", obj));
        switch (p.payload) {
            .ok => |v| return try Value.makeThrow(tctx, .{ .ok = try v.deepCopy(tctx) }),
            .err => |e| {
                // 深拷贝 ErrorValue（连续内存），引用计数为 1，所有权转给 ThrowValue
                const err_val = try Value.makeError(tctx, e.type_name, e.message, e.is_error_subtype);
                const new_e: *ErrorValue = @alignCast(@fieldParentPtr("header", err_val.ref));
                return try Value.makeThrow(tctx, .{ .err = new_e });
            },
        }
    }

    fn deepCopyTrait(obj: *ObjHeader, tctx: *ThreadContext) AllocError!Value {
        const p: *TraitValue = @alignCast(@fieldParentPtr("header", obj));
        if (!p.owned) return Value.fromRef(obj).retain();
        const count = p.method_names.len;
        // 连续内存布局：[TraitValue header | method_values[]]
        const mv_size = count * @sizeOf(Value);
        const total = @sizeOf(TraitValue) + mv_size;
        const mem = try tctx.allocObj(total);
        const tv: *TraitValue = @ptrCast(@alignCast(mem.ptr));
        const mv_ptr: [*]Value = @ptrCast(@alignCast(mem.ptr + @sizeOf(TraitValue)));
        const new_values = mv_ptr[0..count];
        // method_names 独立分配：指针数组 + 每个名字字符串
        const names_mem = if (count > 0) try tctx.allocObj(count * @sizeOf([]const u8)) else &.{};
        const new_names: [][]const u8 = if (count > 0) @as([*][]const u8, @ptrCast(@alignCast(@constCast(names_mem.ptr))))[0..count] else &.{};
        var names_copied: usize = 0;
        var values_copied: usize = 0;
        errdefer {
            for (new_names[0..names_copied]) |n| if (n.len > 0) tctx.freeObj(@ptrCast(@constCast(n.ptr)));
            if (count > 0) tctx.freeObj(@ptrCast(new_names.ptr));
            for (new_values[0..values_copied]) |v| v.release(tctx);
            tctx.freeObj(@ptrCast(tv));
        }
        for (p.method_names, 0..) |name, i| {
            const name_buf = try tctx.allocObj(name.len);
            @memcpy(name_buf, name);
            new_names[i] = name_buf;
            names_copied += 1;
        }
        for (p.method_values, 0..) |val, i| {
            new_values[i] = try val.deepCopy(tctx);
            values_copied += 1;
        }
        const new_data: ?Value = if (p.data) |d| try d.deepCopy(tctx) else null;
        errdefer if (new_data) |d| d.release(tctx);
        tv.* = .{
            .trait_name = p.trait_name,
            .method_names = new_names,
            .method_values = new_values,
            .data = new_data,
            .owned = true,
        };
        return .{ .ref = &tv.header };
    }

    // ════════════════════════════════════════════
    // 格式化
    // ════════════════════════════════════════════

    /// 将值格式化为可读字符串，追加到 buf
    /// 使用 tctx.backing 作为 ArrayList 分配器（format 为非热路径）
    pub fn format(self: Value, tctx: *ThreadContext, buf: *std.ArrayList(u8)) !void {
        const al = tctx.backing;
        switch (self) {
            .null_val => try buf.appendSlice(al, "null"),
            .unit => try buf.appendSlice(al, "()"),
            .boolean => try buf.appendSlice(al, if (self.asBool()) "true" else "false"),
            .char => {
                var temp: [16]u8 = undefined;
                const s = std.fmt.bufPrint(&temp, "'{u}'", .{self.asChar().toNative()}) catch unreachable;
                try buf.appendSlice(al, s);
            },
            .i8 => try formatInt(self.asI8(), tctx, buf),
            .i16 => try formatInt(self.asI16(), tctx, buf),
            .i32 => try formatInt(self.asI32(), tctx, buf),
            .i64 => try formatInt(self.asI64(), tctx, buf),
            .i128 => try formatInt(self.asI128(), tctx, buf),
            .u8 => try formatInt(self.asU8(), tctx, buf),
            .u16 => try formatInt(self.asU16(), tctx, buf),
            .u32 => try formatInt(self.asU32(), tctx, buf),
            .u64 => try formatInt(self.asU64(), tctx, buf),
            .u128 => try formatInt(self.asU128(), tctx, buf),
            .f16 => try formatFloat(self.asF16(), tctx, buf),
            .f32 => try formatFloat(self.asF32(), tctx, buf),
            .f64 => try formatFloat(self.asF64(), tctx, buf),
            .f128 => try formatFloat(self.asF128(), tctx, buf),

            .ref => |obj| {
                switch (obj.type_tag) {
                    .str => {
                        const s: *Str = @alignCast(@fieldParentPtr("header", obj));
                        try buf.append(al, '"');
                        try buf.appendSlice(al, s.bytes());
                        try buf.append(al, '"');
                    },
                    .array => {
                        const arr: *ArrayValue = @alignCast(@fieldParentPtr("header", obj));
                        try buf.append(al, '[');
                        for (arr.elements, 0..) |elem, i| {
                            if (i > 0) try buf.appendSlice(al, ", ");
                            try elem.format(tctx, buf);
                        }
                        try buf.append(al, ']');
                    },
                    .record => {
                        const rec: *RecordValue = @alignCast(@fieldParentPtr("header", obj));
                        try buf.appendSlice(al, rec.type_name);
                        try buf.append(al, '{');
                        for (rec.fields, 0..) |v, i| {
                            if (i > 0) try buf.appendSlice(al, ", ");
                            // 优先用字段名表，无则用 _<id>
                            if (i < rec.field_names.len) {
                                if (rec.field_names[i]) |nm| {
                                    try buf.appendSlice(al, nm);
                                } else {
                                    try buf.appendSlice(al, "_");
                                    try formatInt(i, tctx, buf);
                                }
                            } else {
                                try buf.appendSlice(al, "_");
                                try formatInt(i, tctx, buf);
                            }
                            try buf.appendSlice(al, ": ");
                            try v.format(tctx, buf);
                        }
                        try buf.append(al, '}');
                    },
                    .adt => {
                        const adt: *AdtValue = @alignCast(@fieldParentPtr("header", obj));
                        try buf.appendSlice(al, adt.type_name);
                        try buf.appendSlice(al, "::");
                        try buf.appendSlice(al, adt.constructor);
                        if (adt.fields.len > 0) {
                            try buf.append(al, '(');
                            for (adt.fields, 0..) |field, i| {
                                if (i > 0) try buf.appendSlice(al, ", ");
                                try field.value.format(tctx, buf);
                            }
                            try buf.append(al, ')');
                        }
                    },
                    .newtype => {
                        const nt: *NewtypeValue = @alignCast(@fieldParentPtr("header", obj));
                        try buf.appendSlice(al, nt.type_name);
                        try buf.append(al, '(');
                        try nt.inner.format(tctx, buf);
                        try buf.append(al, ')');
                    },
                    .cell => {
                        const cell: *Cell = @alignCast(@fieldParentPtr("header", obj));
                        try buf.appendSlice(al, "Cell(");
                        try cell.inner.format(tctx, buf);
                        try buf.append(al, ')');
                    },
                    .range => {
                        const r: *Range = @alignCast(@fieldParentPtr("header", obj));
                        try buf.appendSlice(al, "<range>");
                        _ = r;
                    },
                    .closure => try buf.appendSlice(al, "<closure>"),
                    .partial => try buf.appendSlice(al, "<partial>"),
                    .builtin => try buf.appendSlice(al, "<builtin>"),
                    .error_val => {
                        const e: *ErrorValue = @alignCast(@fieldParentPtr("header", obj));
                        try buf.appendSlice(al, "Error(");
                        try buf.appendSlice(al, e.type_name);
                        try buf.appendSlice(al, ": ");
                        try buf.appendSlice(al, e.message);
                        try buf.append(al, ')');
                    },
                    .throw_val => try buf.appendSlice(al, "<throw>"),
                    .array_iter => try buf.appendSlice(al, "<array_iter>"),
                    .string_iter => try buf.appendSlice(al, "<string_iter>"),
                    .range_iter => try buf.appendSlice(al, "<range_iter>"),
                    .atomic_val => try buf.appendSlice(al, "<atomic>"),
                    .async_val => try buf.appendSlice(al, "<async>"),
                    .channel_val => try buf.appendSlice(al, "<channel>"),
                    .sender_val => try buf.appendSlice(al, "<sender>"),
                    .receiver_val => try buf.appendSlice(al, "<receiver>"),
                    .trait_val => try buf.appendSlice(al, "<trait>"),
                    .lazy_val => try buf.appendSlice(al, "<lazy>"),
                }
            },
        }
    }

    /// 格式化值并返回新分配的字符串切片
    /// 使用 tctx.backing 分配，调用方需用 tctx.backing.free 释放
    pub fn formatAlloc(self: Value, tctx: *ThreadContext) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(tctx.backing);
        try self.format(tctx, &buf);
        return buf.toOwnedSlice(tctx.backing);
    }
};

// ════════════════════════════════════════════════════════════
// 模块级工具函数
// ════════════════════════════════════════════════════════════

/// 格式化整数到 buf（使用 tctx.backing 作为 ArrayList 分配器）
fn formatInt(v: anytype, tctx: *ThreadContext, buf: *std.ArrayList(u8)) !void {
    var temp: [41]u8 = undefined;
    const s = std.fmt.bufPrint(&temp, "{d}", .{v}) catch unreachable;
    try buf.appendSlice(tctx.backing, s);
}

/// 格式化浮点数到 buf（使用 tctx.backing 作为 ArrayList 分配器）
fn formatFloat(v: anytype, tctx: *ThreadContext, buf: *std.ArrayList(u8)) !void {
    var temp: [80]u8 = undefined;
    const s = std.fmt.bufPrint(&temp, "{d}", .{v}) catch unreachable;
    try buf.appendSlice(tctx.backing, s);
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
                    // 字段按 field_id 顺序存储，同类型 record 字段顺序一致
                    if (ra.fields.len != rb.fields.len) break :blk false;
                    for (ra.fields, rb.fields) |va, vb| {
                        if (!equals(va, vb)) break :blk false;
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
