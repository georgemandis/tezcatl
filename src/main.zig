const std = @import("std");
const builtin = @import("builtin");
const webview = @import("webview");

const version = "0.3.0";

fn printUsage(writer: *std.Io.Writer) !void {
    try writer.print(
        \\Usage: tezcatl <url> [options]
        \\
        \\Headless web rendering CLI powered by native macOS WebKit.
        \\Loads a URL, waits for JavaScript to render, returns the DOM.
        \\Version {s} ({s})
        \\
        \\Commands:
        \\  tezcatl <url>              Render and output full DOM HTML
        \\  tezcatl <url> --eval=JS    Evaluate JS and output the result
        \\
        \\Options:
        \\  --eval=JS            Evaluate custom JavaScript instead of returning DOM
        \\  --eval-file=FILE     Evaluate JavaScript from a file
        \\  --screenshot[=FILE]  Take a PNG screenshot (default: stdout)
        \\  --archive[=FILE]     Save the page as a Safari .webarchive
        \\  --width=PX           Viewport width in pixels (default: 1280)
        \\  --height=PX          Viewport height in pixels (default: 720)
        \\  --wait=MS            Wait N ms after page load for JS to settle (default: 0)
        \\  --timeout=MS         Navigation timeout in ms (default: 30000)
        \\  --json               Wrap output in JSON
        \\  --help, -h           Show this help message
        \\  --version, -v        Show version
        \\
        \\Examples:
        \\  tezcatl https://example.com
        \\  tezcatl https://spa-site.com --wait=2000
        \\  tezcatl https://example.com --eval="document.title"
        \\  tezcatl https://example.com --eval="document.querySelectorAll('a').length"
        \\  tezcatl https://example.com --screenshot=page.png
        \\  tezcatl https://example.com --screenshot > page.png
        \\  tezcatl https://example.com --screenshot --width=1920 --height=1080
        \\  tezcatl https://example.com --eval-file=scrape.js
        \\  tezcatl https://example.com --archive
        \\  tezcatl https://example.com --archive=page.webarchive
        \\  tezcatl https://example.com | lingua detect
        \\
        \\Created by George Mandis <george@mand.is>
        \\
    , .{ version, @tagName(builtin.os.tag) });
}

fn writeJsonString(writer: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.print("\\\"", .{}),
            '\\' => try writer.print("\\\\", .{}),
            '\n' => try writer.print("\\n", .{}),
            '\r' => try writer.print("\\r", .{}),
            '\t' => try writer.print("\\t", .{}),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => try writer.print("\\u{X:0>4}", .{c}),
            else => try writer.print("{c}", .{c}),
        }
    }
}

fn defaultFilename(allocator: std.mem.Allocator, url: []const u8, ext: []const u8) ![]u8 {
    // Strip a leading scheme.
    var body = url;
    if (std.mem.startsWith(u8, body, "https://")) {
        body = body["https://".len..];
    } else if (std.mem.startsWith(u8, body, "http://")) {
        body = body["http://".len..];
    }

    // The slug is never longer than the input, so one allocation of body.len suffices.
    // Zig 0.16: std.ArrayList is unmanaged; we avoid it and write into a fixed buffer.
    const scratch = try allocator.alloc(u8, body.len);
    defer allocator.free(scratch);

    var len: usize = 0;
    var last_was_us = false;
    for (body) |c| {
        const safe = (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '.' or c == '-' or c == '_';
        if (safe) {
            scratch[len] = c;
            len += 1;
            last_was_us = false;
        } else if (!last_was_us) {
            scratch[len] = '_';
            len += 1;
            last_was_us = true;
        }
    }

    // Trim leading/trailing underscores.
    var slug = scratch[0..len];
    while (slug.len > 0 and slug[0] == '_') slug = slug[1..];
    while (slug.len > 0 and slug[slug.len - 1] == '_') slug = slug[0 .. slug.len - 1];

    const base = if (slug.len == 0) "archive" else slug;
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ base, ext });
}

/// Write a binary blob to an explicit path or a URL-derived default filename.
/// Used by --archive and --pdf (NOT --screenshot, which streams to stdout when no path).
fn writeBlobOutput(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    data: []const u8,
    explicit_path: ?[]const u8,
    url: []const u8,
    ext: []const u8,
    json_mode: bool,
) !void {
    // If no explicit path, derive one from the URL. `generated` owns that allocation
    // and is freed on scope exit; `path` borrows either the arg or the generated slug.
    var generated: ?[]u8 = null;
    defer if (generated) |g| allocator.free(g);
    const path = explicit_path orelse blk: {
        const g = defaultFilename(allocator, url, ext) catch {
            try stderr.print("Error: out of memory\n", .{});
            try stderr.flush();
            std.process.exit(1);
        };
        generated = g;
        break :blk g;
    };

    std.Io.Dir.writeFile(.cwd(), init.io, .{
        .sub_path = path,
        .data = data,
    }) catch {
        try stderr.print("Error: could not write to {s}\n", .{path});
        try stderr.flush();
        std.process.exit(1);
    };
    if (json_mode) {
        try stdout.print("{{\"file\":\"{s}\"}}\n", .{path});
    }
}

pub fn main(init: std.process.Init) !void {
    const stdout_file = std.Io.File.stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout = stdout_file.writerStreaming(init.io, &stdout_buf);

    const stderr_file = std.Io.File.stderr();
    var stderr_buf: [4096]u8 = undefined;
    var stderr = stderr_file.writerStreaming(init.io, &stderr_buf);

    const allocator = init.gpa;

    var args_iter = try init.minimal.args.iterateAllocator(allocator);
    defer args_iter.deinit();
    _ = args_iter.next(); // skip program name

    // Parse arguments
    var url: ?[]const u8 = null;
    var eval_js: ?[]const u8 = null;
    var eval_file: ?[]const u8 = null;
    var screenshot_mode = false;
    var screenshot_path: ?[]const u8 = null;
    var archive_mode = false;
    var archive_path: ?[]const u8 = null;
    var viewport_width: u32 = 1280;
    var viewport_height: u32 = 720;
    var wait_ms: u32 = 0;
    var timeout_ms: u32 = 30000;
    var json_mode = false;

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printUsage(&stdout.interface);
            try stdout.interface.flush();
            return;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            try stdout.interface.print("tezcatl " ++ version ++ " (" ++ @tagName(builtin.os.tag) ++ ")\n", .{});
            try stdout.interface.flush();
            return;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else if (std.mem.eql(u8, arg, "--screenshot")) {
            screenshot_mode = true;
        } else if (std.mem.startsWith(u8, arg, "--screenshot=")) {
            screenshot_mode = true;
            screenshot_path = arg["--screenshot=".len..];
        } else if (std.mem.eql(u8, arg, "--archive")) {
            archive_mode = true;
        } else if (std.mem.startsWith(u8, arg, "--archive=")) {
            archive_mode = true;
            archive_path = arg["--archive=".len..];
        } else if (std.mem.startsWith(u8, arg, "--width=")) {
            viewport_width = std.fmt.parseInt(u32, arg["--width=".len..], 10) catch {
                try stderr.interface.print("Error: invalid --width value\n", .{});
                try stderr.interface.flush();
                std.process.exit(2);
            };
        } else if (std.mem.startsWith(u8, arg, "--height=")) {
            viewport_height = std.fmt.parseInt(u32, arg["--height=".len..], 10) catch {
                try stderr.interface.print("Error: invalid --height value\n", .{});
                try stderr.interface.flush();
                std.process.exit(2);
            };
        } else if (std.mem.startsWith(u8, arg, "--eval-file=")) {
            eval_file = arg["--eval-file=".len..];
        } else if (std.mem.startsWith(u8, arg, "--eval=")) {
            eval_js = arg["--eval=".len..];
        } else if (std.mem.startsWith(u8, arg, "--wait=")) {
            wait_ms = std.fmt.parseInt(u32, arg["--wait=".len..], 10) catch {
                try stderr.interface.print("Error: invalid --wait value\n", .{});
                try stderr.interface.flush();
                std.process.exit(2);
            };
        } else if (std.mem.startsWith(u8, arg, "--timeout=")) {
            timeout_ms = std.fmt.parseInt(u32, arg["--timeout=".len..], 10) catch {
                try stderr.interface.print("Error: invalid --timeout value\n", .{});
                try stderr.interface.flush();
                std.process.exit(2);
            };
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try stderr.interface.print("Error: unknown flag: {s}\n", .{arg});
            try stderr.interface.flush();
            std.process.exit(2);
        } else {
            if (url == null) {
                url = arg;
            }
        }
    }

    if (eval_file) |path| {
        if (eval_js != null) {
            try stderr.interface.print("Error: cannot use both --eval and --eval-file\n", .{});
            try stderr.interface.flush();
            std.process.exit(2);
        }
        const contents = std.Io.Dir.readFileAlloc(.cwd(), init.io, path, allocator, std.Io.Limit.limited(10 * 1024 * 1024)) catch {
            try stderr.interface.print("Error: could not read file: {s}\n", .{path});
            try stderr.interface.flush();
            std.process.exit(1);
        };
        eval_js = contents;
    }

    const target_url = url orelse {
        try stderr.interface.print("Error: no URL provided\n\n", .{});
        try printUsage(&stderr.interface);
        try stderr.interface.flush();
        std.process.exit(1);
    };

    if (archive_mode and screenshot_mode) {
        try stderr.interface.print("Error: cannot use both --archive and --screenshot\n", .{});
        try stderr.interface.flush();
        std.process.exit(2);
    }

    if (archive_mode) {
        const result = webview.archive(allocator, target_url, wait_ms, timeout_ms, eval_js) catch |err| {
            try printError(&stderr.interface, err);
            try stderr.interface.flush();
            std.process.exit(1);
        };
        defer webview.freeArchiveResult(allocator, result);

        try writeBlobOutput(init, allocator, &stdout.interface, &stderr.interface, result.archive_data, archive_path, target_url, "webarchive", json_mode);
    } else if (screenshot_mode) {
        const result = webview.screenshot(allocator, target_url, wait_ms, timeout_ms, viewport_width, viewport_height, eval_js) catch |err| {
            try printError(&stderr.interface, err);
            try stderr.interface.flush();
            std.process.exit(1);
        };
        defer webview.freeScreenshotResult(allocator, result);

        if (screenshot_path) |path| {
            std.Io.Dir.writeFile(.cwd(), init.io, .{
                .sub_path = path,
                .data = result.png_data,
            }) catch {
                try stderr.interface.print("Error: could not write to {s}\n", .{path});
                try stderr.interface.flush();
                std.process.exit(1);
            };
            if (json_mode) {
                try stdout.interface.print("{{\"file\":\"{s}\"}}\n", .{path});
            }
        } else {
            // Write raw PNG to stdout
            try stdout.interface.flush();
            stdout_file.writeStreamingAll(init.io, result.png_data) catch {
                try stderr.interface.print("Error: failed writing screenshot to stdout\n", .{});
                try stderr.interface.flush();
                std.process.exit(1);
            };
        }
    } else if (eval_js) |js| {
        // --eval mode: evaluate custom JS and output result
        const result = webview.eval(allocator, target_url, js, wait_ms, timeout_ms) catch |err| {
            try printError(&stderr.interface, err);
            try stderr.interface.flush();
            std.process.exit(1);
        };
        defer webview.freeEvalResult(allocator, result);

        if (json_mode) {
            try stdout.interface.print("{{\"result\":\"", .{});
            try writeJsonString(&stdout.interface, result.output);
            try stdout.interface.print("\"}}\n", .{});
        } else {
            try stdout.interface.print("{s}\n", .{result.output});
        }
    } else {
        // Default mode: render and output DOM HTML
        const result = webview.render(allocator, target_url, wait_ms, timeout_ms) catch |err| {
            try printError(&stderr.interface, err);
            try stderr.interface.flush();
            std.process.exit(1);
        };
        defer webview.freeRenderResult(allocator, result);

        if (json_mode) {
            try stdout.interface.print("{{\"html\":\"", .{});
            try writeJsonString(&stdout.interface, result.html);
            try stdout.interface.print("\"}}\n", .{});
        } else {
            try stdout.interface.print("{s}\n", .{result.html});
        }
    }

    try stdout.interface.flush();
}

fn printError(writer: *std.Io.Writer, err: webview.WebViewError) !void {
    const msg: []const u8 = switch (err) {
        webview.WebViewError.FrameworkUnavailable => "WebKit framework not available",
        webview.WebViewError.NavigationFailed => "Navigation failed (check URL)",
        webview.WebViewError.JavaScriptError => "JavaScript evaluation error",
        webview.WebViewError.Timeout => "Navigation timed out",
        webview.WebViewError.OutOfMemory => "Out of memory",
        webview.WebViewError.ScreenshotFailed => "Screenshot capture failed",
        webview.WebViewError.ArchiveFailed => "Web archive capture failed",
    };
    try writer.print("Error: {s}\n", .{msg});
}

test "defaultFilename: plain host webarchive" {
    const a = std.testing.allocator;
    const out = try defaultFilename(a, "https://example.com", "webarchive");
    defer a.free(out);
    try std.testing.expectEqualStrings("example.com.webarchive", out);
}

test "defaultFilename: host and path with query" {
    const a = std.testing.allocator;
    const out = try defaultFilename(a, "https://example.com/blog/post?id=42", "webarchive");
    defer a.free(out);
    try std.testing.expectEqualStrings("example.com_blog_post_id_42.webarchive", out);
}

test "defaultFilename: trailing slash trimmed" {
    const a = std.testing.allocator;
    const out = try defaultFilename(a, "https://example.com/path/", "webarchive");
    defer a.free(out);
    try std.testing.expectEqualStrings("example.com_path.webarchive", out);
}

test "defaultFilename: http scheme stripped" {
    const a = std.testing.allocator;
    const out = try defaultFilename(a, "http://example.com", "webarchive");
    defer a.free(out);
    try std.testing.expectEqualStrings("example.com.webarchive", out);
}

test "defaultFilename: ip and port" {
    const a = std.testing.allocator;
    const out = try defaultFilename(a, "http://127.0.0.1:8080/x", "webarchive");
    defer a.free(out);
    try std.testing.expectEqualStrings("127.0.0.1_8080_x.webarchive", out);
}

test "defaultFilename: no scheme" {
    const a = std.testing.allocator;
    const out = try defaultFilename(a, "example.com/a", "webarchive");
    defer a.free(out);
    try std.testing.expectEqualStrings("example.com_a.webarchive", out);
}

test "defaultFilename: pdf extension" {
    const a = std.testing.allocator;
    const out = try defaultFilename(a, "https://example.com/report", "pdf");
    defer a.free(out);
    try std.testing.expectEqualStrings("example.com_report.pdf", out);
}
