const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("sett", .{
        .root_source_file = b.path("sett.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = optimize == .ReleaseFast,
        .omit_frame_pointer = optimize == .ReleaseFast,
    });
    const regent = b.dependency("regent", .{
        .target = target,
        .optimize = optimize,
    }).module("regent");
    const zcasp = b.dependency("zcasp", .{
        .target = target,
        .optimize = optimize,
    }).module("zcasp");

    module.addImport("regent", regent);
    module.addImport("zcasp", zcasp);
    zcasp.addImport("regent", regent);

    const unit_tests = b.addTest(.{
        .root_module = module,
        .use_llvm = true,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const exe = b.addExecutable(.{
        .name = "sett",
        .root_module = module,
        .use_llvm = true,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
