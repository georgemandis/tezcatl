const std = @import("std");
const builtin = @import("builtin");
const webview = @import("webview");

const version = "0.1.0";

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
        \\  curl -s https://example.com | lingua detect   # pipe rendered HTML
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

    const target_url = url orelse {
        try stderr.interface.print("Error: no URL provided\n\n", .{});
        try printUsage(&stderr.interface);
        try stderr.interface.flush();
        std.process.exit(1);
    };

    if (eval_js) |js| {
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
    };
    try writer.print("Error: {s}\n", .{msg});
}
