//! Value 值类型模块
//!
//! 定义 Glue 语言的核心值类型 Value 联合体，涵盖标量值（null、unit、
//! 布尔、字符、整数、浮点数）和堆分配值（字符串、数组、记录、ADT、
//! 闭包等）。提供值的构造、访问、引用计数管理、深拷贝、格式化和
//! 相等性比较等核心操作。

const std = @import("std");
pub const int = @import("int.zig");
pub const IntType = int.Type;
pub const Int = int.Int;
pub const float = @import("float.zig");
pub const FloatType = float.Type;
pub const Float = float.Float;
pub const wide = @import("wide.zig");
const U128 = wide.U128;
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
pub const VmClosure = callable.VmClosure;
pub const TraitValue = callable.TraitValue;
pub const LazyValue = callable.LazyValue;
const BuiltinFn = callable.BuiltinFn;
const Builtin = callable.Builtin;
const PartialApplication = callable.PartialApplication;
pub const control = @import("control.zig");
pub const ErrorValue = control.ErrorValue;
pub const ThrowValue = control.ThrowValue;
pub const iterator = @import("iterator.zig");
const ArrayIterator = iterator.ArrayIterator;
const StringIterator = iterator.StringIterator;
const RangeIterator = iterator.RangeIterator;
pub const concurrent = @import("concurrent.zig");
pub const AtomicValue = concurrent.AtomicValue;
pub const SpawnHandle = concurrent.SpawnHandle;
pub const ChannelValue = concurrent.ChannelValue;
pub const SenderValue = concurrent.SenderValue;
pub const ReceiverValue = concurrent.ReceiverValue;
/// Glue 语言的核心值类型联合体
///
/// 标量变体（null_val、unit、boolean、char、int、float）为内联值，
/// 其余变体为堆分配的引用计数对象指针。
pub const Value = union(enum) {
null_val,
unit,
boolean: bool,
char: Char,
int: Int,
float: Float,
string: *Str,
array: *ArrayValue,
record: *RecordValue,
adt: *AdtValue,
newtype: *NewtypeValue,
cell: *Cell,
range: *Range,
vm_closure: *VmClosure,
partial: *PartialApplication,
builtin: *Builtin,
error_val: *ErrorValue,
throw_val: *ThrowValue,
array_iterator: *ArrayIterator,
string_iterator: *StringIterator,
range_iterator: *RangeIterator,
atomic_val: *AtomicValue,
spawn_val: *SpawnHandle,
channel_val: *ChannelValue,
sender_val: *SenderValue,
receiver_val: *ReceiverValue,
trait_value: *TraitValue,
lazy_val: *LazyValue,

// ── 标量值构造 ──

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
return .{ .boolean = b };
}

/// 构造字符值
pub inline fn fromChar(c: Char) Value {
return .{ .char = c };
}

/// 构造整数值
pub inline fn fromInt(i: Int) Value {
return .{ .int = i };
}

/// 构造浮点数值
pub inline fn fromFloat(f: Float) Value {
return .{ .float = f };
}
// ── 堆分配值构造 ──

/// 从字节切片构造字符串值，在堆上分配 Str
pub fn fromStringBytes(allocator: std.mem.Allocator, bytes: []const u8) !Value {
const s = try allocator.create(Str);
s.* = try Str.fromLiteral(allocator, bytes);
return .{ .string = s };
}

/// 构造数组值，可选固定大小
pub fn makeArray(allocator: std.mem.Allocator, elements: []Value, fixed_size: ?u64) !Value {
const arr = try allocator.create(ArrayValue);
arr.* = .{ .elements = elements, .capacity = elements.len, .fixed_size = fixed_size };
return .{ .array = arr };
}

/// 构造记录值，携带类型名和字段映射
pub fn makeRecord(allocator: std.mem.Allocator, type_name: []const u8, fields: std.StringHashMap(Value)) !Value {
const rec = try allocator.create(RecordValue);
rec.* = .{ .type_name = type_name, .fields = fields };
return .{ .record = rec };
}

/// 构造代数数据类型（ADT）值，携带类型名、构造子和字段
pub fn makeAdt(allocator: std.mem.Allocator, type_name: []const u8, constructor: []const u8, fields: []AdtField) !Value {
const adt = try allocator.create(AdtValue);
adt.* = .{ .type_name = type_name, .constructor = constructor, .fields = fields };
return .{ .adt = adt };
}

/// 构造新类型值，包裹一个内部值
pub fn makeNewtype(allocator: std.mem.Allocator, type_name: []const u8, inner: Value) !Value {
const nt = try allocator.create(NewtypeValue);
nt.* = .{ .type_name = type_name, .inner = inner };
return .{ .newtype = nt };
}

/// 构造可变单元，持有对内部值的可变引用
pub fn makeCell(allocator: std.mem.Allocator, inner: Value) !Value {
const cell = try allocator.create(Cell);
cell.* = .{ .inner = inner };
return .{ .cell = cell };
}

/// 构造区间值，预计算 i64 表示以加速循环
pub fn makeRange(allocator: std.mem.Allocator, start: Int, end: Int, inclusive: bool) !Value {
const r = try allocator.create(Range);
const start_i64 = if (start.coerceTo(.i64)) |s| s.toNative(i64) else null;
const end_i64 = if (end.coerceTo(.i64)) |e| e.toNative(i64) else null;
r.* = .{ .start = start, .end = end, .inclusive = inclusive, .start_i64 = start_i64, .end_i64 = end_i64 };
return .{ .range = r };
}

/// 构造虚拟机闭包值
pub fn makeVmClosure(allocator: std.mem.Allocator, closure: VmClosure) !Value {
const c = try allocator.create(VmClosure);
c.* = closure;
return .{ .vm_closure = c };
}

/// 构造部分应用值，绑定部分参数
pub fn makePartial(allocator: std.mem.Allocator, func: Value, bound_args: []Value, remaining_arity: u8) !Value {
const p = try allocator.create(PartialApplication);
p.* = .{ .func = func, .bound_args = bound_args, .remaining_arity = remaining_arity };
return .{ .partial = p };
}

/// 构造内置函数值
pub fn makeBuiltin(allocator: std.mem.Allocator, fn_ptr: BuiltinFn, user_ctx: ?*anyopaque) !Value {
const b = try allocator.create(Builtin);
b.* = .{ .fn_ptr = fn_ptr, .user_ctx = user_ctx };
return .{ .builtin = b };
}

/// 构造错误值，携带类型名和消息
pub fn makeError(allocator: std.mem.Allocator, type_name: []const u8, message: []const u8, is_error_subtype: bool) !Value {
const e = try allocator.create(ErrorValue);
e.* = .{ .type_name = type_name, .message = message, .is_error_subtype = is_error_subtype };
return .{ .error_val = e };
}

/// 构造抛出值，封装成功值或错误载荷
pub fn makeThrow(allocator: std.mem.Allocator, payload: ThrowValue.Payload) !Value {
const t = try allocator.create(ThrowValue);
t.* = .{ .payload = payload };
return .{ .throw_val = t };
}

/// 包装通道发送端为值（发送端由外部管理，无需分配）
pub fn fromSender(allocator: std.mem.Allocator, sv: *SenderValue) !Value {
_ = allocator;
return .{ .sender_val = sv };
}

/// 包装通道接收端为值（接收端由外部管理，无需分配）
pub fn fromReceiver(allocator: std.mem.Allocator, rv: *ReceiverValue) !Value {
_ = allocator;
return .{ .receiver_val = rv };
}
// ── 值访问器 ──

/// 取布尔值
pub inline fn asBool(self: Value) bool {
return self.boolean;
}

/// 取字符值
pub inline fn asChar(self: Value) Char {
return self.char;
}

/// 取整数值
pub inline fn asInt(self: Value) Int {
return self.int;
}

/// 取浮点数值
pub inline fn asFloat(self: Value) Float {
return self.float;
}

// ── 类型判断 ──

/// 判断是否为堆分配（装箱）值
pub fn isBoxed(self: Value) bool {
return switch (self) {
.null_val, .unit, .boolean, .char, .int, .float => false,
else => true,
};
}

/// 判断是否可作为 memo 表的键（不可变且可序列化）
pub inline fn isMemoizableValue(self: Value) bool {
return switch (self) {
.null_val, .unit, .boolean, .char, .int, .float,
.string, .array, .record, .adt, .newtype,
.range, .error_val, .throw_val => true,
else => false,
};
}

/// 判断是否为整数
pub inline fn isInteger(self: Value) bool {
return self == .int;
}

/// 判断是否为浮点数
pub inline fn isFloat(self: Value) bool {
return self == .float;
}

/// 判断是否为数值（整数或浮点数）
pub inline fn isNumeric(self: Value) bool {
return self == .int or self == .float;
}

/// 判断是否为字符串
pub inline fn isString(self: Value) bool {
return self == .string;
}

// ── 引用计数与生命周期 ──

/// 增加引用计数，返回自身以便链式调用
pub inline fn retain(self: Value) Value {
switch (self) {
// 标量值和 spawn 句柄无需引用计数
.null_val, .unit, .boolean, .char, .int, .float, .spawn_val => {},
// 字符串区分 SSO 和堆分配两种引用计数路径
.string => |p| {
if (p.isSso()) {
p.ssoRetain();
} else {
p.rc += 1;
}
},
inline .array, .record, .adt, .newtype, .cell, .range,
.vm_closure, .partial, .builtin, .error_val, .throw_val,
.array_iterator, .string_iterator, .range_iterator,
.trait_value, .lazy_val => |p| {
p.rc += 1;
},
// 运行时对象使用自身的引用计数机制
inline .atomic_val, .channel_val, .sender_val, .receiver_val => |p| {
p.ref();
},
}
return self;
}

/// 深拷贝值：标量值原样返回，堆分配值递归复制其内容
pub fn deepCopy(self: Value, allocator: std.mem.Allocator) !Value {
switch (self) {
.null_val, .unit, .boolean, .char, .int, .float => return self,
.spawn_val, .atomic_val, .channel_val, .sender_val, .receiver_val => {
return self.retain();
},
.string => |p| {
return try Value.fromStringBytes(allocator, p.bytes());
},
.array => |p| {
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
return .{ .array = arr };
},
.record => |p| {
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
return .{ .record = rec };
},
.adt => |p| {
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
return .{ .adt = adt };
},
.newtype => |p| {
const nt = try allocator.create(NewtypeValue);
nt.* = .{
.type_name = p.type_name,
.inner = try p.inner.deepCopy(allocator),
};
return .{ .newtype = nt };
},
.cell => |p| {
const cell = try allocator.create(Cell);
cell.* = .{ .inner = try p.inner.deepCopy(allocator) };
return .{ .cell = cell };
},
.range => |p| {
const r = try allocator.create(Range);
r.* = .{
.start = p.start,
.end = p.end,
.inclusive = p.inclusive,
.start_i64 = p.start_i64,
.end_i64 = p.end_i64,
};
return .{ .range = r };
},
.vm_closure => |p| {
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
return .{ .vm_closure = c };
},
.partial => |p| {
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
return .{ .partial = pa };
},
.builtin => |p| {
const b = try allocator.create(Builtin);
b.* = .{ .fn_ptr = p.fn_ptr, .user_ctx = p.user_ctx };
return .{ .builtin = b };
},
.error_val => |p| {
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
return .{ .error_val = e };
},
.throw_val => |p| {
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
return .{ .throw_val = t };
},
.array_iterator, .string_iterator, .range_iterator => {
return self.retain();
},
.trait_value => |p| {
if (!p.vm_owned) return self.retain();
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
return .{ .trait_value = tv };
},
.lazy_val => {
return self.retain();
},
}
}

/// 递减引用计数，归零时释放堆内存；ADT 链采用迭代释放以避免递归栈溢出
pub fn release(self: Value, allocator: std.mem.Allocator) void {
var current = self;
while (true) {
switch (current) {
// 标量值和 spawn 句柄无需释放
.null_val, .unit, .boolean, .char, .int, .float, .spawn_val => return,
// 字符串区分 SSO 和堆分配两种释放路径
.string => |p| {
if (p.isSso()) {
if (p.ssoRelease()) allocator.destroy(p);
return;
}
if (p.rc > 1) {
p.rc -= 1;
} else {
p.deinit(allocator);
allocator.destroy(p);
}
return;
},
// ADT 采用迭代释放：将最后一个 rc==1 的子 ADT 延后处理以避免深递归
.adt => |p| {
if (p.rc > 1) {
p.rc -= 1;
return;
}
var next_adt: ?Value = null;
for (p.fields) |*f| {
if (f.value == .adt and f.value.adt.rc == 1) {
if (next_adt) |n| n.release(allocator);
next_adt = f.value;
} else {
f.value.release(allocator);
}
}
if (p.fields.len > 0) allocator.free(p.fields);
allocator.destroy(p);
if (next_adt) |n| {
current = n;
continue;
}
return;
},
inline .array, .record, .newtype, .cell, .range,
.vm_closure, .partial, .builtin, .error_val, .throw_val,
.array_iterator, .string_iterator, .range_iterator,
.trait_value, .lazy_val => |p| {
if (p.rc > 1) {
p.rc -= 1;
} else {
p.deinit(allocator);
allocator.destroy(p);
}
return;
},
inline .atomic_val, .channel_val, .sender_val, .receiver_val => |p| {
if (p.unref()) allocator.destroy(p);
return;
},
}
}
}

// ── 格式化 ──

/// 将值格式化为可读字符串，追加到 buf
pub fn format(self: Value, allocator: std.mem.Allocator, buf: *std.ArrayList(u8)) !void {
switch (self) {
.null_val => try buf.appendSlice(allocator, "null"),
.unit => try buf.appendSlice(allocator, "()"),
.boolean => try buf.appendSlice(allocator, if (self.boolean) "true" else "false"),
.char => {
var temp: [16]u8 = undefined;
const s = std.fmt.bufPrint(&temp, "'{u}'", .{self.char.toNative()}) catch unreachable;
try buf.appendSlice(allocator, s);
},
.int => {
var temp: [64]u8 = undefined;
const s = self.int.formatDecimal(&temp);
try buf.appendSlice(allocator, s);
},
.float => {
var temp: [80]u8 = undefined;
const s = self.float.formatDecimal(&temp);
try buf.appendSlice(allocator, s);
},
.string => {
try buf.append(allocator, '"');
try buf.appendSlice(allocator, self.string.bytes());
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
var start_buf: [41]u8 = undefined;
var end_buf: [41]u8 = undefined;
const start_str = r.start.formatDecimal(&start_buf);
const end_str = r.end.formatDecimal(&end_buf);
var temp: [128]u8 = undefined;
const s = std.fmt.bufPrint(&temp, "{s}..{s}{s}", .{ start_str, if (r.inclusive) "=" else "", end_str }) catch unreachable;
try buf.appendSlice(allocator, s);
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

/// 格式化值并返回新分配的字符串切片
pub fn formatAlloc(self: Value, allocator: std.mem.Allocator) ![]const u8 {
var buf = std.ArrayList(u8).empty;
errdefer buf.deinit(allocator);
try self.format(allocator, &buf);
return buf.toOwnedSlice(allocator);
}
};

// ── 模块级工具函数 ──

/// 值的相等性比较：标量按值比较，容器递归比较，其余按引用相等
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
.string => std.mem.eql(u8, a.string.bytes(), b.string.bytes()),
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

/// 根据无符号 128 位数值和符号推断最小可容纳的整数类型
pub fn inferIntTypeBytes(buf: *const [16]u8, negative: bool) IntType {
const val = U128.load(buf);
if (negative) {
// 负数：绝对值不超过各符号类型范围
if (val.compare(U128.fromU64(1 << 7)) != .gt) return .i8;
if (val.compare(U128.fromU64(1 << 15)) != .gt) return .i16;
if (val.compare(U128.fromU64(1 << 31)) != .gt) return .i32;
if (val.compare(U128.fromU64(1 << 63)) != .gt) return .i64;
return .i128;
} else {
// 非负数：交替尝试有符号和无符号类型
if (val.compare(U128.fromU64(std.math.maxInt(i8))) != .gt) return .i8;
if (val.compare(U128.fromU64(std.math.maxInt(u8))) != .gt) return .u8;
if (val.compare(U128.fromU64(std.math.maxInt(i16))) != .gt) return .i16;
if (val.compare(U128.fromU64(std.math.maxInt(u16))) != .gt) return .u16;
if (val.compare(U128.fromU64(std.math.maxInt(i32))) != .gt) return .i32;
if (val.compare(U128.fromU64(std.math.maxInt(u32))) != .gt) return .u32;
if (val.compare(U128.fromU64(std.math.maxInt(i64))) != .gt) return .i64;
if (val.compare(U128.fromU64(std.math.maxInt(u64))) != .gt) return .u64;
const i128_max = U128.fromU64Pair(0x7FFFFFFFFFFFFFFF, ~@as(u64, 0));
if (val.compare(i128_max) != .gt) return .i128;
return .u128;
}
}

/// 整数类型提升：按位宽选择更宽的类型，符号不一致时升级到下一档有符号类型
pub fn promoteIntTypes(left: IntType, right: IntType) IntType {
const left_bits = left.bitWidth();
const right_bits = right.bitWidth();
if (left_bits > right_bits) return left;
if (right_bits > left_bits) return right;
// 位宽相同但符号不同时，升级到更宽的有符号类型
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
std.testing.refAllDecls(int);
std.testing.refAllDecls(float);
std.testing.refAllDecls(char_mod);
std.testing.refAllDecls(str_mod);
}
