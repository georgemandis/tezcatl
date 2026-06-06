const std = @import("std");
const objc = @import("../objc.zig");
const webview = @import("../webview.zig");

// ---------------------------------------------------------------------------
// CoreFoundation run loop externs
// ---------------------------------------------------------------------------
extern "c" fn CFRunLoopGetCurrent() *anyopaque;
extern "c" fn CFRunLoopStop(rl: *anyopaque) void;
extern "c" fn CFRunLoopRunInMode(mode: objc.id, seconds: f64, returnAfterSourceHandled: bool) i32;
extern "c" var kCFRunLoopDefaultMode: objc.id;

// ---------------------------------------------------------------------------
// ObjC block ABI (for evaluateJavaScript:completionHandler:)
// ---------------------------------------------------------------------------
extern var _NSConcreteStackBlock: [1]usize;

const BlockDescriptor = extern struct {
    reserved: c_ulong,
    size: c_ulong,
};

const JSBlockLiteral = extern struct {
    isa: *anyopaque,
    flags: c_int,
    reserved: c_int,
    invoke: *const fn (*JSBlockLiteral, ?objc.id, ?objc.id) callconv(.c) void,
    descriptor: *const BlockDescriptor,
};

const js_block_descriptor = BlockDescriptor{
    .reserved = 0,
    .size = @sizeOf(JSBlockLiteral),
};

// ---------------------------------------------------------------------------
// Module-level state shared between callbacks
// ---------------------------------------------------------------------------
var delegate_class: ?objc.Class = null;
var nav_completed: bool = false;
var nav_error: bool = false;
var js_completed: bool = false;
var js_result_string: ?[]const u8 = null;
var js_error_occurred: bool = false;
var current_run_loop: ?*anyopaque = null;

// Screenshot state
var snapshot_completed: bool = false;
var snapshot_image: ?objc.id = null;
var snapshot_error_occurred: bool = false;

// ---------------------------------------------------------------------------
// WKNavigationDelegate callbacks
// ---------------------------------------------------------------------------

fn didFinishNavigation(_self: objc.id, _sel: objc.SEL, web_view: objc.id, navigation: objc.id) callconv(.c) void {
    _ = _self;
    _ = _sel;
    _ = web_view;
    _ = navigation;

    nav_completed = true;
    if (current_run_loop) |rl| CFRunLoopStop(rl);
}

fn didFailNavigation(_self: objc.id, _sel: objc.SEL, web_view: objc.id, navigation: objc.id, err: objc.id) callconv(.c) void {
    _ = _self;
    _ = _sel;
    _ = web_view;
    _ = navigation;
    _ = err;

    nav_error = true;
    nav_completed = true;
    if (current_run_loop) |rl| CFRunLoopStop(rl);
}

fn didFailProvisionalNavigation(_self: objc.id, _sel: objc.SEL, web_view: objc.id, navigation: objc.id, err: objc.id) callconv(.c) void {
    _ = _self;
    _ = _sel;
    _ = web_view;
    _ = navigation;
    _ = err;

    nav_error = true;
    nav_completed = true;
    if (current_run_loop) |rl| CFRunLoopStop(rl);
}

// ---------------------------------------------------------------------------
// JavaScript evaluation block callback
// ---------------------------------------------------------------------------

fn jsBlockInvoke(block: *JSBlockLiteral, result: ?objc.id, err: ?objc.id) callconv(.c) void {
    _ = block;

    if (err != null or result == null) {
        js_error_occurred = err != null;
        js_completed = true;
        if (current_run_loop) |rl| CFRunLoopStop(rl);
        return;
    }

    const res = result.?;

    // Check if result is an NSString
    const NSString = objc.getClass("NSString") orelse {
        js_completed = true;
        if (current_run_loop) |rl| CFRunLoopStop(rl);
        return;
    };
    const is_string = objc.msgSend(bool, res, objc.sel("isKindOfClass:"), .{@as(objc.id, @ptrCast(NSString))});

    var ns_str: objc.id = undefined;
    if (is_string) {
        ns_str = res;
    } else {
        // Call -description to get a string representation
        ns_str = objc.msgSend(objc.id, res, objc.sel("description"), .{});
    }

    const cstr = objc.fromNSString(ns_str) orelse {
        js_completed = true;
        if (current_run_loop) |rl| CFRunLoopStop(rl);
        return;
    };

    const slice = std.mem.sliceTo(cstr, 0);
    const copy = std.heap.c_allocator.dupe(u8, slice) catch {
        js_completed = true;
        if (current_run_loop) |rl| CFRunLoopStop(rl);
        return;
    };

    js_result_string = copy;
    js_completed = true;
    if (current_run_loop) |rl| CFRunLoopStop(rl);
}

// ---------------------------------------------------------------------------
// Snapshot (screenshot) block callback
// ---------------------------------------------------------------------------

fn snapshotBlockInvoke(block: *JSBlockLiteral, image: ?objc.id, err: ?objc.id) callconv(.c) void {
    _ = block;

    if (err != null or image == null) {
        snapshot_error_occurred = err != null;
        snapshot_completed = true;
        if (current_run_loop) |rl| CFRunLoopStop(rl);
        return;
    }

    // Retain the image so it survives the autorelease pool drain
    const res = image.?;
    objc.msgSend(void, res, objc.sel("retain"), .{});
    snapshot_image = res;
    snapshot_completed = true;
    if (current_run_loop) |rl| CFRunLoopStop(rl);
}

// ---------------------------------------------------------------------------
// Delegate class registration
// ---------------------------------------------------------------------------

fn ensureDelegateClass() void {
    if (delegate_class != null) return;

    const NSObject = objc.getClass("NSObject") orelse unreachable;
    const cls = objc.allocateClassPair(NSObject, "TezcatlNavDelegate") orelse unreachable;

    // webView:didFinishNavigation: — "v@:@@"
    _ = objc.addMethod(
        cls,
        objc.sel("webView:didFinishNavigation:"),
        @ptrCast(&didFinishNavigation),
        "v@:@@",
    );

    // webView:didFailNavigation:withError: — "v@:@@@"
    _ = objc.addMethod(
        cls,
        objc.sel("webView:didFailNavigation:withError:"),
        @ptrCast(&didFailNavigation),
        "v@:@@@",
    );

    // webView:didFailProvisionalNavigation:withError: — "v@:@@@"
    _ = objc.addMethod(
        cls,
        objc.sel("webView:didFailProvisionalNavigation:withError:"),
        @ptrCast(&didFailProvisionalNavigation),
        "v@:@@@",
    );

    objc.registerClassPair(cls);
    delegate_class = cls;
}

// ---------------------------------------------------------------------------
// Shared setup: create NSApplication, WKWebView, load URL, wait for nav
// ---------------------------------------------------------------------------

const SetupResult = struct {
    wk_webview: objc.id,
    pool: objc.id,
    window: ?objc.id = null,
};

fn setup(url: []const u8, timeout_ms: u32, wait_ms: u32, width: u32, height: u32, needs_window: bool) webview.WebViewError!SetupResult {
    const pool = objc.autoreleasePoolPush();

    // Initialize NSApplication as accessory (no Dock icon, no menu bar)
    const NSApp = objc.getClass("NSApplication") orelse return webview.WebViewError.FrameworkUnavailable;
    const app = objc.msgSend(objc.id, NSApp, objc.sel("sharedApplication"), .{});
    // NSApplicationActivationPolicyAccessory = 1 (suppresses Dock icon)
    objc.msgSend(void, app, objc.sel("setActivationPolicy:"), .{@as(objc.NSInteger, 1)});

    // Create WKWebViewConfiguration
    const WKWebViewConfiguration = objc.getClass("WKWebViewConfiguration") orelse
        return webview.WebViewError.FrameworkUnavailable;
    const config_alloc = objc.msgSend(objc.id, WKWebViewConfiguration, objc.sel("alloc"), .{});
    const config = objc.msgSend(objc.id, config_alloc, objc.sel("init"), .{});

    // Enable JavaScript
    const prefs = objc.msgSend(objc.id, config, objc.sel("preferences"), .{});
    objc.msgSend(void, prefs, objc.sel("setJavaScriptCanOpenWindowsAutomatically:"), .{@as(bool, true)});

    // Create WKWebView with offscreen frame
    const WKWebView = objc.getClass("WKWebView") orelse
        return webview.WebViewError.FrameworkUnavailable;
    const wk_alloc = objc.msgSend(objc.id, WKWebView, objc.sel("alloc"), .{});
    const frame = objc.CGRect{
        .origin = .{ .x = -10000, .y = -10000 },
        .size = .{ .width = @floatFromInt(width), .height = @floatFromInt(height) },
    };
    const wk_webview = objc.msgSend(objc.id, wk_alloc, objc.sel("initWithFrame:configuration:"), .{ frame, config });

    // For screenshots, WKWebView must be in a window for takeSnapshot to work
    var window: ?objc.id = null;
    if (needs_window) {
        const NSWindow = objc.getClass("NSWindow") orelse
            return webview.WebViewError.FrameworkUnavailable;
        const win_alloc = objc.msgSend(objc.id, NSWindow, objc.sel("alloc"), .{});
        const win_frame = objc.CGRect{
            .origin = .{ .x = -10000, .y = -10000 },
            .size = .{ .width = @floatFromInt(width), .height = @floatFromInt(height) },
        };
        // NSWindowStyleMaskBorderless = 0
        // NSBackingStoreBuffered = 2
        const win = objc.msgSend(objc.id, win_alloc, objc.sel("initWithContentRect:styleMask:backing:defer:"), .{
            win_frame,
            @as(objc.NSUInteger, 0),
            @as(objc.NSUInteger, 2),
            @as(bool, false),
        });
        objc.msgSend(void, win, objc.sel("setContentView:"), .{wk_webview});
        window = win;
    }

    // Set up navigation delegate
    ensureDelegateClass();
    const del_cls = delegate_class.?;
    const del_alloc = objc.msgSend(objc.id, del_cls, objc.sel("alloc"), .{});
    const delegate = objc.msgSend(objc.id, del_alloc, objc.sel("init"), .{});
    objc.msgSend(void, wk_webview, objc.sel("setNavigationDelegate:"), .{delegate});

    // Create NSURL and NSURLRequest
    const ns_url_str = objc.nsStringFromSlice(url.ptr, url.len) orelse
        return webview.WebViewError.NavigationFailed;
    const NSURL = objc.getClass("NSURL") orelse return webview.WebViewError.FrameworkUnavailable;
    const ns_url = objc.msgSend(?objc.id, NSURL, objc.sel("URLWithString:"), .{ns_url_str}) orelse
        return webview.WebViewError.NavigationFailed;
    const NSURLRequest = objc.getClass("NSURLRequest") orelse
        return webview.WebViewError.FrameworkUnavailable;
    const request = objc.msgSend(objc.id, NSURLRequest, objc.sel("requestWithURL:"), .{ns_url});

    // Reset navigation state
    nav_completed = false;
    nav_error = false;

    // Load the request
    objc.msgSend(void, wk_webview, objc.sel("loadRequest:"), .{request});

    // Pump run loop until navigation completes or timeout
    const timeout_seconds: f64 = @as(f64, @floatFromInt(timeout_ms)) / 1000.0;
    current_run_loop = CFRunLoopGetCurrent();
    _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode, timeout_seconds, false);

    if (!nav_completed) {
        current_run_loop = null;
        objc.autoreleasePoolPop(pool);
        return webview.WebViewError.Timeout;
    }
    if (nav_error) {
        current_run_loop = null;
        objc.autoreleasePoolPop(pool);
        return webview.WebViewError.NavigationFailed;
    }

    // Optional wait for JS to settle (SPAs, dynamic content)
    if (wait_ms > 0) {
        const wait_seconds: f64 = @as(f64, @floatFromInt(wait_ms)) / 1000.0;
        _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode, wait_seconds, false);
    }

    return .{ .wk_webview = wk_webview, .pool = pool, .window = window };
}

fn evalJS(wk_webview: objc.id, js_code: []const u8, timeout_ms: u32) webview.WebViewError!void {
    // Reset JS state
    js_completed = false;
    js_result_string = null;
    js_error_occurred = false;

    // Create NSString from JS code
    const ns_js = objc.nsStringFromSlice(js_code.ptr, js_code.len) orelse
        return webview.WebViewError.JavaScriptError;

    // Build the completion handler block
    var block = JSBlockLiteral{
        .isa = @ptrCast(&_NSConcreteStackBlock),
        .flags = 0,
        .reserved = 0,
        .invoke = &jsBlockInvoke,
        .descriptor = &js_block_descriptor,
    };

    // evaluateJavaScript:completionHandler:
    objc.msgSend(void, wk_webview, objc.sel("evaluateJavaScript:completionHandler:"), .{
        ns_js,
        @as(objc.id, @ptrCast(&block)),
    });

    // Pump run loop for JS execution
    const timeout_seconds: f64 = @as(f64, @floatFromInt(timeout_ms)) / 1000.0;
    _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode, timeout_seconds, false);

    if (!js_completed) {
        return webview.WebViewError.Timeout;
    }
    if (js_error_occurred and js_result_string == null) {
        return webview.WebViewError.JavaScriptError;
    }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

pub fn render(allocator: std.mem.Allocator, url: []const u8, wait_ms: u32, timeout_ms: u32) webview.WebViewError!webview.RenderResult {
    const s = try setup(url, timeout_ms, wait_ms, 1280, 720, false);
    defer {
        current_run_loop = null;
        objc.autoreleasePoolPop(s.pool);
    }

    // Get the rendered DOM: document.documentElement.outerHTML
    try evalJS(s.wk_webview, "document.documentElement.outerHTML", timeout_ms);

    const html_c = js_result_string orelse return webview.WebViewError.JavaScriptError;

    // Copy from c_allocator to caller's allocator
    const html = allocator.dupe(u8, html_c) catch return webview.WebViewError.OutOfMemory;
    std.heap.c_allocator.free(@constCast(html_c));
    js_result_string = null;

    return .{ .html = html };
}

pub fn eval(allocator: std.mem.Allocator, url: []const u8, js: []const u8, wait_ms: u32, timeout_ms: u32) webview.WebViewError!webview.EvalResult {
    const s = try setup(url, timeout_ms, wait_ms, 1280, 720, false);
    defer {
        current_run_loop = null;
        objc.autoreleasePoolPop(s.pool);
    }

    try evalJS(s.wk_webview, js, timeout_ms);

    const output_c = js_result_string orelse return webview.WebViewError.JavaScriptError;

    const output = allocator.dupe(u8, output_c) catch return webview.WebViewError.OutOfMemory;
    std.heap.c_allocator.free(@constCast(output_c));
    js_result_string = null;

    return .{ .output = output };
}

pub fn screenshot(allocator: std.mem.Allocator, url: []const u8, wait_ms: u32, timeout_ms: u32, width: u32, height: u32, eval_js_code: ?[]const u8) webview.WebViewError!webview.ScreenshotResult {
    const s = try setup(url, timeout_ms, wait_ms, width, height, true);
    defer {
        current_run_loop = null;
        objc.autoreleasePoolPop(s.pool);
    }

    // Run optional JS before taking the screenshot
    if (eval_js_code) |js| {
        try evalJS(s.wk_webview, js, timeout_ms);
        // Discard the JS result string — we only care about its side effects
        if (js_result_string) |res| {
            std.heap.c_allocator.free(@constCast(res));
            js_result_string = null;
        }
    }

    // Reset snapshot state
    snapshot_completed = false;
    snapshot_image = null;
    snapshot_error_occurred = false;

    // Create WKSnapshotConfiguration
    const WKSnapshotConfiguration = objc.getClass("WKSnapshotConfiguration") orelse
        return webview.WebViewError.ScreenshotFailed;
    const config_alloc = objc.msgSend(objc.id, WKSnapshotConfiguration, objc.sel("alloc"), .{});
    const config = objc.msgSend(objc.id, config_alloc, objc.sel("init"), .{});

    // Set snapshot rect to full viewport
    const rect = objc.CGRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = @floatFromInt(width), .height = @floatFromInt(height) },
    };
    objc.msgSend(void, config, objc.sel("setRect:"), .{rect});

    // Build the completion handler block (reuses JSBlockLiteral since same signature)
    var block = JSBlockLiteral{
        .isa = @ptrCast(&_NSConcreteStackBlock),
        .flags = 0,
        .reserved = 0,
        .invoke = &snapshotBlockInvoke,
        .descriptor = &js_block_descriptor,
    };

    // takeSnapshotWithConfiguration:completionHandler:
    objc.msgSend(void, s.wk_webview, objc.sel("takeSnapshotWithConfiguration:completionHandler:"), .{
        config,
        @as(objc.id, @ptrCast(&block)),
    });

    // Pump run loop for snapshot
    const timeout_seconds: f64 = @as(f64, @floatFromInt(timeout_ms)) / 1000.0;
    _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode, timeout_seconds, false);

    if (!snapshot_completed or snapshot_error_occurred or snapshot_image == null) {
        return webview.WebViewError.ScreenshotFailed;
    }

    const image = snapshot_image.?;
    defer objc.msgSend(void, image, objc.sel("release"), .{});

    // Convert NSImage -> NSBitmapImageRep -> PNG NSData
    // Get TIFFRepresentation from NSImage
    const tiff_data = objc.msgSend(?objc.id, image, objc.sel("TIFFRepresentation"), .{}) orelse
        return webview.WebViewError.ScreenshotFailed;

    // Create NSBitmapImageRep from TIFF data
    const NSBitmapImageRep = objc.getClass("NSBitmapImageRep") orelse
        return webview.WebViewError.ScreenshotFailed;
    const bitmap_rep = objc.msgSend(?objc.id, NSBitmapImageRep, objc.sel("imageRepWithData:"), .{tiff_data}) orelse
        return webview.WebViewError.ScreenshotFailed;

    // representationUsingType:properties: with NSBitmapImageFileTypePNG = 4
    const NSDictionary = objc.getClass("NSDictionary") orelse
        return webview.WebViewError.ScreenshotFailed;
    const empty_dict = objc.msgSend(objc.id, NSDictionary, objc.sel("dictionary"), .{});
    const png_data = objc.msgSend(?objc.id, bitmap_rep, objc.sel("representationUsingType:properties:"), .{
        @as(objc.NSUInteger, 4), // NSBitmapImageFileTypePNG
        empty_dict,
    }) orelse return webview.WebViewError.ScreenshotFailed;

    // Extract bytes from NSData
    const length = objc.msgSend(objc.NSUInteger, png_data, objc.sel("length"), .{});
    const bytes_ptr = objc.msgSend([*]const u8, png_data, objc.sel("bytes"), .{});
    const bytes_slice = bytes_ptr[0..length];

    // Copy to caller's allocator
    const result = allocator.dupe(u8, bytes_slice) catch return webview.WebViewError.OutOfMemory;

    return .{ .png_data = result };
}
