const std = @import("std");
const vm = @import("src/vm/vm.zig");
const chunk = @import("src/vm/chunk.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var prog = chunk.Program.init(allocator);
    defer prog.deinit();

    try prog.addImplMethod("Cat", "hello", "Greet", 0);
    
    std.debug.print("Added method. Checking impl_methods:\n", .{});
    for (prog.impl_methods.items) |m| {
        std.debug.print("  type='{s}', method='{s}', trait='{s}', func={}\n", .{m.type_name, m.method_name, m.trait_name, m.func_idx});
    }
}
