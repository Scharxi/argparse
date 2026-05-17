# argparse

**Argparse comfort, Zig performance.**

If you have ever shipped a Python CLI, you probably reached for the standard library’s [`argparse`](https://docs.python.org/3/library/argparse.html)—`add_argument`, sensible `--help`, positionals in order, defaults when flags are omitted. This package brings that workflow to Zig: declare arguments at compile time, parse `argv`, and read typed results without hand-rolling token loops.

Requires **Zig 0.16** or newer.

## Why this feels familiar

| Python `argparse` | This library |
| ------------------- | -------------- |
| `ArgumentParser(prog=...)` | `ArgumentParser.init(allocator, "myapp", description, epilog, usage)` |
| `add_argument("--count", type=int, default=1)` | `addArgument(i32, .{ .name = "count", .default = 1 })` |
| `add_argument("input", help="...")` | `addArgument([]const u8, .{ .name = "input", .style = .positional, ... })` |
| `parser.parse_args()` | `parse` / `parseProcess` → `ParsedValues` |
| `-h` / `--help` | `error.HelpRequested` → `printHelpToStdout` |

The big difference: types are real. `addArgument(i32, …)` means you get an `i32` back, not a string you still have to parse yourself.

## Add it to your project

```bash
zig fetch --save git+https://github.com/Scharxi/argparse#v0.1.0
```

Then in `build.zig`:

```zig
const argparse = b.dependency("argparse", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("argparse", argparse.module("argparse"));
```

Use `@import("argparse")` in your source.

For a local path while hacking:

```zig
.dependencies = .{
    .argparse = .{ .path = "../argparse" },
},
```

## Five-minute CLI

```zig
const std = @import("std");
const argparse = @import("argparse");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    var parser = argparse.ArgumentParser.init(
        allocator,
        "myapp",
        "Process files with style.",
        null, // epilog (optional footer in --help)
        null, // custom usage line (optional)
    );
    defer parser.deinit();

    try parser.addArgument([]const u8, .{
        .name = "input",
        .style = .positional,
        .required = true,
        .help = "file to read",
    });
    try parser.addArgument(i32, .{
        .name = "count",
        .default = 1,
        .help = "how many times to run",
    });
    try parser.addArgument(bool, .{
        .name = "verbose",
        .short = 'v',
        .help = "extra logging",
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

    std.debug.print("{s} × {} (verbose={})\n", .{ input, count, verbose });
}
```

Run it:

```bash
zig build run -- input.txt --count 3 -v
zig build run -- -h
```

Help output looks like what Python users expect:

```txt
usage: myapp INPUT [--count COUNT] [-v] [-h]

Process files with style.

positional arguments:
  INPUT  file to read

options:
  -h, --help     show this help message and exit
  --count COUNT  how many times to run (default: 1)
  -v, --verbose  extra logging (default: false)
```

## Defining arguments

Each `addArgument(T, spec)` call registers one argument. The type `T` is the value type after parsing.

| Field | Meaning |
| ------- | --------- |
| `name` | Key for `get` / `require` (and default long flag name) |
| `long` | Long flag without dashes (`"verbose"` → `--verbose`); defaults to `name` |
| `short` | Single character for `-v` (optional flags only) |
| `help` | Text in `--help` |
| `default` | Value when not provided |
| `required` | Must appear on the command line |
| `style` | `.optional` (flag) or `.positional` |

**Supported types:** `bool`, `i32`, `u32`, `i64`, `f64`, `[]const u8`, and enums (parsed by tag name).

**Bool flags** work like `store_true` in Python: `--verbose` or `-v` sets the value to `true`. Omitted bools default to `false`. They do not consume the next argv token.

**Positionals** are filled in registration order. Register them with `.style = .positional`.

```zig
const Color = enum { red, green, blue };
try parser.addArgument(Color, .{ .name = "color", .default = .green });
// myapp --color green
```

## Reading parsed values

After a successful `parse` or `parseProcess`, use `ParsedValues`:

```zig
const n = try values.require(i32, "count");       // error if missing or wrong type
const maybe = values.get(i32, "count");           // null if missing or wrong type
const v = values.getOr(bool, "verbose", false);   // fallback when missing
```

Wrong-type access is safe: `get(u32, "count")` returns `null` if `count` was registered as `i32`.

String values are copied into memory owned by `ParsedValues`; free them only via `values.deinit()`.

## Help and errors

`-h` and `--help` anywhere in `argv` make parsing return `error.HelpRequested`. Handle it and print help:

```zig
var values = parser.parse(argv) catch |err| switch (err) {
    error.HelpRequested => {
        // write help to any std.Io.Writer, or:
        try parser.printHelpToStdout(io);
        return;
    },
    else => return err,
};
```

Common parse errors:

| Error | Typical cause |
| ------- | ---------------- |
| `UnknownArgument` | Unknown flag or too many positionals |
| `MissingValue` | Option needs a value but argv ended |
| `MissingRequiredArgument` | Required flag or positional not provided |
| `InvalidValue` | Bad integer, float, or enum tag |
| `DuplicateOption` | Two arguments share the same `long` or `short` |

## A few honest limits

This is not a full clone of Python’s `argparse`—yet. Notably:

- No combined short flags (`-abc`); use `-a -b -c`.
- Short options are exactly one character: `-v`, not `-verbose`.
- No subcommands module; one parser per invocation.
- Help uses a fixed buffer for stdout output; extremely long help text may truncate.

For most small-to-medium CLIs, that is a fair trade for compile-time checking and zero Python runtime.

## Develop & test

```bash
zig build test
zig build run -- --help
```

API docs live in source comments; open any public type in your editor or run `zig build-lib -femit-docs` on the package root module.

---

*Inspired by Python’s argparse. Built for Zig’s compile-time types.*
