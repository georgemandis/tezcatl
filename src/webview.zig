// Cross-platform dispatch layer for headless web rendering.
// Currently macOS-only (WKWebView via ObjC runtime bindings).

const std = @import("std");

const platform = switch (@import("builtin").os.tag) {
    .macos => @import("platform/macos.zig"),
    else => @compileError("tezcatl: unsupported platform (macOS only)"),
};

pub const WebViewError = error{
    FrameworkUnavailable,
    NavigationFailed,
    JavaScriptError,
    Timeout,
    OutOfMemory,
};

pub const RenderResult = struct {
    html: []const u8,
};

pub const EvalResult = struct {
    output: []const u8,
};

/// Load a URL in a headless WKWebView and return the rendered DOM HTML.
pub fn render(allocator: std.mem.Allocator, url: []const u8, wait_ms: u32, timeout_ms: u32) WebViewError!RenderResult {
    return platform.render(allocator, url, wait_ms, timeout_ms);
}

/// Load a URL and evaluate custom JavaScript, returning the string result.
pub fn eval(allocator: std.mem.Allocator, url: []const u8, js: []const u8, wait_ms: u32, timeout_ms: u32) WebViewError!EvalResult {
    return platform.eval(allocator, url, js, wait_ms, timeout_ms);
}

pub fn freeRenderResult(allocator: std.mem.Allocator, result: RenderResult) void {
    allocator.free(result.html);
}

pub fn freeEvalResult(allocator: std.mem.Allocator, result: EvalResult) void {
    allocator.free(result.output);
}
