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
    ScreenshotFailed,
    ArchiveFailed,
    PdfFailed,
};

pub const RenderResult = struct {
    html: []const u8,
};

pub const EvalResult = struct {
    output: []const u8,
};

pub const ScreenshotResult = struct {
    png_data: []const u8,
};

pub const ArchiveResult = struct {
    archive_data: []const u8,
};

pub const PdfResult = struct {
    pdf_data: []const u8,
};

/// Load a URL in a headless WKWebView and return the rendered DOM HTML.
pub fn render(allocator: std.mem.Allocator, url: []const u8, wait_ms: u32, timeout_ms: u32) WebViewError!RenderResult {
    return platform.render(allocator, url, wait_ms, timeout_ms);
}

/// Load a URL and evaluate custom JavaScript, returning the string result.
pub fn eval(allocator: std.mem.Allocator, url: []const u8, js: []const u8, wait_ms: u32, timeout_ms: u32) WebViewError!EvalResult {
    return platform.eval(allocator, url, js, wait_ms, timeout_ms);
}

/// Load a URL and take a screenshot, returning PNG data.
/// If eval_js is provided, it is executed before the snapshot is taken.
pub fn screenshot(allocator: std.mem.Allocator, url: []const u8, wait_ms: u32, timeout_ms: u32, width: u32, height: u32, eval_js: ?[]const u8) WebViewError!ScreenshotResult {
    return platform.screenshot(allocator, url, wait_ms, timeout_ms, width, height, eval_js);
}

/// Load a URL and capture it as a Safari .webarchive, returning the archive bytes.
/// If eval_js is provided, it is executed before the archive is captured.
pub fn archive(allocator: std.mem.Allocator, url: []const u8, wait_ms: u32, timeout_ms: u32, eval_js: ?[]const u8) WebViewError!ArchiveResult {
    return platform.archive(allocator, url, wait_ms, timeout_ms, eval_js);
}

/// Load a URL and capture it as a PDF, returning the PDF bytes.
/// If eval_js is provided, it is executed before the PDF is captured.
pub fn pdf(allocator: std.mem.Allocator, url: []const u8, wait_ms: u32, timeout_ms: u32, eval_js: ?[]const u8) WebViewError!PdfResult {
    return platform.pdf(allocator, url, wait_ms, timeout_ms, eval_js);
}

pub fn freeRenderResult(allocator: std.mem.Allocator, result: RenderResult) void {
    allocator.free(result.html);
}

pub fn freeEvalResult(allocator: std.mem.Allocator, result: EvalResult) void {
    allocator.free(result.output);
}

pub fn freeScreenshotResult(allocator: std.mem.Allocator, result: ScreenshotResult) void {
    allocator.free(result.png_data);
}

pub fn freeArchiveResult(allocator: std.mem.Allocator, result: ArchiveResult) void {
    allocator.free(result.archive_data);
}

pub fn freePdfResult(allocator: std.mem.Allocator, result: PdfResult) void {
    allocator.free(result.pdf_data);
}
