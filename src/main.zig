const std = @import("std");

const argparse = @import("argparse");
const ArgumentParser = argparse.ArgumentParser;

pub fn main(init: std.process.Init) !void {
    var parser = ArgumentParser.init(init.arena.allocator(), "myapp", "This is a test program", "Hello World", null);
    defer parser.deinit();

    try parser.addArgument([]const u8, .{
        .name = "input",
        .style = .positional,
        .required = true,
        .help = "input file",
    });
    try parser.addArgument(i32, .{ .name = "count", .default = 1, .help = "iterations" });
    try parser.addArgument(bool, .{
        .name = "verbose",
        .long = "verbose",
        .short = 'v',
        .help = "log more",
    });

    var values = parser.parseProcess(init) catch |err| switch (err) {
        error.HelpRequested => {
            try parser.printHelpToStdout(init.io);
            return;
        },
        else => return err,
    };
    defer values.deinit();

    const input = try values.require([]const u8, "input");
    const count = try values.require(i32, "count");
    const verbose = values.getOr(bool, "verbose", false);

    std.debug.print("input: {s}\n", .{input});
    std.debug.print("count: {}\n", .{count});
    std.debug.print("verbose: {}\n", .{verbose});
}
