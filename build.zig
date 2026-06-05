const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 共享模块
    const ast_module = b.createModule(.{
        .root_source_file = b.path("src/ast.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lexer_module = b.createModule(.{
        .root_source_file = b.path("src/lexer.zig"),
        .target = target,
        .optimize = optimize,
    });

    const parser_module = b.createModule(.{
        .root_source_file = b.path("src/parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    parser_module.addImport("ast", ast_module);
    parser_module.addImport("lexer", lexer_module);

    // eval 子模块
    const value_module = b.createModule(.{
        .root_source_file = b.path("src/eval/value.zig"),
        .target = target,
        .optimize = optimize,
    });
    value_module.addImport("ast", ast_module);

    const env_module = b.createModule(.{
        .root_source_file = b.path("src/eval/env.zig"),
        .target = target,
        .optimize = optimize,
    });
    env_module.addImport("value", value_module);

    const pattern_module = b.createModule(.{
        .root_source_file = b.path("src/eval/pattern.zig"),
        .target = target,
        .optimize = optimize,
    });
    pattern_module.addImport("ast", ast_module);
    pattern_module.addImport("value", value_module);
    pattern_module.addImport("env", env_module);

    const throw_module = b.createModule(.{
        .root_source_file = b.path("src/eval/throw.zig"),
        .target = target,
        .optimize = optimize,
    });
    throw_module.addImport("value", value_module);

    const module_eval_module = b.createModule(.{
        .root_source_file = b.path("src/eval/module_eval.zig"),
        .target = target,
        .optimize = optimize,
    });
    module_eval_module.addImport("ast", ast_module);
    module_eval_module.addImport("value", value_module);
    module_eval_module.addImport("env", env_module);

    const eval_module = b.createModule(.{
        .root_source_file = b.path("src/eval/eval.zig"),
        .target = target,
        .optimize = optimize,
    });
    eval_module.addImport("ast", ast_module);
    eval_module.addImport("value", value_module);
    eval_module.addImport("env", env_module);
    eval_module.addImport("pattern", pattern_module);
    eval_module.addImport("throw_mod", throw_module);
    eval_module.addImport("module_eval", module_eval_module);
    eval_module.addImport("lexer", lexer_module);
    eval_module.addImport("parser", parser_module);

    // 创建根模块
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("ast", ast_module);
    root_module.addImport("lexer", lexer_module);
    root_module.addImport("parser", parser_module);
    root_module.addImport("eval", eval_module);

    // 创建 glue 可执行文件
    const exe = b.addExecutable(.{
        .name = "glue",
        .root_module = root_module,
    });

    // 安装可执行文件到输出目录
    b.installArtifact(exe);

    // 创建 run 命令：zig build run
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    // 允许通过 -- 传递参数给程序
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "运行 Glue 解释器");
    run_step.dependOn(&run_cmd.step);

    // 测试 — eval 模块
    const eval_unit_tests = b.addTest(.{
        .root_module = eval_module,
    });
    const run_eval_unit_tests = b.addRunArtifact(eval_unit_tests);

    // 测试 — lexer
    const lexer_unit_tests = b.addTest(.{
        .root_module = lexer_module,
    });
    const run_lexer_unit_tests = b.addRunArtifact(lexer_unit_tests);

    // 测试 — parser
    const parser_unit_tests = b.addTest(.{
        .root_module = parser_module,
    });
    const run_parser_unit_tests = b.addRunArtifact(parser_unit_tests);

    const test_step = b.step("test", "运行测试");
    test_step.dependOn(&run_eval_unit_tests.step);
    test_step.dependOn(&run_lexer_unit_tests.step);
    test_step.dependOn(&run_parser_unit_tests.step);
}
