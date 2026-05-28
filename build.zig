const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const target_os = target.result.os.tag;

    // Shared module for WebKit rendering logic
    const webview_mod = b.createModule(.{
        .root_source_file = b.path("src/webview.zig"),
        .target = target,
        .optimize = optimize,
    });

    if (target_os == .macos) {
        webview_mod.linkSystemLibrary("objc", .{});
        webview_mod.linkFramework("Foundation", .{});
        webview_mod.linkFramework("WebKit", .{});
        webview_mod.linkFramework("AppKit", .{});
        webview_mod.linkFramework("CoreGraphics", .{});
    }

    // CLI executable
    const exe = b.addExecutable(.{
        .name = "tezcatl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "webview", .module = webview_mod },
            },
        }),
    });
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the tezcatl CLI");
    run_step.dependOn(&run_cmd.step);
}
