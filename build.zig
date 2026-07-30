const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const keepSymbols = b.option(bool, "keep-symbols", "Keep symbols");

    const module = b.addModule("sett", .{
        .root_source_file = b.path("sett.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = optimize == .ReleaseFast and !(keepSymbols orelse false),
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

    const test_filters = b.option([]const []const u8, "test-filter", "Filter tests by string match") orelse &.{};
    const unit_tests = b.addTest(.{
        .root_module = module,
        .use_llvm = true,
        .filters = test_filters,
    });
    b.installArtifact(unit_tests);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    b.getInstallStep().dependOn(&run_unit_tests.step);

    const exe = b.addExecutable(.{
        .name = "sett",
        .root_module = module,
        .use_llvm = true,
    });
    b.installArtifact(exe);
}
