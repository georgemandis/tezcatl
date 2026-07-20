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

    // Cross-compilation SDK paths (e.g. -Dtarget=x86_64-macos on aarch64 host)
    const is_native = target.query.isNativeOs() and target.query.isNativeCpu();
    if (!is_native and target_os == .macos) {
        const macos_sdk = b.option([]const u8, "macos-sdk", "Path to macOS SDK for cross-compilation");
        if (macos_sdk) |sdk| {
            webview_mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk}) });
            webview_mod.addFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}) });
        }
    }

    if (target_os == .macos) {
        webview_mod.linkSystemLibrary("objc", .{});
        webview_mod.linkFramework("Foundation", .{});
        webview_mod.linkFramework("WebKit", .{});
        webview_mod.linkFramework("AppKit", .{});
        webview_mod.linkFramework("CoreGraphics", .{});
    } else if (target_os == .linux) {
        // WebKitGTK 6.0 (GTK4). Resolved via pkg-config; requires the -dev
        // packages: libwebkitgtk-6.0-dev (pulls in gtk4, glib, jsc).
        // Experimental backend — see src/platform/linux.zig.
        webview_mod.link_libc = true;
        webview_mod.linkSystemLibrary("webkitgtk-6.0", .{});
        webview_mod.linkSystemLibrary("gtk4", .{});
        webview_mod.linkSystemLibrary("glib-2.0", .{});
        webview_mod.linkSystemLibrary("gobject-2.0", .{});
        webview_mod.linkSystemLibrary("javascriptcoregtk-6.0", .{});
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

    // Test step
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "webview", .module = webview_mod },
            },
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
