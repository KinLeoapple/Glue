//! 模块类型匹配 —— 结构化匹配规则（文档 §2.7.5 / §2.12.2 / §4.6.2）
//!
//! 名义化匹配（`impl`）由 trait_resolve 处理；本模块负责**结构化匹配**：
//! 文件模块作为一等 Trait 值时，按结构（方法集合）自动满足 Trait。
//!
//! 文档 §2.12.2：方法更多的模块是方法更少的 Trait 的子类型。
//!     { get, put, delete, list }  <:  { get, put }
//! 即「模块提供的方法集合 ⊇ Trait 要求的方法集合，且对应签名兼容」。

const std = @import("std");
const ast = @import("ast");

/// 一个方法的结构化摘要：名字 + 参数个数（arity）。
/// 结构化匹配只比较名字与 arity——签名的精确类型留给 HM 在调用点处理。
pub const MethodSig = struct {
    name: []const u8,
    arity: usize,
};

/// 结构化匹配的诊断结果。
pub const MatchResult = struct {
    ok: bool,
    /// 不满足时：缺失或不兼容的方法名（指向 required 中的切片，调用方负责生命周期）。
    missing_method: ?[]const u8 = null,
    /// 不兼容原因：arity 不一致时记录 (expected, got)。
    arity_expected: usize = 0,
    arity_got: usize = 0,
    /// 失败种类
    reason: Reason = .ok,

    pub const Reason = enum { ok, missing, arity_mismatch };
};

pub const ModuleChecker = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ModuleChecker {
        return ModuleChecker{ .allocator = allocator };
    }

    pub fn deinit(self: *ModuleChecker) void {
        _ = self;
    }

    /// 结构化匹配核心：`provided` 是否结构化满足 `required`（文档 §2.12.2）。
    /// 规则：required 中的每个方法都能在 provided 中找到同名方法，且 arity 一致。
    /// provided 可以有更多方法（子类型方向：方法多 <: 方法少）。
    pub fn structurallySatisfies(
        self: *ModuleChecker,
        provided: []const MethodSig,
        required: []const MethodSig,
    ) MatchResult {
        _ = self;
        for (required) |req| {
            var found: ?MethodSig = null;
            for (provided) |prov| {
                if (std.mem.eql(u8, prov.name, req.name)) {
                    found = prov;
                    break;
                }
            }
            if (found) |prov| {
                if (prov.arity != req.arity) {
                    return .{
                        .ok = false,
                        .missing_method = req.name,
                        .arity_expected = req.arity,
                        .arity_got = prov.arity,
                        .reason = .arity_mismatch,
                    };
                }
            } else {
                return .{
                    .ok = false,
                    .missing_method = req.name,
                    .reason = .missing,
                };
            }
        }
        return .{ .ok = true };
    }

    /// 从 trait 声明提取要求的方法签名集合（仅含**抽象**方法，即无默认实现的；
    /// 有默认实现的方法模块可以不提供——文档 §2.7 默认方法）。
    /// 结果切片由调用方 allocator 持有。
    pub fn requiredMethods(
        self: *ModuleChecker,
        trait_methods: []const ast.MethodDecl,
    ) ![]MethodSig {
        var list = std.ArrayList(MethodSig).empty;
        for (trait_methods) |m| {
            // 有默认实现（body != null）的方法不强制要求模块提供
            if (m.body != null) continue;
            try list.append(self.allocator, .{ .name = m.name, .arity = m.params.len });
        }
        return list.toOwnedSlice(self.allocator);
    }
};
