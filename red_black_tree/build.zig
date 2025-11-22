const std = @import("std");

pub fn build(b: *std.Build) void {
    const fuzz = b.option(bool, "fuzz", "Build fuzzing harness") orelse false;
    const prof = b.option(bool, "prof", "Build profiling harness") orelse false;
    if (!(fuzz or prof)) @panic("Build with either a fuzzing or profiling harness is required");

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    if (fuzz) {
        const fuzzlib_mod = b.createModule(.{
            .root_source_file = b.path("../fuzzlib/fuzz.zig"),
            .target = target,
            .optimize = optimize,
        });

        const exe = b.addExecutable(.{
            .name = "fuzz_rbt.exe",
            .root_module = b.createModule(.{
                .root_source_file = b.path("fuzz.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });

        exe.root_module.addImport("fuzzlib", fuzzlib_mod);

        b.installArtifact(exe);
    }

    if (prof) {
        const exe = b.addExecutable(.{
            .name = "prof_rbt.exe",
            .root_module = b.createModule(.{
                .root_source_file = b.path("prof.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        b.installArtifact(exe);
    }
}
