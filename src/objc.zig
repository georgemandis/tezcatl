// Objective-C runtime bindings for Zig.
// Provides type-safe wrappers around objc_msgSend, NSString, NSData, NSArray.
// Includes class creation helpers for dynamic delegate registration.

const std = @import("std");

// ---------------------------------------------------------------------------
// Part 1: Core Obj-C runtime types and extern functions
// ---------------------------------------------------------------------------

pub const Class = *opaque {};
pub const SEL = *opaque {};
pub const id = *opaque {};
pub const NSUInteger = usize;
pub const NSInteger = isize;

extern "objc" fn objc_getClass(name: [*:0]const u8) ?Class;
extern "objc" fn sel_registerName(name: [*:0]const u8) SEL;
extern "objc" fn objc_msgSend() void;

// Class creation (for dynamic delegate registration)
extern "objc" fn objc_allocateClassPair(superclass: ?Class, name: [*:0]const u8, extra_bytes: usize) ?Class;
extern "objc" fn objc_registerClassPair(cls: Class) void;
extern "objc" fn class_addMethod(cls: Class, name: SEL, imp: *const anyopaque, types: [*:0]const u8) bool;

/// Look up an Objective-C class by name. Returns null if not found.
pub fn getClass(name: [*:0]const u8) ?Class {
    return objc_getClass(name);
}

/// Register/look up a selector by name.
pub fn sel(name: [*:0]const u8) SEL {
    return sel_registerName(name);
}

/// Cast objc_msgSend to a typed function pointer.
pub fn msgSendFn(comptime ReturnType: type, comptime ArgTypes: type) MsgSendFnType(ReturnType, ArgTypes) {
    return @ptrCast(&objc_msgSend);
}

fn MsgSendFnType(comptime ReturnType: type, comptime ArgTypes: type) type {
    const args_info = @typeInfo(ArgTypes);
    const fields = args_info.@"struct".fields;

    return switch (fields.len) {
        0 => *const fn (id, SEL) callconv(.c) ReturnType,
        1 => *const fn (id, SEL, fields[0].type) callconv(.c) ReturnType,
        2 => *const fn (id, SEL, fields[0].type, fields[1].type) callconv(.c) ReturnType,
        3 => *const fn (id, SEL, fields[0].type, fields[1].type, fields[2].type) callconv(.c) ReturnType,
        4 => *const fn (id, SEL, fields[0].type, fields[1].type, fields[2].type, fields[3].type) callconv(.c) ReturnType,
        else => @compileError("msgSendFn: too many arguments, add more cases"),
    };
}

/// Send a message to an Objective-C object.
pub fn msgSend(comptime ReturnType: type, target: anytype, selector: SEL, args: anytype) ReturnType {
    const target_as_id: id = @ptrCast(target);
    const ArgsType = @TypeOf(args);
    const func = msgSendFn(ReturnType, ArgsType);

    const args_info = @typeInfo(ArgsType);
    const fields = args_info.@"struct".fields;

    return switch (fields.len) {
        0 => func(target_as_id, selector),
        1 => func(target_as_id, selector, args[0]),
        2 => func(target_as_id, selector, args[0], args[1]),
        3 => func(target_as_id, selector, args[0], args[1], args[2]),
        4 => func(target_as_id, selector, args[0], args[1], args[2], args[3]),
        else => @compileError("msgSend: too many arguments"),
    };
}

/// Allocate a new Objective-C class pair.
pub fn allocateClassPair(superclass: ?Class, name: [*:0]const u8) ?Class {
    return objc_allocateClassPair(superclass, name, 0);
}

/// Register a class pair previously created with allocateClassPair.
pub fn registerClassPair(cls: Class) void {
    objc_registerClassPair(cls);
}

/// Add a method to a class. Must be called before registerClassPair.
pub fn addMethod(cls: Class, name: SEL, imp: *const anyopaque, types: [*:0]const u8) bool {
    return class_addMethod(cls, name, imp, types);
}

// ---------------------------------------------------------------------------
// Part 2: NSString bridging helpers
// ---------------------------------------------------------------------------

/// Create an NSString from a null-terminated C string. Autoreleased.
pub fn nsString(str: [*:0]const u8) id {
    const NSString = getClass("NSString") orelse unreachable;
    return msgSend(id, NSString, sel("stringWithUTF8String:"), .{str});
}

/// Create an NSString from a Zig byte slice (non-null-terminated). Autoreleased.
pub fn nsStringFromSlice(bytes: [*]const u8, len: NSUInteger) ?id {
    const NSString = getClass("NSString") orelse return null;
    const alloc_str = msgSend(id, NSString, sel("alloc"), .{});
    return msgSend(?id, alloc_str, sel("initWithBytes:length:encoding:"), .{
        bytes,
        len,
        @as(NSUInteger, 4), // NSUTF8StringEncoding
    });
}

/// Read a UTF-8 C string from an NSString.
pub fn fromNSString(nsstr: id) ?[*:0]const u8 {
    return msgSend(?[*:0]const u8, nsstr, sel("UTF8String"), .{});
}

/// Get the length of an NSString (number of UTF-16 code units).
pub fn nsStringLength(nsstr: id) NSUInteger {
    return msgSend(NSUInteger, nsstr, sel("length"), .{});
}

// ---------------------------------------------------------------------------
// Part 3: NSArray helpers
// ---------------------------------------------------------------------------

/// Get the count of an NSArray.
pub fn nsArrayCount(nsarray: id) NSUInteger {
    return msgSend(NSUInteger, nsarray, sel("count"), .{});
}

/// Get an object from an NSArray at a given index.
pub fn nsArrayObjectAtIndex(nsarray: id, index: NSUInteger) id {
    return msgSend(id, nsarray, sel("objectAtIndex:"), .{index});
}

// ---------------------------------------------------------------------------
// Part 4: NSRange helper
// ---------------------------------------------------------------------------

pub const NSRange = extern struct {
    location: NSUInteger,
    length: NSUInteger,
};

// ---------------------------------------------------------------------------
// Part 5: CGRect helper
// ---------------------------------------------------------------------------

pub const CGFloat = f64;

pub const CGPoint = extern struct {
    x: CGFloat,
    y: CGFloat,
};

pub const CGSize = extern struct {
    width: CGFloat,
    height: CGFloat,
};

pub const CGRect = extern struct {
    origin: CGPoint,
    size: CGSize,
};

// ---------------------------------------------------------------------------
// Part 6: Autorelease pool
// ---------------------------------------------------------------------------

/// Create a new autorelease pool.
pub fn autoreleasePoolPush() id {
    const NSAutoreleasePool = getClass("NSAutoreleasePool") orelse unreachable;
    const pool = msgSend(id, NSAutoreleasePool, sel("alloc"), .{});
    return msgSend(id, pool, sel("init"), .{});
}

/// Drain an autorelease pool.
pub fn autoreleasePoolPop(pool: id) void {
    msgSend(void, pool, sel("drain"), .{});
}
