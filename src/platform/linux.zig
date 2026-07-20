// Linux backend for tezcatl, built on WebKit's GLib API.
//
// Two display backends are selectable at build time (see build.zig, -Dwpe):
//
//   * WPE WebKit + WPEPlatform headless display  (DEFAULT, -Dwpe=true)
//       True headless: renders with no X server and no Wayland. Best fit for
//       servers / containers / CI. Uses wpe_display_headless_new() and creates
//       the view via g_object_new(WEBKIT_TYPE_WEB_VIEW, "display", display, ...).
//       pkg-config: wpe-webkit-2.0, wpe-platform-2.0.
//
//   * WebKitGTK 6.0 (GTK4)                        (-Dwpe=false)
//       Same engine, but GTK wants a display, so headless runs go through Xvfb:
//         xvfb-run -a ./zig-out/bin/tezcatl https://example.com
//       pkg-config: webkitgtk-6.0, gtk4.
//
// Everything after view creation is SHARED: both ports expose the identical
// libwebkit GLib API (webkit_web_view_load_uri, the "load-changed" signal,
// webkit_web_view_evaluate_javascript). Only createWebView() differs, and it is
// pruned at compile time by the comptime `use_wpe` flag.
//
// This mirrors the macOS/WKWebView backend: load a URL, pump a run loop
// (GLib GMainLoop here, CFRunLoop there) until navigation finishes, optionally
// wait for JS to settle, then evaluate JavaScript and return the string result.
//
// STATUS: experimental / unverified. Not yet compiled/run against WebKit on a
// real machine — treat as a structurally-complete starting point. The exact
// WPE pkg-config module names and the wpe_display_headless_new() linkage are
// the most likely things to need a small tweak per WPE version (see build.zig).

const std = @import("std");
const webview = @import("../webview.zig");

// Build-time backend selection (default: WPE headless). See build.zig.
const use_wpe = @import("build_options").use_wpe;

// ---------------------------------------------------------------------------
// Shared GLib / GObject / WebKit GLib-API externs
//
// All GObject-derived pointers are opaque; we only pass them back to the C API.
// gboolean is a C int; gssize is isize; GType is gsize (usize). NULL = `null`.
// ---------------------------------------------------------------------------

const gpointer = ?*anyopaque;
const GAsyncReadyCallback = *const fn (source: gpointer, res: gpointer, user_data: gpointer) callconv(.c) void;
const GSourceFunc = *const fn (user_data: gpointer) callconv(.c) c_int;
const GCallback = *const fn () callconv(.c) void;

// WebKit GLib API — identical symbols on both the WPE and GTK ports.
extern "c" fn webkit_web_view_load_uri(web_view: gpointer, uri: [*:0]const u8) void;
extern "c" fn webkit_web_view_evaluate_javascript(
    web_view: gpointer,
    script: [*:0]const u8,
    length: isize, // gssize; -1 = script is NUL-terminated
    world_name: ?[*:0]const u8, // NULL = default world
    source_uri: ?[*:0]const u8, // NULL
    cancellable: gpointer, // GCancellable*; NULL
    callback: GAsyncReadyCallback,
    user_data: gpointer,
) void;
extern "c" fn webkit_web_view_evaluate_javascript_finish(
    web_view: gpointer,
    result: gpointer, // GAsyncResult*
    err_out: ?*gpointer, // GError**
) gpointer; // JSCValue* (NULL on error)

// JavaScriptCore value -> string (g_free the result).
extern "c" fn jsc_value_to_string(value: gpointer) ?[*:0]u8;

// GLib main loop + timeouts + signals + memory.
extern "c" fn g_main_loop_new(context: gpointer, is_running: c_int) gpointer;
extern "c" fn g_main_loop_run(loop: gpointer) void;
extern "c" fn g_main_loop_quit(loop: gpointer) void;
extern "c" fn g_main_loop_unref(loop: gpointer) void;
extern "c" fn g_timeout_add(interval_ms: c_uint, function: GSourceFunc, data: gpointer) c_uint;
extern "c" fn g_source_remove(tag: c_uint) c_int;
extern "c" fn g_signal_connect_data(
    instance: gpointer,
    detailed_signal: [*:0]const u8,
    c_handler: GCallback,
    data: gpointer,
    destroy_data: gpointer, // GClosureNotify; NULL
    connect_flags: c_uint, // 0
) c_ulong;
extern "c" fn g_free(mem: gpointer) void;

// ---------------------------------------------------------------------------
// WPE-only externs (referenced only when use_wpe == true; the comptime branch
// prunes them out of the GTK build so their libraries aren't required there).
// ---------------------------------------------------------------------------
extern "c" fn wpe_display_headless_new() gpointer; // WPEDisplay*
extern "c" fn webkit_web_view_get_type() usize; // GType (WEBKIT_TYPE_WEB_VIEW)
// g_object_new is variadic: (GType, first_prop_name, value, ..., NULL).
extern "c" fn g_object_new(object_type: usize, first_property_name: ?[*:0]const u8, ...) gpointer;

// ---------------------------------------------------------------------------
// GTK-only externs (referenced only when use_wpe == false).
// ---------------------------------------------------------------------------
extern "c" fn gtk_init() void;
extern "c" fn gtk_window_new() gpointer; // GtkWidget*
extern "c" fn gtk_window_set_default_size(window: gpointer, width: c_int, height: c_int) void;
extern "c" fn gtk_window_set_child(window: gpointer, child: gpointer) void;
extern "c" fn gtk_window_present(window: gpointer) void;
extern "c" fn webkit_web_view_new() gpointer; // GtkWidget* (a WebKitWebView)

// WebKitLoadEvent enum value.
const WEBKIT_LOAD_FINISHED: c_int = 3;
// GSourceFunc return: remove the source after it fires.
const G_SOURCE_REMOVE: c_int = 0;

// ---------------------------------------------------------------------------
// Module-level state shared between callbacks (single-shot CLI: globals are OK,
// matching the macOS backend).
// ---------------------------------------------------------------------------
var gtk_initialized: bool = false;
var main_loop: gpointer = null;

var nav_finished: bool = false;
var nav_timed_out: bool = false;

var js_done: bool = false;
var js_error: bool = false;
var js_result: ?[]u8 = null; // owned by c_allocator

// ---------------------------------------------------------------------------
// Callbacks
// ---------------------------------------------------------------------------

// "load-changed" signal: void (WebKitWebView*, WebKitLoadEvent, gpointer).
fn onLoadChanged(_web_view: gpointer, load_event: c_int, _user_data: gpointer) callconv(.c) void {
    _ = _web_view;
    _ = _user_data;
    if (load_event == WEBKIT_LOAD_FINISHED) {
        nav_finished = true;
        if (main_loop) |loop| g_main_loop_quit(loop);
    }
}

// Navigation timeout: fires if the page never finishes loading.
fn onNavTimeout(_user_data: gpointer) callconv(.c) c_int {
    _ = _user_data;
    if (!nav_finished) {
        nav_timed_out = true;
        if (main_loop) |loop| g_main_loop_quit(loop);
    }
    return G_SOURCE_REMOVE;
}

// Generic "quit the loop" timeout, used for the post-load settle wait and as
// the watchdog for the async JS evaluation.
fn onWaitElapsed(_user_data: gpointer) callconv(.c) c_int {
    _ = _user_data;
    if (main_loop) |loop| g_main_loop_quit(loop);
    return G_SOURCE_REMOVE;
}

// GAsyncReadyCallback for evaluate_javascript. `source` is the WebKitWebView*.
fn onJsFinished(source: gpointer, res: gpointer, _user_data: gpointer) callconv(.c) void {
    _ = _user_data;

    var err: gpointer = null;
    const value = webkit_web_view_evaluate_javascript_finish(source, res, &err);
    if (value == null or err != null) {
        js_error = true;
        js_done = true;
        if (main_loop) |loop| g_main_loop_quit(loop);
        return;
    }

    const c_str = jsc_value_to_string(value); // NUL-terminated, g_free-owned
    if (c_str) |ptr| {
        const slice = std.mem.sliceTo(ptr, 0);
        js_result = std.heap.c_allocator.dupe(u8, slice) catch null;
        g_free(@ptrCast(ptr));
        if (js_result == null) js_error = true;
    } else {
        js_error = true;
    }

    js_done = true;
    if (main_loop) |loop| g_main_loop_quit(loop);
}

// ---------------------------------------------------------------------------
// Backend-specific view creation (comptime-pruned).
// Returns a WebKitWebView*. For WPE this also creates the headless display and
// (implicitly) keeps it alive for process lifetime.
// ---------------------------------------------------------------------------

fn createWebView(width: u32, height: u32) webview.WebViewError!gpointer {
    if (use_wpe) {
        // WPEPlatform headless: no display server, no window, no Xvfb.
        const display = wpe_display_headless_new();
        if (display == null) return webview.WebViewError.FrameworkUnavailable;

        // g_object_new(WEBKIT_TYPE_WEB_VIEW, "display", display, NULL)
        const gtype = webkit_web_view_get_type();
        const web_view = g_object_new(gtype, "display", display, @as(gpointer, null));
        if (web_view == null) return webview.WebViewError.FrameworkUnavailable;

        _ = width;
        _ = height;
        return web_view;
    } else {
        // WebKitGTK: realize the view inside a presented top-level window.
        // Under Xvfb nothing is shown on any real screen.
        if (!gtk_initialized) {
            gtk_init();
            gtk_initialized = true;
        }
        const web_view = webkit_web_view_new();
        if (web_view == null) return webview.WebViewError.FrameworkUnavailable;

        const window = gtk_window_new();
        if (window == null) return webview.WebViewError.FrameworkUnavailable;
        gtk_window_set_default_size(window, @intCast(width), @intCast(height));
        gtk_window_set_child(window, web_view);
        gtk_window_present(window);
        return web_view;
    }
}

// ---------------------------------------------------------------------------
// Shared setup: create the view, load the URL, wait for load to finish.
// ---------------------------------------------------------------------------

fn setup(url: []const u8, timeout_ms: u32, wait_ms: u32, width: u32, height: u32) webview.WebViewError!gpointer {
    const web_view = try createWebView(width, height);

    // Observe load progress.
    _ = g_signal_connect_data(
        web_view,
        "load-changed",
        @ptrCast(&onLoadChanged),
        null,
        null,
        0,
    );

    // NUL-terminate the URL for the C API.
    const url_z = std.heap.c_allocator.dupeZ(u8, url) catch
        return webview.WebViewError.OutOfMemory;
    defer std.heap.c_allocator.free(url_z);

    // Reset navigation state and kick off the load.
    nav_finished = false;
    nav_timed_out = false;
    main_loop = g_main_loop_new(null, 0);
    if (main_loop == null) return webview.WebViewError.FrameworkUnavailable;

    webkit_web_view_load_uri(web_view, url_z.ptr);

    // Arm the navigation timeout, then pump the loop until load-finished
    // or timeout quits it.
    const nav_timeout_id = g_timeout_add(timeout_ms, &onNavTimeout, null);
    g_main_loop_run(main_loop);
    if (nav_finished) _ = g_source_remove(nav_timeout_id);

    if (nav_timed_out and !nav_finished) return webview.WebViewError.Timeout;
    if (!nav_finished) return webview.WebViewError.NavigationFailed;

    // Optional settle wait for SPAs / late-rendering JS.
    if (wait_ms > 0) {
        _ = g_timeout_add(wait_ms, &onWaitElapsed, null);
        g_main_loop_run(main_loop);
    }

    return web_view;
}

fn evalJS(web_view: gpointer, js_code: []const u8, timeout_ms: u32) webview.WebViewError!void {
    js_done = false;
    js_error = false;
    js_result = null;

    const js_z = std.heap.c_allocator.dupeZ(u8, js_code) catch
        return webview.WebViewError.OutOfMemory;
    defer std.heap.c_allocator.free(js_z);

    webkit_web_view_evaluate_javascript(
        web_view,
        js_z.ptr,
        -1,
        null,
        null,
        null,
        &onJsFinished,
        null,
    );

    // Pump the loop until the async callback fires or we time out.
    const js_timeout_id = g_timeout_add(timeout_ms, &onWaitElapsed, null);
    g_main_loop_run(main_loop);
    if (js_done) _ = g_source_remove(js_timeout_id);

    if (!js_done) return webview.WebViewError.Timeout;
    if (js_error and js_result == null) return webview.WebViewError.JavaScriptError;
}

// ---------------------------------------------------------------------------
// Public API (matches src/platform/macos.zig)
// ---------------------------------------------------------------------------

pub fn render(allocator: std.mem.Allocator, url: []const u8, wait_ms: u32, timeout_ms: u32) webview.WebViewError!webview.RenderResult {
    const web_view = try setup(url, timeout_ms, wait_ms, 1280, 720);
    defer teardown();

    try evalJS(web_view, "document.documentElement.outerHTML", timeout_ms);

    const html_c = js_result orelse return webview.WebViewError.JavaScriptError;
    defer {
        std.heap.c_allocator.free(html_c);
        js_result = null;
    }
    const html = allocator.dupe(u8, html_c) catch return webview.WebViewError.OutOfMemory;
    return .{ .html = html };
}

pub fn eval(allocator: std.mem.Allocator, url: []const u8, js: []const u8, wait_ms: u32, timeout_ms: u32) webview.WebViewError!webview.EvalResult {
    const web_view = try setup(url, timeout_ms, wait_ms, 1280, 720);
    defer teardown();

    try evalJS(web_view, js, timeout_ms);

    const output_c = js_result orelse return webview.WebViewError.JavaScriptError;
    defer {
        std.heap.c_allocator.free(output_c);
        js_result = null;
    }
    const output = allocator.dupe(u8, output_c) catch return webview.WebViewError.OutOfMemory;
    return .{ .output = output };
}

// --- Not yet ported to Linux -----------------------------------------------
// screenshot -> webkit_web_view_snapshot() + GdkTexture/cairo PNG encode (GTK),
//               or a WPEView buffer grab (WPE)
// pdf        -> webkit_print_operation_new() with a PDF print setting (GTK)
// archive    -> no WebKit GLib equivalent to .webarchive; likely macOS-only.

pub fn screenshot(allocator: std.mem.Allocator, url: []const u8, wait_ms: u32, timeout_ms: u32, width: u32, height: u32, eval_js: ?[]const u8) webview.WebViewError!webview.ScreenshotResult {
    _ = allocator;
    _ = url;
    _ = wait_ms;
    _ = timeout_ms;
    _ = width;
    _ = height;
    _ = eval_js;
    return webview.WebViewError.ScreenshotFailed;
}

pub fn archive(allocator: std.mem.Allocator, url: []const u8, wait_ms: u32, timeout_ms: u32, eval_js: ?[]const u8) webview.WebViewError!webview.ArchiveResult {
    _ = allocator;
    _ = url;
    _ = wait_ms;
    _ = timeout_ms;
    _ = eval_js;
    return webview.WebViewError.ArchiveFailed;
}

pub fn pdf(allocator: std.mem.Allocator, url: []const u8, wait_ms: u32, timeout_ms: u32, eval_js: ?[]const u8) webview.WebViewError!webview.PdfResult {
    _ = allocator;
    _ = url;
    _ = wait_ms;
    _ = timeout_ms;
    _ = eval_js;
    return webview.WebViewError.PdfFailed;
}

fn teardown() void {
    if (main_loop) |loop| {
        g_main_loop_unref(loop);
        main_loop = null;
    }
    // A single-shot CLI intentionally leaks the view/display/window rather than
    // tearing down the toolkit, which keeps run-loop bookkeeping simple.
}
