//! 一等 Trait 值 vtable 支持
//!
//! 定义 Trait 分发的核心数据结构

const std = @import("std");
const value = @import("value");

const Closure = value.Closure;

/// 委托条目 — 将方法调用转发到父 Trait impl 的对应方法
pub const DelegateEntry = struct {
    target_trait: []const u8,
    target_method: []const u8,
};

/// Trait 声明信息
pub const TraitInfo = struct {
    name: []const u8,
    /// 方法名列表（\0 分隔的紧凑字符串）
    method_names: []const u8,
    /// 默认实现的方法（方法名 -> 闭包）
    default_methods: std.StringHashMap(*Closure),
    /// 父 Trait 名称列表
    parent_names: []const []const u8,
    /// 关联类型名称列表（\0 分隔的紧凑字符串）
    associated_type_names: []const u8,
    /// override 方法名集合（方法名 -> void），仅 override 的方法可覆盖父 Trait impl
    override_methods: std.StringHashMap(void),
    /// 委托方法名集合（方法名 -> void），委托方法也可覆盖父 Trait impl
    delegate_methods: std.StringHashMap(void),
    /// 委托信息（方法名 -> DelegateEntry），运行时动态查找父 Trait impl
    delegate_infos: std.StringHashMap(DelegateEntry),
};

/// Impl 方法注册项
pub const ImplMethodEntry = struct {
    trait_name: []const u8,
    /// impl 的目标类型名（如 impl Comparable<i32> 中的 "i32"）
    type_name: []const u8,
    method_name: []const u8,
    closure: *Closure,
};

/// Impl 注册信息（用于关联类型查找）
pub const ImplInfo = struct {
    trait_name: []const u8,
    type_name: []const u8,
    /// 关联类型定义（关联类型名 -> 实际类型名字符串）
    associated_types: std.StringHashMap([]const u8),
};
