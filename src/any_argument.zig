//! Type-erased runtime representation of registered arguments.
//!
//! `ArgumentParser` must store many different `Argument(T)` types in one list.
//! `AnyArgument` homogenizes them:
//!
//! - Metadata (`name`, `long`, `kind`, etc.) is copied into a plain struct.
//! - Parsing is delegated through `parseInto`, a function pointer to a
//!   comptime-generated wrapper (`makeParseInto`) that calls `ArgType(T).parse`
//!   and `ParsedValues.set`.
//!
//! ## Positional order
//!
//! When `from` is called for a positional spec, `positional_index` is the count
//! of positionals already registered. The parser fills positionals by increasing
//! index as it sees non-flag argv tokens.
//!
//! ## Defaults and help
//!
//! `has_default` is true for optional arguments with an explicit `default`, or
//! for optional bools (implicit default `false`). That flag drives both
//! `applyDefault` and the `(default: …)` suffix in help output.
//!
//! `applyDefault` skips `required` arguments. Bool without `spec.default` stores
//! `false`. Enum defaults are stored in `Value.@"enum"` via `@intFromEnum`.

const std = @import("std");
const arg_type = @import("arg_type.zig");
const argument = @import("argument.zig");
const values = @import("values.zig");

pub const AnyArgument = struct {
    name: []const u8,
    long: []const u8,
    short: ?u8,
    help: ?[]const u8,
    kind: arg_type.ArgKind,
    type_name: []const u8,
    required: bool,
    style: argument.ArgStyle,
    positional_index: ?usize,
    has_default: bool,
    default: ?values.Value,
    seen: bool,
    parseInto: *const fn (
        std.mem.Allocator,
        []const u8,
        []const u8,
        *values.ParsedValues,
    ) error{ InvalidValue, OutOfMemory }!void,

    pub fn from(
        comptime T: type,
        spec: argument.Argument(T),
        positional_index: ?usize,
    ) AnyArgument {
        const AT = arg_type.ArgType(T);
        const default_value: ?values.Value = if (spec.default) |d| defaultToValue(T, d) else null;
        const long_name = argument.resolveLong(spec);

        return .{
            .name = spec.name,
            .long = long_name,
            .short = if (spec.style == .optional) spec.short else null,
            .help = spec.help,
            .kind = AT.Kind,
            .type_name = AT.type_name,
            .required = spec.required,
            .style = spec.style,
            .positional_index = positional_index,
            .has_default = !spec.required and (spec.default != null or AT.Kind == .bool),
            .default = default_value,
            .seen = false,
            .parseInto = makeParseInto(T),
        };
    }

    /// Inserts default values for optional arguments before argv is scanned.
    pub fn applyDefault(self: AnyArgument, parsed: *values.ParsedValues) !void {
        if (self.required) return;

        if (self.default) |default_value| {
            try parsed.setValue(self.name, self.type_name, default_value);
            return;
        }
        if (self.kind == .bool) {
            try parsed.set(self.name, bool, false);
        }
    }

    pub fn formatDefault(self: AnyArgument, writer: *std.Io.Writer) !void {
        if (self.default) |default_value| {
            switch (default_value) {
                .bool => |v| try writer.print("{}", .{v}),
                .i32 => |v| try writer.print("{}", .{v}),
                .u32 => |v| try writer.print("{}", .{v}),
                .i64 => |v| try writer.print("{}", .{v}),
                .f64 => |v| try writer.print("{d}", .{v}),
                .string => |v| try writer.print("{s}", .{v}),
                .@"enum" => |v| try writer.print("{}", .{v}),
            }
            return;
        }
        if (self.kind == .bool) {
            try writer.print("{}", .{false});
        }
    }

    /// Sets a bool optional to `true` when the flag is present (no value token).
    pub fn parseBoolFlag(self: AnyArgument, parsed: *values.ParsedValues) !void {
        if (self.kind != .bool) return;
        try parsed.set(self.name, bool, true);
    }

    pub fn parseValue(
        self: AnyArgument,
        allocator: std.mem.Allocator,
        text: []const u8,
        parsed: *values.ParsedValues,
    ) error{ InvalidValue, OutOfMemory }!void {
        return self.parseInto(allocator, text, self.name, parsed);
    }
};

fn defaultToValue(comptime T: type, value: T) values.Value {
    const AT = arg_type.ArgType(T);
    return switch (AT.Kind) {
        .bool => .{ .bool = value },
        .i32 => .{ .i32 = value },
        .u32 => .{ .u32 = value },
        .i64 => .{ .i64 = value },
        .f64 => .{ .f64 = value },
        .string => .{ .string = value },
        .@"enum" => .{ .@"enum" = @intFromEnum(value) },
    };
}

fn makeParseInto(comptime T: type) *const fn (
    std.mem.Allocator,
    []const u8,
    []const u8,
    *values.ParsedValues,
) error{ InvalidValue, OutOfMemory }!void {
    const AT = arg_type.ArgType(T);
    return struct {
        fn parseInto(
            allocator: std.mem.Allocator,
            text: []const u8,
            name: []const u8,
            parsed: *values.ParsedValues,
        ) error{ InvalidValue, OutOfMemory }!void {
            const parsed_value = AT.parse(allocator, text) catch return error.InvalidValue;
            try parsed.set(name, T, parsed_value);
        }
    }.parseInto;
}
