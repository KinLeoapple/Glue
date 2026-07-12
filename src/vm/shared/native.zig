//! 原生函数枚举与名称映射。
//!
//! 定义 VM 内建原生函数的枚举及其名称查找逻辑，
//! 供 call_native 指令快速分派到对应实现。

const std = @import("std");
const ast = @import("ast");

/// 内建原生函数标识，编码在 call_native 指令的操作数 B 中。
pub const Native = enum(u8) {
    println,
    print,
    ok,
    err,
    channel,
    type,
    eq,
    panic,
    eprintln,
    eprint,
    scan,
    scanln,

    /// 根据源码名称查找对应的原生函数，找不到返回 null。
    pub fn fromName(s: []const u8) ?Native {
        if (std.mem.eql(u8, s, "println")) return .println;
        if (std.mem.eql(u8, s, "print")) return .print;
        if (std.mem.eql(u8, s, "Ok")) return .ok;
        if (std.mem.eql(u8, s, ast.type_names.error_type)) return .err;
        if (std.mem.eql(u8, s, "channel")) return .channel;
        if (std.mem.eql(u8, s, "type")) return .type;
        if (std.mem.eql(u8, s, "eq")) return .eq;
        if (std.mem.eql(u8, s, "Panic")) return .panic;
        if (std.mem.eql(u8, s, "eprintln")) return .eprintln;
        if (std.mem.eql(u8, s, "eprint")) return .eprint;
        if (std.mem.eql(u8, s, "scan")) return .scan;
        if (std.mem.eql(u8, s, "scanln")) return .scanln;
        return null;
    }
};
