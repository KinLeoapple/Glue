//! 模块结构检查模块。
//!
//! 提供模块成员方法签名（MethodSig）的抽象，以及模块是否结构化满足某 trait
//! 所需方法集合的判定（ModuleChecker）。这在以模块作为 trait 实参时用于校验
//! 模块是否提供了 trait 要求的全部方法及其参数个数。

const std = @import("std");
const ast = @import("ast");

/// 模块成员方法的签名摘要：方法名与参数个数。
pub const MethodSig = struct {
    name: []const u8,
    arity: usize,
};

/// 模块结构化匹配 trait 的结果。
pub const MatchResult = struct {
    ok: bool,
    missing_method: ?[]const u8 = null,
    arity_expected: usize = 0,
    arity_got: usize = 0,
    reason: Reason = .ok,

    pub const Reason = enum { ok, missing, arity_mismatch };
};

/// 模块检查器：判断一组提供的方法签名是否结构化满足一组必需的方法签名。
pub const ModuleChecker = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ModuleChecker {
        return ModuleChecker{ .allocator = allocator };
    }

    pub fn deinit(self: *ModuleChecker) void {
        _ = self;
    }

    /// 逐个校验 `required` 中的方法是否在 `provided` 中存在且参数个数一致。
    /// 任一方法缺失或参数个数不符即返回带原因的失败结果。
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

    /// 从 trait 方法声明中收集无方法体（即需要被实现）的方法签名。
    pub fn requiredMethods(
        self: *ModuleChecker,
        trait_methods: []const ast.MethodDecl,
    ) ![]MethodSig {
        var list = std.ArrayList(MethodSig).empty;
        for (trait_methods) |m| {
            if (m.body != null) continue;
            try list.append(self.allocator, .{ .name = m.name, .arity = m.params.len });
        }
        return list.toOwnedSlice(self.allocator);
    }
};
