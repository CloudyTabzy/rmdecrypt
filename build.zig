const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- CLI executable ---
    const exe = b.addExecutable(.{
        .name = "rmdecrypt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    // --- GUI executable (SDL2 backend) ---
    const dvui_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .sdl2,
    });

    const gui = b.addExecutable(.{
        .name = "rmdecrypt-gui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gui.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "dvui", .module = dvui_dep.module("dvui_sdl2") },
                .{ .name = "sdl2-backend", .module = dvui_dep.module("sdl2") },
                .{ .name = "win32_folder_dialog", .module = b.createModule(.{
                    .root_source_file = b.path("src/win32_folder_dialog.zig"),
                    .target = target,
                    .optimize = optimize,
                }) },
            },
        }),
    });
    if (target.result.os.tag == .windows) gui.root_module.linkSystemLibrary("ole32", .{});
    b.installArtifact(gui);

    const gui_run_step = b.step("gui", "Run the GUI");
    const gui_run_cmd = b.addRunArtifact(gui);
    gui_run_step.dependOn(&gui_run_cmd.step);
    gui_run_cmd.step.dependOn(b.getInstallStep());

    // --- Tests ---
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
