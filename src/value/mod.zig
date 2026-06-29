//! Glue 语言运行时值表示 - 新统一 Value（union(enum) 24B）
//!
//! 根本动机：规避 LLVM 在 Linux 上 i128/u128/f128 的 codegen bug。
//! - 数值用 [N]u8 软件实现（Int/Float 内联在 Value union，无装箱）
//! - 复合类型每类型独立 struct（首字段 rc:u32），Value 持 *T 指针
//! - 旧 BoxedValue 统一装箱头部废弃，每 struct 自管 rc + deinit
//!
//! 物理布局：union(enum) 24B 定长，最大 payload = Int/Float = 18B，
//! 对齐 8 → 24B，tag 落入 padding。平凡可拷贝（POD + 指针）。
//!
//! 文件结构：
//! - byte_array.zig: ByteArray union（b1/b2/b4/b8/b16）
//! - int.zig:   Type 枚举 + Int 结构体（含加减乘除/位运算/位移/取负/inRange/fromName）
//! - float.zig: Type 枚举 + Float 结构体（f8/f16/f32/f64/f128 全软件 IEEE 754）
//! - char.zig:  Char 结构体（[4]u8 UTF-32 码点存储）
//! - str.zig:   Str 结构体（[]u8 UTF-8 + rc + allocator 管理）
//! - composite.zig:    ArrayValue/RecordValue/AdtValue/AdtField/NewtypeValue/Cell/Range
//! - callable.zig:     VmClosure/PartialApplication/Builtin/TraitValue/LazyValue
//! - control.zig:      ErrorValue/ThrowValue
//! - iterator.zig:     ArrayIterator/StringIterator/RangeIterator
//! - runtime_bridge.zig: re-export runtime/ 的 AtomicValue/SpawnHandle/ChannelValue/SenderValue/ReceiverValue

const std = @import("std");
const ast = @import("ast");

// ============================================================
// 子模块再导出
// ============================================================

pub const byte_array = @import("byte_array.zig");
pub const ByteArray = byte_array.ByteArray;

pub const int = @import("int.zig");
pub const IntType = int.Type;
pub const Int = int.Int;

pub const float = @import("float.zig");
pub const FloatType = float.Type;
pub const FloatUnpacked = float.Unpacked;
pub const Float = float.Float;

pub const char_mod = @import("char.zig");
pub const Char = char_mod.Char;

pub const str_mod = @import("str.zig");
pub const Str = str_mod.Str;

pub const composite = @import("composite.zig");
pub const ArrayValue = composite.ArrayValue;
pub const RecordValue = composite.RecordValue;
pub const AdtValue = composite.AdtValue;
pub const AdtField = composite.AdtField;
pub const NewtypeValue = composite.NewtypeValue;
pub const Cell = composite.Cell;
pub const Range = composite.Range;

pub const callable = @import("callable.zig");
pub const BuiltinFn = callable.BuiltinFn;
pub const Builtin = callable.Builtin;
pub const VmClosure = callable.VmClosure;
pub const PartialApplication = callable.PartialApplication;
pub const TraitValue = callable.TraitValue;
pub const LazyValue = callable.LazyValue;

pub const control = @import("control.zig");
pub const ErrorValue = control.ErrorValue;
pub const ThrowValue = control.ThrowValue;

pub const iterator = @import("iterator.zig");
pub const ArrayIterator = iterator.ArrayIterator;
pub const StringIterator = iterator.StringIterator;
pub const RangeIterator = iterator.RangeIterator;

pub const runtime_bridge = @import("runtime_bridge.zig");
pub const AtomicValue = runtime_bridge.AtomicValue;
pub const SpawnHandle = runtime_bridge.SpawnHandle;
pub const ChannelValue = runtime_bridge.ChannelValue;
pub const SenderValue = runtime_bridge.SenderValue;
pub const ReceiverValue = runtime_bridge.ReceiverValue;
pub const atomicTypeToIntType = runtime_bridge.atomicTypeToIntType;
pub const intTypeToAtomicType = runtime_bridge.intTypeToAtomicType;

// ============================================================
// 错误与控制流（与旧 value.zig 一致）
// ============================================================

pub const EvalError = error{
    OutOfMemory,
    TypeMismatch,
    UndefinedVariable,
    ImmutableAssignment,
    NotCallable,
    WrongArity,
    IndexOutOfBounds,
    UnsupportedOperation,
    CircularDependency,
    FileNotFound,
    MissingMain,
    TypeCheckFailed,
};

pub const ControlFlow = error{
    ReturnValue,
    ThrowValue,
    BreakSignal,
    ContinueSignal,
    GluePanic,
    TailCall,
};

pub const EvalResult = EvalError || ControlFlow;

// ============================================================
// 统一 Value union（24B 定长）
// ============================================================

/// Glue 运行时统一值类型
///
/// 内联变体（无堆分配）：null_val/unit/boolean/char/int/float
/// 装箱变体（持 *T 指针，T 首 rc:u32）：string/array/record/adt/newtype/cell/range/
///   vm_closure/partial/builtin/error_val/throw_val/
///   array_iterator/string_iterator/range_iterator/
///   atomic_val/spawn_val/channel_val/sender_val/receiver_val/
///   trait_value/lazy_val
pub const Value = union(enum) {
    // 内联标量
    null_val,
    unit,
    boolean: bool,
    char: Char,
    // 内联数值（~18B，无装箱）
    int: Int,
    float: Float,
    // 装箱复合
    string: *Str,
    array: *ArrayValue,
    record: *RecordValue,
    adt: *AdtValue,
    newtype: *NewtypeValue,
    cell: *Cell,
    range: *Range,
    // 装箱可调用
    vm_closure: *VmClosure,
    partial: *PartialApplication,
    builtin: *Builtin,
    // 装箱控制流
    error_val: *ErrorValue,
    throw_val: *ThrowValue,
    // 装箱迭代器
    array_iterator: *ArrayIterator,
    string_iterator: *StringIterator,
    range_iterator: *RangeIterator,
    // 装箱并发原语（runtime 类型自管 rc）
    atomic_val: *AtomicValue,
    spawn_val: *SpawnHandle,
    channel_val: *ChannelValue,
    sender_val: *SenderValue,
    receiver_val: *ReceiverValue,
    // 装箱高级
    trait_value: *TraitValue,
    lazy_val: *LazyValue,

    // ============================================================
    // 构造函数（内联，无 allocator）
    // ============================================================

    pub inline fn fromNull() Value {
        return .null_val;
    }

    pub inline fn fromUnit() Value {
        return .unit;
    }

    pub inline fn fromBool(b: bool) Value {
        return .{ .boolean = b };
    }

    pub inline fn fromChar(c: Char) Value {
        return .{ .char = c };
    }

    pub inline fn fromInt(i: Int) Value {
        return .{ .int = i };
    }

    pub inline fn fromFloat(f: Float) Value {
        return .{ .float = f };
    }

    // ============================================================
    // 构造函数（装箱，需 allocator）
    // ============================================================

    pub fn fromString(allocator: std.mem.Allocator, s: *Str) !Value {
        _ = allocator;
        return .{ .string = s };
    }

    /// 从字节切片构造 string Value（创建 *Str，dupe 字节）
    pub fn fromStringBytes(allocator: std.mem.Allocator, bytes: []const u8) !Value {
        const s = try allocator.create(Str);
        s.* = try Str.fromLiteral(allocator, bytes);
        return .{ .string = s };
    }

    pub fn makeArray(allocator: std.mem.Allocator, elements: []Value, fixed_size: ?u64) !Value {
        const arr = try allocator.create(ArrayValue);
        arr.* = .{ .elements = elements, .capacity = elements.len, .fixed_size = fixed_size };
        return .{ .array = arr };
    }

    pub fn makeRecord(allocator: std.mem.Allocator, type_name: []const u8, fields: std.StringHashMap(Value)) !Value {
        const rec = try allocator.create(RecordValue);
        rec.* = .{ .type_name = type_name, .fields = fields };
        return .{ .record = rec };
    }

    pub fn makeAdt(allocator: std.mem.Allocator, type_name: []const u8, constructor: []const u8, fields: []AdtField) !Value {
        const adt = try allocator.create(AdtValue);
        adt.* = .{ .type_name = type_name, .constructor = constructor, .fields = fields };
        return .{ .adt = adt };
    }

    pub fn makeNewtype(allocator: std.mem.Allocator, type_name: []const u8, inner: Value) !Value {
        const nt = try allocator.create(NewtypeValue);
        nt.* = .{ .type_name = type_name, .inner = inner };
        return .{ .newtype = nt };
    }

    pub fn makeCell(allocator: std.mem.Allocator, inner: Value) !Value {
        const cell = try allocator.create(Cell);
        cell.* = .{ .inner = inner };
        return .{ .cell = cell };
    }

    pub fn makeRange(allocator: std.mem.Allocator, start: Int, end: Int, inclusive: bool) !Value {
        const r = try allocator.create(Range);
        r.* = .{ .start = start, .end = end, .inclusive = inclusive };
        return .{ .range = r };
    }

    pub fn makeVmClosure(allocator: std.mem.Allocator, closure: VmClosure) !Value {
        const c = try allocator.create(VmClosure);
        c.* = closure;
        return .{ .vm_closure = c };
    }

    pub fn makePartial(allocator: std.mem.Allocator, func: Value, bound_args: []Value, remaining_arity: u8) !Value {
        const p = try allocator.create(PartialApplication);
        p.* = .{ .func = func, .bound_args = bound_args, .remaining_arity = remaining_arity };
        return .{ .partial = p };
    }

    pub fn makeBuiltin(allocator: std.mem.Allocator, fn_ptr: BuiltinFn, user_ctx: ?*anyopaque) !Value {
        const b = try allocator.create(Builtin);
        b.* = .{ .fn_ptr = fn_ptr, .user_ctx = user_ctx };
        return .{ .builtin = b };
    }

    pub fn makeError(allocator: std.mem.Allocator, type_name: []const u8, message: []const u8, is_error_subtype: bool) !Value {
        const e = try allocator.create(ErrorValue);
        e.* = .{ .type_name = type_name, .message = message, .is_error_subtype = is_error_subtype };
        return .{ .error_val = e };
    }

    pub fn makeThrow(allocator: std.mem.Allocator, payload: ThrowValue.Payload) !Value {
        const t = try allocator.create(ThrowValue);
        t.* = .{ .payload = payload };
        return .{ .throw_val = t };
    }

    pub fn fromSender(allocator: std.mem.Allocator, sv: *SenderValue) !Value {
        _ = allocator;
        return .{ .sender_val = sv };
    }

    pub fn fromReceiver(allocator: std.mem.Allocator, rv: *ReceiverValue) !Value {
        _ = allocator;
        return .{ .receiver_val = rv };
    }

    // ============================================================
    // 访问器
    // ============================================================

    pub inline fn asBool(self: Value) bool {
        return self.boolean;
    }

    pub inline fn asChar(self: Value) Char {
        return self.char;
    }

    pub inline fn asInt(self: Value) Int {
        return self.int;
    }

    pub inline fn asFloat(self: Value) Float {
        return self.float;
    }

    // ============================================================
    // 类型谓词
    // ============================================================

    pub fn isBoxed(self: Value) bool {
        return switch (self) {
            .null_val, .unit, .boolean, .char, .int, .float => false,
            else => true,
        };
    }

    pub fn isInteger(self: Value) bool {
        return self == .int;
    }

    pub fn isFloat(self: Value) bool {
        return self == .float;
    }

    pub fn isNumeric(self: Value) bool {
        return self == .int or self == .float;
    }

    pub fn isString(self: Value) bool {
        return self == .string;
    }

    // ============================================================
    // 引用计数
    // ============================================================

    /// retain：增加引用计数，返回 self
    /// 内联变体原样返回；装箱变体 ptr.rc += 1；runtime 类型（atomic/channel/sender/receiver）调对应 ref()
    pub inline fn retain(self: Value) Value {
        switch (self) {
            .null_val, .unit, .boolean, .char, .int, .float => {},
            .string => |p| p.rc += 1,
            .array => |p| p.rc += 1,
            .record => |p| p.rc += 1,
            .adt => |p| p.rc += 1,
            .newtype => |p| p.rc += 1,
            .cell => |p| p.rc += 1,
            .range => |p| p.rc += 1,
            .vm_closure => |p| p.rc += 1,
            .partial => |p| p.rc += 1,
            .builtin => |p| p.rc += 1,
            .error_val => |p| p.rc += 1,
            .throw_val => |p| p.rc += 1,
            .array_iterator => |p| p.rc += 1,
            .string_iterator => |p| p.rc += 1,
            .range_iterator => |p| p.rc += 1,
            .atomic_val => |p| p.ref(),
            .spawn_val => {},
            .channel_val => |p| p.ref(),
            .sender_val => |p| p.ref(),
            .receiver_val => |p| p.ref(),
            .trait_value => |p| p.rc += 1,
            .lazy_val => |p| p.rc += 1,
        }
        return self;
    }

    /// release：减少引用计数，归零则 deinit + destroy
    /// 内联变体 noop；装箱变体 if rc>1 rc-=1 else { ptr.deinit(alloc); alloc.destroy(ptr) }
    pub fn release(self: Value, allocator: std.mem.Allocator) void {
        switch (self) {
            .null_val, .unit, .boolean, .char, .int, .float => {},
            .string => |p| {
                if (p.rc > 1) {
                    p.rc -= 1;
                } else {
                    p.deinit();
                    allocator.destroy(p);
                }
            },
            .array => |p| {
                if (p.rc > 1) {
                    p.rc -= 1;
                } else {
                    p.deinit(allocator);
                    allocator.destroy(p);
                }
            },
            .record => |p| {
                if (p.rc > 1) {
                    p.rc -= 1;
                } else {
                    p.deinit(allocator);
                    allocator.destroy(p);
                }
            },
            .adt => |p| {
                if (p.rc > 1) {
                    p.rc -= 1;
                } else {
                    p.deinit(allocator);
                    allocator.destroy(p);
                }
            },
            .newtype => |p| {
                if (p.rc > 1) {
                    p.rc -= 1;
                } else {
                    p.deinit(allocator);
                    allocator.destroy(p);
                }
            },
            .cell => |p| {
                if (p.rc > 1) {
                    p.rc -= 1;
                } else {
                    p.deinit(allocator);
                    allocator.destroy(p);
                }
            },
            .range => |p| {
                if (p.rc > 1) {
                    p.rc -= 1;
                } else {
                    p.deinit(allocator);
                    allocator.destroy(p);
                }
            },
            .vm_closure => |p| {
                if (p.rc > 1) {
                    p.rc -= 1;
                } else {
                    p.deinit(allocator);
                    allocator.destroy(p);
                }
            },
            .partial => |p| {
                if (p.rc > 1) {
                    p.rc -= 1;
                } else {
                    p.deinit(allocator);
                    allocator.destroy(p);
                }
            },
            .builtin => |p| {
                if (p.rc > 1) {
                    p.rc -= 1;
                } else {
                    p.deinit(allocator);
                    allocator.destroy(p);
                }
            },
            .error_val => |p| {
                if (p.rc > 1) {
                    p.rc -= 1;
                } else {
                    p.deinit(allocator);
                    allocator.destroy(p);
                }
            },
            .throw_val => |p| {
                if (p.rc > 1) {
                    p.rc -= 1;
                } else {
                    p.deinit(allocator);
                    allocator.destroy(p);
                }
            },
            .array_iterator => |p| {
                if (p.rc > 1) {
                    p.rc -= 1;
                } else {
                    p.deinit(allocator);
                    allocator.destroy(p);
                }
            },
            .string_iterator => |p| {
                if (p.rc > 1) {
                    p.rc -= 1;
                } else {
                    p.deinit(allocator);
                    allocator.destroy(p);
                }
            },
            .range_iterator => |p| {
                if (p.rc > 1) {
                    p.rc -= 1;
                } else {
                    p.deinit(allocator);
                    allocator.destroy(p);
                }
            },
            .atomic_val => |p| {
                if (p.unref()) allocator.destroy(p);
            },
            .spawn_val => {},
            .channel_val => |p| {
                if (p.unref()) allocator.destroy(p);
            },
            .sender_val => |p| {
                if (p.unref()) allocator.destroy(p);
            },
            .receiver_val => |p| {
                if (p.unref()) allocator.destroy(p);
            },
            .trait_value => |p| {
                if (p.rc > 1) {
                    p.rc -= 1;
                } else {
                    p.deinit(allocator);
                    allocator.destroy(p);
                }
            },
            .lazy_val => |p| {
                if (p.rc > 1) {
                    p.rc -= 1;
                } else {
                    p.deinit(allocator);
                    allocator.destroy(p);
                }
            },
        }
    }

    // ============================================================
    // format（软件转十进制；int/float 暂用退化打印）
    // ============================================================

    pub fn format(self: Value, allocator: std.mem.Allocator, buf: *std.ArrayList(u8)) !void {
        switch (self) {
            .null_val => try buf.appendSlice(allocator, "null"),
            .unit => try buf.appendSlice(allocator, "()"),
            .boolean => try buf.appendSlice(allocator, if (self.boolean) "true" else "false"),
            .char => {
                const temp = try std.fmt.allocPrint(allocator, "'{u}'", .{self.char.toNative()});
                defer allocator.free(temp);
                try buf.appendSlice(allocator, temp);
            },
            .int => {
                // 退化：用 toNative(i128) + {d}（对超出 i128 范围的 u128 会 truncate，后续完善）
                const iv = self.int.toNative(i128);
                const temp = try std.fmt.allocPrint(allocator, "{d}", .{iv});
                defer allocator.free(temp);
                try buf.appendSlice(allocator, temp);
            },
            .float => {
                // 退化：用 toNative(f64) + {d}（损失精度，后续软件转十进制）
                const fv = self.float.toNative(f64);
                const temp = try std.fmt.allocPrint(allocator, "{d}", .{fv});
                defer allocator.free(temp);
                try buf.appendSlice(allocator, temp);
            },
            .string => {
                try buf.append(allocator, '"');
                try buf.appendSlice(allocator, self.string.bytes);
                try buf.append(allocator, '"');
            },
            .array => {
                const arr = self.array;
                try buf.append(allocator, '[');
                for (arr.elements, 0..) |elem, i| {
                    if (i > 0) try buf.appendSlice(allocator, ", ");
                    try elem.format(allocator, buf);
                }
                try buf.append(allocator, ']');
            },
            .record => {
                const rec = self.record;
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
                const adt = self.adt;
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
                try buf.appendSlice(allocator, self.newtype.type_name);
                try buf.append(allocator, '(');
                try self.newtype.inner.format(allocator, buf);
                try buf.append(allocator, ')');
            },
            .cell => {
                try buf.appendSlice(allocator, "Cell(");
                try self.cell.inner.format(allocator, buf);
                try buf.append(allocator, ')');
            },
            .range => {
                const r = self.range;
                const start_iv = r.start.toNative(i128);
                const end_iv = r.end.toNative(i128);
                const temp = try std.fmt.allocPrint(allocator, "{d}..{s}{d}", .{ start_iv, if (r.inclusive) "=" else "", end_iv });
                defer allocator.free(temp);
                try buf.appendSlice(allocator, temp);
            },
            .vm_closure => try buf.appendSlice(allocator, "<closure>"),
            .partial => try buf.appendSlice(allocator, "<partial>"),
            .builtin => try buf.appendSlice(allocator, "<builtin>"),
            .error_val => {
                const err = self.error_val;
                try buf.appendSlice(allocator, "Error(");
                try buf.appendSlice(allocator, err.type_name);
                try buf.appendSlice(allocator, ": ");
                try buf.appendSlice(allocator, err.message);
                try buf.append(allocator, ')');
            },
            .throw_val => try buf.appendSlice(allocator, "<throw>"),
            .array_iterator => try buf.appendSlice(allocator, "<array_iter>"),
            .string_iterator => try buf.appendSlice(allocator, "<string_iter>"),
            .range_iterator => try buf.appendSlice(allocator, "<range_iter>"),
            .atomic_val => try buf.appendSlice(allocator, "<atomic>"),
            .spawn_val => try buf.appendSlice(allocator, "<spawn>"),
            .channel_val => try buf.appendSlice(allocator, "<channel>"),
            .sender_val => try buf.appendSlice(allocator, "<sender>"),
            .receiver_val => try buf.appendSlice(allocator, "<receiver>"),
            .trait_value => try buf.appendSlice(allocator, "<trait>"),
            .lazy_val => try buf.appendSlice(allocator, "<lazy>"),
        }
    }

    pub fn formatAlloc(self: Value, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try self.format(allocator, &buf);
        return buf.toOwnedSlice(allocator);
    }
};

// ============================================================
// 工具函数（移植自旧 value.zig，返回 int.Type）
// ============================================================

/// 结构相等（深比较基础/数组/记录/ADT/newtype；其余引用相等）。
pub fn equals(a: Value, b: Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .int => a.asInt().compare(b.asInt()) == .eq,
        .float => {
            const af = a.asFloat();
            const bf = b.asFloat();
            return af.compare(bf) == .eq;
        },
        .boolean => a.asBool() == b.asBool(),
        .char => a.asChar().equals(b.asChar()),
        .string => std.mem.eql(u8, a.string.bytes, b.string.bytes),
        .null_val, .unit => true,
        .range => {
            const ar = a.range;
            const br = b.range;
            return ar.start.compare(br.start) == .eq and ar.end.compare(br.end) == .eq and ar.inclusive == br.inclusive;
        },
        .array => {
            const arr = a.array;
            const barr = b.array;
            if (arr.elements.len != barr.elements.len) return false;
            for (arr.elements, barr.elements) |x, y| {
                if (!equals(x, y)) return false;
            }
            return true;
        },
        .record => {
            const rec = a.record;
            const brec = b.record;
            if (rec.fields.count() != brec.fields.count()) return false;
            var it = rec.fields.iterator();
            while (it.next()) |e| {
                const bv = brec.fields.get(e.key_ptr.*) orelse return false;
                if (!equals(e.value_ptr.*, bv)) return false;
            }
            return true;
        },
        .adt => {
            const av = a.adt;
            const bv = b.adt;
            if (!std.mem.eql(u8, av.type_name, bv.type_name)) return false;
            if (!std.mem.eql(u8, av.constructor, bv.constructor)) return false;
            if (av.fields.len != bv.fields.len) return false;
            for (av.fields, bv.fields) |fa, fb| {
                if (!equals(fa.value, fb.value)) return false;
            }
            return true;
        },
        .newtype => {
            const nv = a.newtype;
            const bnv = b.newtype;
            return std.mem.eql(u8, nv.type_name, bnv.type_name) and equals(nv.inner, bnv.inner);
        },
        .error_val => {
            const e = a.error_val;
            const be = b.error_val;
            return std.mem.eql(u8, e.type_name, be.type_name) and std.mem.eql(u8, e.message, be.message);
        },
        // 其余（闭包/原语/迭代器/并发原语等）引用相等。
        else => switch (a) {
            .vm_closure => a.vm_closure == b.vm_closure,
            .partial => a.partial == b.partial,
            .builtin => a.builtin == b.builtin,
            .throw_val => a.throw_val == b.throw_val,
            .array_iterator => a.array_iterator == b.array_iterator,
            .string_iterator => a.string_iterator == b.string_iterator,
            .range_iterator => a.range_iterator == b.range_iterator,
            .atomic_val => a.atomic_val == b.atomic_val,
            .spawn_val => a.spawn_val == b.spawn_val,
            .channel_val => a.channel_val == b.channel_val,
            .sender_val => a.sender_val == b.sender_val,
            .receiver_val => a.receiver_val == b.receiver_val,
            .trait_value => a.trait_value == b.trait_value,
            .lazy_val => a.lazy_val == b.lazy_val,
            .cell => a.cell == b.cell,
            else => unreachable,
        },
    };
}

/// 编译期整数类型推断（纯 u128/i128 算术，不触发运行时 codegen bug）
/// 正数按 i8/u8/i16/.../u128 升序选最小容纳类型；负数按 i8/i16/i32/i64/i128
pub fn inferIntType(val: u128) IntType {
    const signed_val: i128 = @bitCast(val);
    if (signed_val >= 0) {
        if (val <= std.math.maxInt(i8)) return .i8;
        if (val <= std.math.maxInt(u8)) return .u8;
        if (val <= std.math.maxInt(i16)) return .i16;
        if (val <= std.math.maxInt(u16)) return .u16;
        if (val <= std.math.maxInt(i32)) return .i32;
        if (val <= std.math.maxInt(u32)) return .u32;
        if (val <= std.math.maxInt(i64)) return .i64;
        if (val <= std.math.maxInt(u64)) return .u64;
        if (val <= @as(u128, @bitCast(@as(i128, std.math.maxInt(i128))))) return .i128;
        return .u128;
    } else {
        if (signed_val >= std.math.minInt(i8)) return .i8;
        if (signed_val >= std.math.minInt(i16)) return .i16;
        if (signed_val >= std.math.minInt(i32)) return .i32;
        if (signed_val >= std.math.minInt(i64)) return .i64;
        return .i128;
    }
}

/// 整数类型提升（移植自旧 value.zig）
/// 同宽有符号→提升到下一档有符号；否则取更宽的
pub fn promoteIntTypes(left: IntType, right: IntType) IntType {
    const left_bits = left.bitWidth();
    const right_bits = right.bitWidth();
    if (left_bits > right_bits) return left;
    if (right_bits > left_bits) return right;
    if (!left.isSigned() or !right.isSigned()) {
        return switch (left_bits) {
            8 => .i16,
            16 => .i32,
            32 => .i64,
            64 => .i128,
            128 => .i128,
            else => unreachable,
        };
    }
    return left;
}

test {
    // 引用所有子模块以确保它们的 test 被收集
    std.testing.refAllDecls(byte_array);
    std.testing.refAllDecls(int);
    std.testing.refAllDecls(float);
    std.testing.refAllDecls(char_mod);
    std.testing.refAllDecls(str_mod);
}
