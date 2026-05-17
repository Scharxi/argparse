//! Orchestrates argv scanning, default application, and help output.
//!
//! `ArgumentParser` stores type-erased arguments (`any_argument.AnyArgument`)
//! built at compile time from `Argument(T)` specs. See `any_argument.zig` for
//! how heterogeneous types are unified at runtime.

const std = @import("std");
const arg_type = @import("arg_type.zig");
const argument = @import("argument.zig");
const any_argument = @import("any_argument.zig");
const help = @import("help.zig");
const values = @import("values.zig");

/// Returned when any `argv` token is `-h` or `--help`.
///
/// Help detection runs before argument parsing and is not configurable.
pub const HelpRequested = error{HelpRequested};

/// Errors from parsing the command line or registering arguments.
pub const ParseError = arg_type.ParseError || HelpRequested || error{
    /// Flag or positional name was not registered.
    UnknownArgument,
    /// A non-bool option was present but the next argv token is missing.
    MissingValue,
    /// A `required` argument was not seen on the command line.
    MissingRequiredArgument,
    /// Two arguments share the same `long` or `short` name.
    DuplicateOption,
    OutOfMemory,
    Unexpected,
};

pub const Argument = argument.Argument;
pub const ArgStyle = argument.ArgStyle;
pub const ParsedValues = values.ParsedValues;

/// Command-line parser with argparse-style help and typed results.
///
/// Register arguments with `addArgument`, then `parse` or `parseProcess`.
/// Bool options (`--verbose`, `-v`) do not consume a following token; their
/// presence sets the value to `true`. Other options read the next argv token.
/// Non-flag tokens fill positionals in registration order.
pub const ArgumentParser = struct {
    allocator: std.mem.Allocator,
    /// Program name shown in the usage line.
    prog: []const u8,
    /// Text printed after the usage line in help output.
    description: ?[]const u8,
    /// Text printed after the options section in help output.
    epilog: ?[]const u8,
    /// If set, replaces the auto-generated usage line entirely.
    usage: ?[]const u8,
    args: std.ArrayList(any_argument.AnyArgument),

    /// Creates an empty parser. Call `deinit` when done.
    pub fn init(
        allocator: std.mem.Allocator,
        prog: []const u8,
        description: ?[]const u8,
        epilog: ?[]const u8,
        usage: ?[]const u8,
    ) ArgumentParser {
        return .{
            .allocator = allocator,
            .prog = prog,
            .description = description,
            .epilog = epilog,
            .usage = usage,
            .args = .empty,
        };
    }

    /// Frees the argument list. Does not free `prog`, `description`, or other
    /// string slices passed to `init` (caller owns those).
    pub fn deinit(self: *ArgumentParser) void {
        self.args.deinit(self.allocator);
    }

    /// Registers an argument of type `T` with compile-time validation.
    ///
    /// Returns `error.DuplicateOption` if `long` or `short` collides with an
    /// existing argument. Invalid specs (e.g. bool positional) are compile errors.
    pub fn addArgument(
        self: *ArgumentParser,
        comptime T: type,
        comptime spec: argument.Argument(T),
    ) !void {
        comptime argument.validateArgument(T, spec);

        const positional_index: ?usize = if (spec.style == .positional) blk: {
            var count: usize = 0;
            for (self.args.items) |a| {
                if (a.style == .positional) count += 1;
            }
            break :blk count;
        } else null;

        const any_arg = any_argument.AnyArgument.from(T, spec, positional_index);
        try self.validateNoDuplicate(&any_arg);
        try self.args.append(self.allocator, any_arg);
    }

    fn validateNoDuplicate(self: *const ArgumentParser, new_arg: *const any_argument.AnyArgument) !void {
        for (self.args.items) |existing| {
            if (std.mem.eql(u8, existing.long, new_arg.long)) {
                return error.DuplicateOption;
            }
            if (existing.short) |s| {
                if (new_arg.short == s) return error.DuplicateOption;
            }
        }
    }

    /// Parses `argv` (typically without the program name).
    ///
    /// Applies defaults for non-required arguments before scanning tokens.
    /// Returns `HelpRequested` if any token is `-h` or `--help`.
    pub fn parse(self: *ArgumentParser, argv: []const [:0]const u8) ParseError!values.ParsedValues {
        for (argv) |token| {
            if (isHelpToken(token)) return error.HelpRequested;
        }

        for (self.args.items) |*arg| {
            arg.seen = false;
        }

        var parsed = values.ParsedValues.init(self.allocator);
        errdefer parsed.deinit();

        for (self.args.items) |*arg| {
            try arg.applyDefault(&parsed);
        }

        var positional_cursor: usize = 0;
        var i: usize = 0;
        while (i < argv.len) : (i += 1) {
            const token = argv[i];

            if (std.mem.startsWith(u8, token, "--")) {
                const long_name = token[2..];
                const idx = self.findByLong(long_name) orelse return error.UnknownArgument;
                try self.parseOptional(idx, &parsed, argv, &i);
                continue;
            }

            if (std.mem.startsWith(u8, token, "-")) {
                if (token.len != 2) return error.UnknownArgument;
                const short_char = token[1];
                const idx = self.findByShort(short_char) orelse return error.UnknownArgument;
                try self.parseOptional(idx, &parsed, argv, &i);
                continue;
            }

            const idx = self.findPositional(positional_cursor) orelse return error.UnknownArgument;
            positional_cursor += 1;
            try self.parsePositional(idx, token, &parsed);
        }

        for (self.args.items) |arg| {
            if (arg.required and !arg.seen) {
                return error.MissingRequiredArgument;
            }
        }

        return parsed;
    }

    fn parseOptional(
        self: *ArgumentParser,
        idx: usize,
        parsed: *values.ParsedValues,
        argv: []const [:0]const u8,
        i: *usize,
    ) ParseError!void {
        const arg = &self.args.items[idx];
        if (arg.style != .optional) return error.UnknownArgument;

        arg.seen = true;

        if (arg.kind == .bool) {
            try arg.parseBoolFlag(parsed);
            return;
        }

        if (i.* + 1 >= argv.len) return error.MissingValue;
        i.* += 1;
        try arg.parseValue(self.allocator, argv[i.*], parsed);
    }

    fn parsePositional(
        self: *ArgumentParser,
        idx: usize,
        token: []const u8,
        parsed: *values.ParsedValues,
    ) ParseError!void {
        const arg = &self.args.items[idx];
        arg.seen = true;
        try arg.parseValue(self.allocator, token, parsed);
    }

    /// Parses process arguments using the arena from `process_init`.
    ///
    /// Skips `argv[0]` (the executable path). Equivalent to `parse` on the
    /// remaining slice.
    pub fn parseProcess(self: *ArgumentParser, process_init: std.process.Init) ParseError!values.ParsedValues {
        const all_args = try process_init.minimal.args.toSlice(process_init.arena.allocator());
        const args = if (all_args.len > 0) all_args[1..] else all_args;
        return self.parse(args);
    }

    fn findByLong(self: *const ArgumentParser, long_name: []const u8) ?usize {
        for (self.args.items, 0..) |arg, idx| {
            if (arg.style == .optional and std.mem.eql(u8, arg.long, long_name)) {
                return idx;
            }
        }
        return null;
    }

    fn findByShort(self: *const ArgumentParser, short_char: u8) ?usize {
        for (self.args.items, 0..) |arg, idx| {
            if (arg.short) |s| {
                if (s == short_char) return idx;
            }
        }
        return null;
    }

    fn findPositional(self: *const ArgumentParser, index: usize) ?usize {
        for (self.args.items, 0..) |arg, idx| {
            if (arg.style == .positional and arg.positional_index == index) {
                return idx;
            }
        }
        return null;
    }

    /// Writes usage, description, positionals, options, and epilog to `writer`.
    pub fn printHelp(self: *const ArgumentParser, writer: *std.Io.Writer) !void {
        try help.printUsage(self.prog, self.usage, self.args.items, writer);

        if (self.description) |description| {
            try writer.print("\n{s}\n", .{description});
        }

        try writer.print("\n", .{});
        try help.printPositionals(self.args.items, writer);

        var has_positionals = false;
        for (self.args.items) |arg| {
            if (arg.style == .positional) {
                has_positionals = true;
                break;
            }
        }
        if (has_positionals) try writer.print("\n", .{});

        try help.printOptions(self.args.items, writer);

        if (self.epilog) |epilog| {
            try writer.print("\n{s}\n", .{epilog});
        }
    }

    /// Formats help into a fixed 4 KiB buffer, then writes it to stdout.
    ///
    /// Very long help text may be truncated to fit the buffer.
    pub fn printHelpToStdout(self: *const ArgumentParser, io: std.Io) !void {
        var buffer: [4096]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try self.printHelp(&writer);
        try std.Io.File.stdout().writeStreamingAll(io, writer.buffered());
    }
};

fn isHelpToken(token: []const u8) bool {
    return std.mem.eql(u8, token, "-h") or std.mem.eql(u8, token, "--help");
}

test "parse i32 argument" {
    var parser = ArgumentParser.init(std.testing.allocator, "myapp", null, null, null);
    defer parser.deinit();

    try parser.addArgument(i32, .{
        .name = "count",
        .default = 1,
        .help = "iterations",
    });

    const argv = [_][:0]const u8{ "--count", "42" };
    var parsed = try parser.parse(&argv);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i32, 42), parsed.get(i32, "count").?);
}

test "parse applies default" {
    var parser = ArgumentParser.init(std.testing.allocator, "myapp", null, null, null);
    defer parser.deinit();

    try parser.addArgument(i32, .{
        .name = "count",
        .default = 7,
    });

    const argv = [_][:0]const u8{};
    var parsed = try parser.parse(&argv);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i32, 7), parsed.get(i32, "count").?);
}

test "parse bool flag" {
    var parser = ArgumentParser.init(std.testing.allocator, "myapp", null, null, null);
    defer parser.deinit();

    try parser.addArgument(bool, .{ .name = "verbose", .help = "log more" });

    const argv = [_][:0]const u8{"--verbose"};
    var parsed = try parser.parse(&argv);
    defer parsed.deinit();

    try std.testing.expect(parsed.get(bool, "verbose").?);
}

test "parse short bool flag" {
    var parser = ArgumentParser.init(std.testing.allocator, "myapp", null, null, null);
    defer parser.deinit();

    try parser.addArgument(bool, .{
        .name = "verbose",
        .long = "verbose",
        .short = 'v',
    });

    const argv = [_][:0]const u8{"-v"};
    var parsed = try parser.parse(&argv);
    defer parsed.deinit();

    try std.testing.expect(parsed.get(bool, "verbose").?);
}

test "parse positional" {
    var parser = ArgumentParser.init(std.testing.allocator, "myapp", null, null, null);
    defer parser.deinit();

    try parser.addArgument([]const u8, .{
        .name = "input",
        .style = .positional,
        .required = true,
        .help = "input file",
    });

    const argv = [_][:0]const u8{"input.txt"};
    var parsed = try parser.parse(&argv);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("input.txt", parsed.get([]const u8, "input").?);
}

test "parse required positional missing" {
    var parser = ArgumentParser.init(std.testing.allocator, "myapp", null, null, null);
    defer parser.deinit();

    try parser.addArgument([]const u8, .{
        .name = "input",
        .style = .positional,
        .required = true,
    });

    const argv = [_][:0]const u8{};
    try std.testing.expectError(error.MissingRequiredArgument, parser.parse(&argv));
}

test "parse required optional missing" {
    var parser = ArgumentParser.init(std.testing.allocator, "myapp", null, null, null);
    defer parser.deinit();

    try parser.addArgument(i32, .{
        .name = "count",
        .required = true,
    });

    const argv = [_][:0]const u8{};
    try std.testing.expectError(error.MissingRequiredArgument, parser.parse(&argv));
}

test "parse extra positional" {
    var parser = ArgumentParser.init(std.testing.allocator, "myapp", null, null, null);
    defer parser.deinit();

    try parser.addArgument([]const u8, .{
        .name = "input",
        .style = .positional,
        .required = true,
    });

    const argv = [_][:0]const u8{ "a.txt", "b.txt" };
    try std.testing.expectError(error.UnknownArgument, parser.parse(&argv));
}

test "parse invalid value" {
    var parser = ArgumentParser.init(std.testing.allocator, "myapp", null, null, null);
    defer parser.deinit();

    try parser.addArgument(i32, .{ .name = "count", .default = 1 });

    const argv = [_][:0]const u8{ "--count", "nope" };
    try std.testing.expectError(error.InvalidValue, parser.parse(&argv));
}

test "parse enum argument" {
    const Color = enum { red, green, blue };

    var parser = ArgumentParser.init(std.testing.allocator, "myapp", null, null, null);
    defer parser.deinit();

    try parser.addArgument(Color, .{
        .name = "color",
        .default = .blue,
    });

    const argv = [_][:0]const u8{ "--color", "green" };
    var parsed = try parser.parse(&argv);
    defer parsed.deinit();

    try std.testing.expectEqual(Color.green, parsed.get(Color, "color").?);
}

test "parse -h requests help" {
    var parser = ArgumentParser.init(std.testing.allocator, "myapp", null, null, null);
    defer parser.deinit();

    const argv = [_][:0]const u8{"-h"};
    try std.testing.expectError(error.HelpRequested, parser.parse(&argv));
}

test "parse --help requests help" {
    var parser = ArgumentParser.init(std.testing.allocator, "myapp", null, null, null);
    defer parser.deinit();

    const argv = [_][:0]const u8{"--help"};
    try std.testing.expectError(error.HelpRequested, parser.parse(&argv));
}

test "printHelp output" {
    var parser = ArgumentParser.init(
        std.testing.allocator,
        "myapp",
        "This is a test program",
        "Hello World",
        null,
    );
    defer parser.deinit();

    try parser.addArgument(i32, .{ .name = "count", .default = 1, .help = "iterations" });
    try parser.addArgument(bool, .{
        .name = "verbose",
        .long = "verbose",
        .short = 'v',
        .help = "log more",
    });
    try parser.addArgument([]const u8, .{
        .name = "input",
        .style = .positional,
        .required = true,
        .help = "input file",
    });

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try parser.printHelp(&writer);
    const output = writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, output, "usage: myapp INPUT") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "[-h]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "positional arguments:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "INPUT") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "-v, --verbose") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "--count COUNT") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "iterations") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "(default: 1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Hello World") != null);
}

test "get wrong type returns null" {
    var parser = ArgumentParser.init(std.testing.allocator, "myapp", null, null, null);
    defer parser.deinit();

    try parser.addArgument(i32, .{ .name = "count", .default = 1 });

    const argv = [_][:0]const u8{};
    var parsed = try parser.parse(&argv);
    defer parsed.deinit();

    try std.testing.expect(parsed.get(u32, "count") == null);
}
