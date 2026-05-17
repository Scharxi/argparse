//! Compile-time argument specifications for `ArgumentParser.addArgument`.

const arg_type = @import("arg_type.zig");

/// How an argument is passed on the command line.
pub const ArgStyle = enum {
    /// Flag or value preceded by `-x` / `--name` (default).
    optional,
    /// Bare token, filled in registration order among positionals.
    positional,
};

/// Returns the struct type used to describe an argument of type `T`.
///
/// Unsupported `T` values are a compile error. Use `ArgumentParser.addArgument`
/// to register instances.
pub fn Argument(comptime T: type) type {
    comptime {
        if (!arg_type.isSupported(T)) {
            @compileError("unsupported argument type: " ++ @typeName(T));
        }
    }

    return struct {
        /// Key for `ParsedValues.get` / `require`.
        name: []const u8,
        /// Long flag without dashes (e.g. `"verbose"` → `--verbose`). Defaults to `name`.
        long: ?[]const u8 = null,
        /// Short flag character (e.g. `'v'` → `-v`). Ignored for positionals.
        short: ?u8 = null,
        /// Help text shown in `--help`.
        help: ?[]const u8 = null,
        /// Default used when the argument is not provided. Incompatible with
        /// `required = true` for non-bool types (compile error).
        default: ?T = null,
        /// Must appear on the command line (or, for bool flags, must be passed
        /// explicitly to be `true`; there is no implicit default when required).
        required: bool = false,
        /// Optional flag vs positional argument. Defaults to `.optional`.
        style: ArgStyle = .optional,
    };
}

/// Compile-time checks for `spec`. Violations are `@compileError`.
///
/// - Positionals cannot have `short` or type `bool`.
/// - `required` and `default` cannot both be set unless `T` is `bool`.
pub fn validateArgument(comptime T: type, spec: Argument(T)) void {
    comptime {
        if (spec.style == .positional) {
            if (spec.short != null) {
                @compileError("positional arguments cannot have a short option");
            }
            if (T == bool) {
                @compileError("positional arguments cannot be bool");
            }
        }
        if (spec.required and spec.default != null and T != bool) {
            @compileError("required arguments cannot have a default value");
        }
    }
}

/// Resolves the long option name: `spec.long` or `spec.name`.
pub fn resolveLong(spec: anytype) []const u8 {
    return spec.long orelse spec.name;
}
