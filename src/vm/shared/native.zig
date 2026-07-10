//! VM 共享：原生内建函数枚举（println/print/channel 等）。
//! 栈式与寄存器式 VM 共用。

const std = @import("std");
const ast = @import("ast");

/// 原生内建函数 id（OP_CALL_NATIVE / call_native 的立即数）。编译器按裸名映射，VM 按 id 分派。
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
