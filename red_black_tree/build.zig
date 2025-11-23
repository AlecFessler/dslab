const std = @import("std");

pub fn build(b: *std.Build) void {
    const fuzz = b.option(bool, "fuzz", "Build fuzzing harness") orelse false;
    const prof = b.option(bool, "prof", "Build profiling harness") orelse false;
    if (!(fuzz or prof)) @panic("Build with either a fuzzing or profiling harness is required");

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const makeOp_mod = b.createModule(.{
        .root_source_file = b.path("../shared/makeOp.zig"),
        .target = target,
        .optimize = optimize,
    });

    if (fuzz) {
        const fuzz_mod = b.createModule(.{
            .root_source_file = b.path("../fuzz/fuzz.zig"),
            .target = target,
            .optimize = optimize,
        });
        fuzz_mod.addImport("makeOp", makeOp_mod);

        const exe = b.addExecutable(.{
            .name = "fuzz_rbt.exe",
            .root_module = b.createModule(.{
                .root_source_file = b.path("fuzz.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addImport("fuzz", fuzz_mod);
        b.installArtifact(exe);
    }

    if (prof) {
        const prof_mod = b.createModule(.{
            .root_source_file = b.path("../prof/prof.zig"),
            .target = target,
            .optimize = optimize,
        });
        prof_mod.addImport("makeOp", makeOp_mod);

        const exe = b.addExecutable(.{
            .name = "prof_rbt.exe",
            .root_module = b.createModule(.{
                .root_source_file = b.path("prof.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addImport("prof", prof_mod);
        b.installArtifact(exe);
    }
}
