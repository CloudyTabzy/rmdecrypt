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

    // Single source of truth for the version string: the .version field of
    // build.zig.zon, read out of the manifest text at compile time. The CLI
    // gets it via the build_options module (also picked up by the test
    // step, which reuses exe.root_module); the GUI C code via -DRMD_VERSION.
    const version = blk: {
        const zon = @embedFile("build.zig.zon");
        const marker = ".version = \"";
        const at = std.mem.indexOf(u8, zon, marker) orelse break :blk "0.0.0-dev";
        const rest = zon[at + marker.len ..];
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse break :blk "0.0.0-dev";
        break :blk rest[0..end];
    };
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);
    exe.root_module.addOptions("build_options", build_options);

    const run_step = b.step("run", "Run CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    // --- GUI executable (Nuklear + D3D11, native Win32) ---
    const gui = b.addExecutable(.{
        .name = "rmdecrypt-gui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gui.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "win32_folder_dialog", .module = b.createModule(.{
                    .root_source_file = b.path("src/win32_folder_dialog.zig"),
                    .target = target,
                    .optimize = optimize,
                }) },
            },
        }),
    });
    gui.root_module.addIncludePath(b.path("vendor/nuklear"));
    gui.root_module.addCMacro("RMD_VERSION", b.fmt("\"{s}\"", .{version}));
    gui.root_module.addCSourceFile(.{ .file = b.path("src/nk_shim.c") });
    gui.root_module.addCSourceFile(.{ .file = b.path("src/gui_nk.c") });
    gui.root_module.addWin32ResourceFile(.{ .file = b.path("resources/app.rc") });
    gui.root_module.link_libc = true;
    if (target.result.os.tag == .windows) {
        gui.subsystem = .windows;
        gui.root_module.linkSystemLibrary("user32", .{});
        gui.root_module.linkSystemLibrary("gdi32", .{});
        gui.root_module.linkSystemLibrary("d3d11", .{});
        gui.root_module.linkSystemLibrary("dxguid", .{});
        gui.root_module.linkSystemLibrary("shell32", .{});
        gui.root_module.linkSystemLibrary("ole32", .{});
    }
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

    // --- Benchmarks (build with -Doptimize=ReleaseFast for real numbers) ---
    const core = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    addBench(b, core, target, optimize, "bench", "bench/micro.zig", "CPU microbenchmarks (optional arg: game dir)");
    addBench(b, core, target, optimize, "bench-io", "bench/io_strategies.zig", "File-system strategy bench (args: game dir, scratch dir, [reps])");
}

fn addBench(
    b: *std.Build,
    core: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    step_name: []const u8,
    source: []const u8,
    description: []const u8,
) void {
    const exe = b.addExecutable(.{
        .name = step_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "rmdecrypt", .module = core }},
        }),
    });
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step(step_name, description).dependOn(&run.step);
}
