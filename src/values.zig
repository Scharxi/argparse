//! Runtime storage for parsed argument values.

const std = @import("std");
const arg_type = @import("arg_type.zig");

/// Type-erased stored value. Used internally when applying defaults.
pub const Value = union(arg_type.ArgKind) {
    bool: bool,
    i32: i32,
    u32: u32,
    i64: i64,
    f64: f64,
    string: []const u8,
    @"enum": i64,
};

const Entry = struct {
    type_name: []const u8,
    value: Value,
};

/// Errors from `ParsedValues.require`.
pub const AccessError = error{
    /// No value was stored under `name`.
    MissingArgument,
    /// A value exists but `T` does not match the registered argument type.
    TypeMismatch,
};

/// Map of argument names to parsed values.
///
/// Values are tagged with `@typeName(T)` at insert time. Use `get` with the
/// same `T` you passed to `addArgument`; a mismatched type returns `null` from
/// `get` or `error.TypeMismatch` from `require`.
///
/// `[]const u8` values are duplicated into memory owned by this struct and
/// freed in `deinit`. Do not free slices returned from `get` / `require`.
pub const ParsedValues = struct {
    allocator: std.mem.Allocator,
    entries: std.StringArrayHashMapUnmanaged(Entry),
    owned_strings: std.ArrayListUnmanaged([]const u8),

    pub fn init(allocator: std.mem.Allocator) ParsedValues {
        return .{
            .allocator = allocator,
            .entries = .empty,
            .owned_strings = .empty,
        };
    }

    /// Frees all entries and duplicated string storage.
    pub fn deinit(self: *ParsedValues) void {
        for (self.owned_strings.items) |owned| {
            self.allocator.free(owned);
        }
        self.owned_strings.deinit(self.allocator);
        self.entries.deinit(self.allocator);
    }

    /// Stores a value using an explicit type name (internal / default path).
    pub fn setValue(self: *ParsedValues, name: []const u8, type_name: []const u8, value: Value) !void {
        const stored: Value = switch (value) {
            .string => |s| blk: {
                const duped = try self.allocator.dupe(u8, s);
                try self.owned_strings.append(self.allocator, duped);
                break :blk .{ .string = duped };
            },
            else => value,
        };
        try self.entries.put(self.allocator, name, .{
            .type_name = type_name,
            .value = stored,
        });
    }

    /// Inserts or replaces `name` with `value`, tagged as type `T`.
    pub fn set(self: *ParsedValues, name: []const u8, comptime T: type, value: T) !void {
        const AT = arg_type.ArgType(T);
        const stored = try valueToStored(self, value);
        try self.entries.put(self.allocator, name, .{
            .type_name = AT.type_name,
            .value = stored,
        });
    }

    /// Returns the value if present and `T` matches, otherwise `null`.
    ///
    /// Wrong `T` (e.g. `get(u32, "count")` when `count` is `i32`) returns `null`,
    /// not an error.
    pub fn get(self: *const ParsedValues, comptime T: type, name: []const u8) ?T {
        const AT = arg_type.ArgType(T);
        const entry = self.entries.get(name) orelse return null;
        if (!std.mem.eql(u8, entry.type_name, AT.type_name)) return null;
        return storedToValue(T, entry.value);
    }

    /// Returns the value or `error.MissingArgument` / `error.TypeMismatch`.
    pub fn require(self: *const ParsedValues, comptime T: type, name: []const u8) AccessError!T {
        const AT = arg_type.ArgType(T);
        const entry = self.entries.get(name) orelse return error.MissingArgument;
        if (!std.mem.eql(u8, entry.type_name, AT.type_name)) return error.TypeMismatch;
        return storedToValue(T, entry.value) orelse return error.TypeMismatch;
    }

    /// Returns the stored value, or `default` if the name is missing.
    ///
    /// Unlike `get`, a type mismatch still returns `default` (the name is
    /// treated as missing for the requested `T`).
    pub fn getOr(self: *const ParsedValues, comptime T: type, name: []const u8, default: T) T {
        return self.get(T, name) orelse default;
    }

    fn valueToStored(self: *ParsedValues, value: anytype) !Value {
        const T = @TypeOf(value);
        const AT = arg_type.ArgType(T);
        return switch (AT.Kind) {
            .bool => .{ .bool = value },
            .i32 => .{ .i32 = value },
            .u32 => .{ .u32 = value },
            .i64 => .{ .i64 = value },
            .f64 => .{ .f64 = value },
            .string => blk: {
                const duped = try self.allocator.dupe(u8, value);
                try self.owned_strings.append(self.allocator, duped);
                break :blk .{ .string = duped };
            },
            .@"enum" => .{ .@"enum" = @intFromEnum(value) },
        };
    }

    fn storedToValue(comptime T: type, stored: Value) ?T {
        const AT = arg_type.ArgType(T);
        return switch (AT.Kind) {
            .bool => if (stored == .bool) stored.bool else null,
            .i32 => if (stored == .i32) stored.i32 else null,
            .u32 => if (stored == .u32) stored.u32 else null,
            .i64 => if (stored == .i64) stored.i64 else null,
            .f64 => if (stored == .f64) stored.f64 else null,
            .string => if (stored == .string) stored.string else null,
            .@"enum" => if (stored == .@"enum") @enumFromInt(stored.@"enum") else null,
        };
    }
};

test "ParsedValues get type mismatch" {
    var values = ParsedValues.init(std.testing.allocator);
    defer values.deinit();

    try values.set("count", i32, 10);
    try std.testing.expectEqual(@as(?i32, 10), values.get(i32, "count"));
    try std.testing.expect(values.get(u32, "count") == null);
}

test "ParsedValues require" {
    var values = ParsedValues.init(std.testing.allocator);
    defer values.deinit();

    try values.set("count", i32, 10);
    try std.testing.expectEqual(@as(i32, 10), try values.require(i32, "count"));
    try std.testing.expectError(error.MissingArgument, values.require(i32, "missing"));
    try std.testing.expectError(error.TypeMismatch, values.require(u32, "count"));
}

test "ParsedValues getOr" {
    var values = ParsedValues.init(std.testing.allocator);
    defer values.deinit();

    try std.testing.expectEqual(@as(bool, false), values.getOr(bool, "verbose", false));
    try values.set("verbose", bool, true);
    try std.testing.expectEqual(@as(bool, true), values.getOr(bool, "verbose", false));
}
