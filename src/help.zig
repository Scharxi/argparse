//! Argparse-style help text formatting.
//!
//! Builds a usage line, a positionals section, and an options section with
//! column-aligned spec strings. Metavars are the argument `name` uppercased
//! (e.g. `count` → `COUNT`). A built-in `-h, --help` row is always included in
//! the options section.

const std = @import("std");
const any_argument = @import("any_argument.zig");

pub const builtin_help_spec = "-h, --help";
pub const builtin_help_text = "show this help message and exit";

/// Uppercases `name` into `buf` and returns the slice written.
pub fn formatMetavar(name: []const u8, buf: []u8) ![]const u8 {
    if (buf.len < name.len) return error.NoSpaceLeft;
    for (name, 0..) |c, i| {
        buf[i] = std.ascii.toUpper(c);
    }
    return buf[0..name.len];
}

pub fn formatOptionSpec(arg: any_argument.AnyArgument, buf: []u8) ![]const u8 {
    if (arg.style != .optional) return error.InvalidArgument;

    if (arg.kind == .bool) {
        if (arg.short) |s| {
            return std.fmt.bufPrint(buf, "-{c}, --{s}", .{ s, arg.long });
        }
        return std.fmt.bufPrint(buf, "--{s}", .{arg.long});
    }

    var metabuf: [64]u8 = undefined;
    const meta = try formatMetavar(arg.name, &metabuf);
    if (arg.short) |s| {
        return std.fmt.bufPrint(buf, "-{c}, --{s} {s}", .{ s, arg.long, meta });
    }
    return std.fmt.bufPrint(buf, "--{s} {s}", .{ arg.long, meta });
}

pub fn optionSpecLen(arg: any_argument.AnyArgument) usize {
    var buf: [128]u8 = undefined;
    const spec = formatOptionSpec(arg, &buf) catch return 0;
    return spec.len;
}

/// Writes `usage: …` — either `usage` verbatim or prog + positionals + options + `[-h]`.
pub fn printUsage(
    prog: []const u8,
    usage: ?[]const u8,
    args: []const any_argument.AnyArgument,
    writer: *std.Io.Writer,
) !void {
    if (usage) |custom| {
        try writer.print("usage: {s}\n", .{custom});
        return;
    }

    try writer.print("usage: {s}", .{prog});

    for (args) |arg| {
        if (arg.style != .positional) continue;
        var metabuf: [64]u8 = undefined;
        const meta = formatMetavar(arg.name, &metabuf) catch arg.name;
        if (arg.required) {
            try writer.print(" {s}", .{meta});
        } else {
            try writer.print(" [{s}]", .{meta});
        }
    }

    for (args) |arg| {
        if (arg.style != .optional) continue;
        var spec_buf: [128]u8 = undefined;
        const spec = formatUsageOptional(arg, &spec_buf) catch continue;
        try writer.print("{s}", .{spec});
    }

    try writer.print(" [-h]\n", .{});
}

fn formatUsageOptional(arg: any_argument.AnyArgument, buf: []u8) ![]const u8 {
    if (arg.kind == .bool) {
        if (arg.short) |s| {
            if (arg.required) return std.fmt.bufPrint(buf, " -{c}", .{s});
            return std.fmt.bufPrint(buf, " [-{c}]", .{s});
        }
        if (arg.required) return std.fmt.bufPrint(buf, " --{s}", .{arg.long});
        return std.fmt.bufPrint(buf, " [--{s}]", .{arg.long});
    }

    var metabuf: [64]u8 = undefined;
    const meta = try formatMetavar(arg.name, &metabuf);
    if (arg.short) |s| {
        if (arg.required) return std.fmt.bufPrint(buf, " -{c} {s}", .{ s, meta });
        return std.fmt.bufPrint(buf, " [-{c} {s}]", .{ s, meta });
    }
    if (arg.required) return std.fmt.bufPrint(buf, " --{s} {s}", .{ arg.long, meta });
    return std.fmt.bufPrint(buf, " [--{s} {s}]", .{ arg.long, meta });
}

/// Writes the `positional arguments:` block if any positionals exist.
pub fn printPositionals(
    args: []const any_argument.AnyArgument,
    writer: *std.Io.Writer,
) !void {
    var has_positionals = false;
    for (args) |arg| {
        if (arg.style == .positional) {
            has_positionals = true;
            break;
        }
    }
    if (!has_positionals) return;

    var max_meta: usize = 0;
    for (args) |arg| {
        if (arg.style != .positional) continue;
        max_meta = @max(max_meta, arg.name.len);
    }

    try writer.print("positional arguments:\n", .{});
    for (args) |arg| {
        if (arg.style != .positional) continue;

        var metabuf: [64]u8 = undefined;
        const meta = formatMetavar(arg.name, &metabuf) catch arg.name;
        try writer.print("  {s}", .{meta});

        const padding = max_meta - meta.len;
        var i: usize = 0;
        while (i < padding) : (i += 1) {
            try writer.writeByte(' ');
        }
        try writer.writeAll("  ");

        if (arg.help) |help_text| {
            try writer.print("{s}", .{help_text});
        }
        try writer.writeByte('\n');
    }
}

/// Writes the `options:` block with aligned specs and optional `(default: …)`.
pub fn printOptions(
    args: []const any_argument.AnyArgument,
    writer: *std.Io.Writer,
) !void {
    var max_spec = builtin_help_spec.len;
    for (args) |arg| {
        if (arg.style != .optional) continue;
        max_spec = @max(max_spec, optionSpecLen(arg));
    }

    try writer.print("options:\n", .{});
    try printOptionRow(writer, max_spec, builtin_help_spec, builtin_help_text, null);
    for (args) |arg| {
        if (arg.style != .optional) continue;
        var spec_buf: [128]u8 = undefined;
        const spec = formatOptionSpec(arg, &spec_buf) catch continue;
        const help_text = arg.help orelse "";
        try printOptionRow(writer, max_spec, spec, help_text, arg);
    }
}

fn printOptionRow(
    writer: *std.Io.Writer,
    spec_width: usize,
    spec: []const u8,
    help_text: []const u8,
    arg: ?any_argument.AnyArgument,
) !void {
    try writer.print("  {s}", .{spec});

    const padding = spec_width - spec.len;
    var i: usize = 0;
    while (i < padding) : (i += 1) {
        try writer.writeByte(' ');
    }
    try writer.writeAll("  ");

    if (help_text.len > 0) {
        try writer.print("{s}", .{help_text});
    }

    if (arg) |a| {
        if (a.has_default) {
            try writer.print(" (default: ", .{});
            try a.formatDefault(writer);
            try writer.writeByte(')');
        }
    }

    try writer.writeByte('\n');
}
