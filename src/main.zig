const std = @import("std");
const builtin = @import("builtin");
const webview = @import("webview");

const version = "0.1.0";

fn printUsage(writer: anytype) !void {
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
        \\  tezcatl <url> --screenshot Capture a PNG snapshot of the page
        \\
        \\Options:
        \\  --eval=JS            Evaluate custom JavaScript instead of returning DOM
        \\  --eval-file=PATH     Read JavaScript from a file and evaluate it (alias: --js-file)
        \\  --screenshot         Capture a PNG snapshot of the page
        \\  --full               Capture full height of the page instead of just the viewport
        \\  --settle=MS          Settle time in ms after evaluating JS before screenshot (default: 200)
        \\  --wait=MS            Wait N ms after page load for JS to settle (default: 0)
        \\  --timeout=MS         Navigation timeout in ms (default: 30000)
        \\  --json               Wrap output in JSON (eval result, HTML, or base64 screenshot)
        \\  --help, -h           Show this help message
        \\  --version, -v        Show version
        \\
        \\Examples:
        \\  tezcatl https://example.com
        \\  tezcatl https://spa-site.com --wait=2000
        \\  tezcatl https://example.com --eval="document.title"
        \\  tezcatl https://example.com --screenshot > screenshot.png
        \\
        \\Created by George Mandis <george@mand.is>
        \\
    , .{ version, @tagName(builtin.os.tag) });
}

fn writeJsonString(writer: anytype, s: []const u8) !void {
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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;

    var args_iter = try std.process.argsWithAllocator(allocator);
    defer args_iter.deinit();
    _ = args_iter.next(); // skip program name

    // Parse arguments
    var url: ?[]const u8 = null;
    var eval_js: ?[]const u8 = null;
    var eval_file: ?[]const u8 = null;
    var screenshot_mode = false;
    var full_page = false;
    var settle_ms: u32 = 200;
    var wait_ms: u32 = 0;
    var timeout_ms: u32 = 30000;
    var json_mode = false;

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printUsage(stdout);
            try stdout.flush();
            return;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            try stdout.print("tezcatl " ++ version ++ " (" ++ @tagName(builtin.os.tag) ++ ")\n", .{});
            try stdout.flush();
            return;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else if (std.mem.eql(u8, arg, "--screenshot")) {
            screenshot_mode = true;
        } else if (std.mem.eql(u8, arg, "--full")) {
            full_page = true;
        } else if (std.mem.startsWith(u8, arg, "--eval=")) {
            eval_js = arg["--eval=".len..];
        } else if (std.mem.startsWith(u8, arg, "--eval-file=")) {
            eval_file = arg["--eval-file=".len..];
        } else if (std.mem.startsWith(u8, arg, "--js-file=")) {
            eval_file = arg["--js-file=".len..];
        } else if (std.mem.startsWith(u8, arg, "--settle=")) {
            settle_ms = std.fmt.parseInt(u32, arg["--settle=".len..], 10) catch {
                try stderr.print("Error: invalid --settle value\n", .{});
                try stderr.flush();
                std.process.exit(2);
            };
        } else if (std.mem.startsWith(u8, arg, "--wait=")) {
            wait_ms = std.fmt.parseInt(u32, arg["--wait=".len..], 10) catch {
                try stderr.print("Error: invalid --wait value\n", .{});
                try stderr.flush();
                std.process.exit(2);
            };
        } else if (std.mem.startsWith(u8, arg, "--timeout=")) {
            timeout_ms = std.fmt.parseInt(u32, arg["--timeout=".len..], 10) catch {
                try stderr.print("Error: invalid --timeout value\n", .{});
                try stderr.flush();
                std.process.exit(2);
            };
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try stderr.print("Error: unknown flag: {s}\n", .{arg});
            try stderr.flush();
            std.process.exit(2);
        } else {
            if (url == null) {
                url = arg;
            }
        }
    }

    const target_url = url orelse {
        try stderr.print("Error: no URL provided\n\n", .{});
        try printUsage(stderr);
        try stderr.flush();
        std.process.exit(1);
    };

    var file_eval_js: ?[]const u8 = null;
    defer if (file_eval_js) |js| allocator.free(js);

    if (eval_file) |path| {
        file_eval_js = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |err| {
            try stderr.print("Error: failed to read script file '{s}' ({s})\n", .{ path, @errorName(err) });
            try stderr.flush();
            std.process.exit(1);
        };
    }

    const active_js = file_eval_js orelse eval_js;

    if (screenshot_mode) {
        const result = webview.screenshot(allocator, target_url, wait_ms, timeout_ms, full_page, active_js, settle_ms) catch |err| {
            try printError(stderr, err);
            try stderr.flush();
            std.process.exit(1);
        };
        defer webview.freeScreenshotResult(allocator, result);

        if (json_mode) {
            const encoder = std.base64.standard.Encoder;
            const encoded_len = encoder.calcSize(result.data.len);
            const buf = try allocator.alloc(u8, encoded_len);
            defer allocator.free(buf);
            _ = encoder.encode(buf, result.data);

            try stdout.print("{{\"screenshot\":\"{s}\"}}\n", .{buf});
        } else {
            // Write raw binary data directly to stdout. Flush first to prevent interface mixups.
            try stdout.flush();
            try std.fs.File.stdout().writeAll(result.data);
        }
    } else if (active_js) |js| {
        // --eval mode: evaluate custom JS and output result
        const result = webview.eval(allocator, target_url, js, wait_ms, timeout_ms) catch |err| {
            try printError(stderr, err);
            try stderr.flush();
            std.process.exit(1);
        };
        defer webview.freeEvalResult(allocator, result);

        if (json_mode) {
            try stdout.print("{{\"result\":\"", .{});
            try writeJsonString(stdout, result.output);
            try stdout.print("\"}}\n", .{});
        } else {
            try stdout.print("{s}\n", .{result.output});
        }
    } else {
        // Default mode: render and output DOM HTML
        const result = webview.render(allocator, target_url, wait_ms, timeout_ms) catch |err| {
            try printError(stderr, err);
            try stderr.flush();
            std.process.exit(1);
        };
        defer webview.freeRenderResult(allocator, result);

        if (json_mode) {
            try stdout.print("{{\"html\":\"", .{});
            try writeJsonString(stdout, result.html);
            try stdout.print("\"}}\n", .{});
        } else {
            try stdout.print("{s}\n", .{result.html});
        }
    }

    try stdout.flush();
}

fn printError(writer: anytype, err: webview.WebViewError) !void {
    const msg: []const u8 = switch (err) {
        webview.WebViewError.FrameworkUnavailable => "WebKit framework not available",
        webview.WebViewError.NavigationFailed => "Navigation failed (check URL)",
        webview.WebViewError.JavaScriptError => blk: {
            if (webview.getJsErrorMessage()) |js_err| {
                break :blk js_err;
            }
            break :blk "JavaScript evaluation error";
        },
        webview.WebViewError.Timeout => "Navigation timed out",
        webview.WebViewError.OutOfMemory => "Out of memory",
    };
    try writer.print("Error: {s}\n", .{msg});
}
