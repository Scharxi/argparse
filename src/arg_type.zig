//! Compile-time argument type metadata and text parsing.
//!
//! Each supported `T` gets an `ArgType(T)` namespace with `Kind`, `type_name`,
//! and `parse`. The parser uses these at compile time; `type_name` is stored in
//! `ParsedValues` for runtime type checks.

const std = @import("std");

/// Errors from parsing a single token as a given type.
pub const ParseError = error{
    InvalidValue,
    UnsupportedType,
};

/// Discriminant for supported argument types (matches `values.Value`).
pub const ArgKind = enum {
    bool,
    i32,
    u32,
    i64,
    f64,
    string,
    @"enum",
};

/// Returns whether `T` can be passed to `Argument(T)` and `addArgument`.
pub fn isSupported(comptime T: type) bool {
    return T == bool or
        T == i32 or
        T == u32 or
        T == i64 or
        T == f64 or
        T == []const u8 or
        @typeInfo(T) == .@"enum";
}

fn kindOf(comptime T: type) ArgKind {
    if (T == bool) return .bool;
    if (T == i32) return .i32;
    if (T == u32) return .u32;
    if (T == i64) return .i64;
    if (T == f64) return .f64;
    if (T == []const u8) return .string;
    if (@typeInfo(T) == .@"enum") return .@"enum";
    @compileError("unsupported argument type: " ++ @typeName(T));
}

/// Compile-time facade for one argument type: kind, name, and parsers.
pub fn ArgType(comptime T: type) type {
    const kind = kindOf(T);

    return struct {
        pub const Kind = kind;
        /// Stored in `ParsedValues` entries for `get` / `require` checks.
        pub const type_name = @typeName(T);

        /// Parses `text` into `T`.
        ///
        /// For `bool`, always returns `true` if reached (bool **flags** on the
        /// command line use `AnyArgument.parseBoolFlag` instead and do not call
        /// this with a separate value token). Enums use tag names via
        /// `std.meta.stringToEnum` (case-sensitive).
        pub fn parse(allocator: std.mem.Allocator, text: []const u8) ParseError!T {
            _ = allocator;
            return switch (kind) {
                .bool => true,
                .i32 => std.fmt.parseInt(i32, text, 10) catch return error.InvalidValue,
                .u32 => std.fmt.parseInt(u32, text, 10) catch return error.InvalidValue,
                .i64 => std.fmt.parseInt(i64, text, 10) catch return error.InvalidValue,
                .f64 => std.fmt.parseFloat(f64, text) catch return error.InvalidValue,
                .string => text,
                .@"enum" => std.meta.stringToEnum(T, text) orelse return error.InvalidValue,
            };
        }

        pub fn formatDefault(writer: anytype, value: T) !void {
            switch (kind) {
                .bool => try writer.print("{}", .{value}),
                .i32, .u32, .i64 => try writer.print("{}", .{value}),
                .f64 => try writer.print("{d}", .{value}),
                .string => try writer.print("{s}", .{value}),
                .@"enum" => try writer.print("{s}", .{@tagName(value)}),
            }
        }
    };
}

test "ArgType i32 parse" {
    const T = ArgType(i32);
    try std.testing.expectEqual(@as(i32, 42), try T.parse(std.testing.allocator, "42"));
    try std.testing.expectError(error.InvalidValue, T.parse(std.testing.allocator, "nope"));
}

test "ArgType enum parse" {
    const Color = enum { red, green, blue };
    const T = ArgType(Color);
    try std.testing.expectEqual(Color.green, try T.parse(std.testing.allocator, "green"));
}
