//! Typed command-line argument parser for Zig 0.16+.
//!
//! This package provides `ArgumentParser` for declaring flags and positionals at
//! compile time, parsing `argv`, and reading results from `ParsedValues`.
//!
//! ## Quick start
//!
//! ```zig
//! const argparse = @import("argparse");
//!
//! var parser = argparse.ArgumentParser.init(allocator, "myapp", "Does things.", null, null);
//! defer parser.deinit();
//!
//! try parser.addArgument([]const u8, .{
//!     .name = "input",
//!     .style = .positional,
//!     .required = true,
//! });
//! try parser.addArgument(i32, .{ .name = "count", .default = 1 });
//! try parser.addArgument(bool, .{ .name = "verbose", .short = 'v' });
//!
//! var values = try parser.parse(argv);
//! defer values.deinit();
//!
//! const input = try values.require([]const u8, "input");
//! const count = try values.require(i32, "count");
//! const verbose = values.getOr(bool, "verbose", false);
//! ```
//!
//! With `std.process.Init`, use `parseProcess` and handle help explicitly:
//!
//! ```zig
//! var values = parser.parseProcess(init) catch |err| switch (err) {
//!     error.HelpRequested => {
//!         try parser.printHelpToStdout(init.io);
//!         return;
//!     },
//!     else => return err,
//! };
//! defer values.deinit();
//! ```
//!
//! ## Supported types
//!
//! `bool`, `i32`, `u32`, `i64`, `f64`, `[]const u8`, and enums.
//!
//! ## Help
//!
//! Any `-h` or `--help` token in `argv` makes `parse` / `parseProcess` return
//! `error.HelpRequested`. Format help with `printHelp` or `printHelpToStdout`.
//!
//! ## Limitations
//!
//! - Short options must be exactly one character (`-v`), not combined (`-abc`).
//! - Tokens starting with `-` that are not `--long` or single-char `-x` are rejected.
//! - Positionals are filled in the order arguments were registered.
//! - Extra positional tokens or unknown flags return `error.UnknownArgument`.
//!
//! ## Public API
//!
//! Re-exported types and functions below are the supported entry points.
const arg_type = @import("arg_type.zig");
const argument = @import("argument.zig");
const values = @import("values.zig");
const parser = @import("parser.zig");

/// Compile-time argument specification; see `ArgumentParser.addArgument`.
pub const Argument = argument.Argument;
/// Main parser: register arguments, parse `argv`, print help.
pub const ArgumentParser = parser.ArgumentParser;
/// Parsed argument values keyed by name.
pub const ParsedValues = parser.ParsedValues;
/// Errors returned by `ArgumentParser.parse` and `parseProcess`.
pub const ParseError = parser.ParseError;
/// Returned when `argv` contains `-h` or `--help`.
pub const HelpRequested = parser.HelpRequested;
/// Errors returned by `ParsedValues.require`.
pub const AccessError = values.AccessError;
/// Discriminant for stored value kinds (used by the internal `Value` union).
pub const ArgKind = arg_type.ArgKind;
/// Whether an argument is an optional flag or a positional value.
pub const ArgStyle = argument.ArgStyle;
