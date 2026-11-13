//! zig build          release binary (ReleaseSmall) in zig-out/bin
//! zig build test     conformance fixtures, CLI scenarios and the repository linter
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // The release binary is built for size by default.
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default: ReleaseSmall)") orelse .ReleaseSmall;

    // Private values live in secrets/values.zig (ignored by git); without it
    // the empty committed skeleton is compiled, so nothing is replaced.
    const private = "secrets/values.zig";
    const has_private = if (b.build_root.handle.access(b.graph.io, private, .{})) true else |_| false;
    const values = b.createModule(.{ .root_source_file = b.path(if (has_private) private else "src/values.zig") });
    b.installArtifact(rufix(b, "rufix", target, optimize, values));

    // Tests never see private data: the CLI under test uses the skeleton.
    const skeleton = b.createModule(.{ .root_source_file = b.path("src/values.zig") });
    const cli = rufix(b, "rufix-under-test", target, .Debug, skeleton);
    const options = b.addOptions();
    options.addOptionPath("cli_exe", cli.getEmittedBin());

    const lib = b.createModule(.{
        .root_source_file = b.path("src/rufix.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    const tests_module = b.createModule(.{
        .root_source_file = b.path("tests/root.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    tests_module.addImport("rufix", lib);
    tests_module.addOptions("build_options", options);
    const tests = b.addTest(.{ .root_module = tests_module });
    const run = b.addRunArtifact(tests);
    run.setCwd(b.path("."));
    b.step("test", "Run the conformance fixtures, CLI scenarios and linter").dependOn(&run.step);
}

fn rufix(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    values: *std.Build.Module,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = optimize != .Debug,
    });
    module.addImport("values", values);
    if (target.result.os.tag == .windows) module.linkSystemLibrary("shell32", .{});
    return b.addExecutable(.{ .name = name, .root_module = module });
}
