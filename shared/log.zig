const std = @import("std");

var log_writer: ?*std.Io.Writer = null;

pub const FmtErrors = error{
    FmtParseError,
};

pub const ParsedFmt = struct {
    fn_name: []const u8,
    arg_fmt: []const u8,
    ret_fmt: ?[]const u8,
};

pub fn parseFmt(comptime fmt: []const u8) ParsedFmt {
    const space = std.mem.indexOfScalar(u8, fmt, ' ') orelse @compileError("fmt must contain a space after the function name");
    const arrow = std.mem.indexOf(u8, fmt, "->") orelse @compileError("fmt must contain '->' after the argument format list");

    const fn_name = fmt[0..space];
    const arg_fmt = fmt[space + 1 .. arrow];

    const brace_start = std.mem.indexOfScalarPos(u8, fmt, arrow, '{') orelse {
        return .{
            .fn_name = fn_name,
            .arg_fmt = arg_fmt,
            .ret_fmt = null,
        };
    };

    const brace_end = std.mem.indexOfScalarPos(u8, fmt, brace_start + 1, '}') orelse @compileError("Missing '}' in return value format specifier");

    const ret_fmt = fmt[brace_start .. brace_end + 1];

    return .{
        .fn_name = fn_name,
        .arg_fmt = arg_fmt,
        .ret_fmt = ret_fmt,
    };
}

pub fn setLogWriter(writer: *std.Io.Writer) void {
    log_writer = writer;
}

pub fn logPrint(comptime fmt: []const u8, args: anytype) void {
    if (log_writer) |w| {
        w.print(fmt, args) catch |err| {
            std.debug.panic("log writer failed: {}\n", .{err});
        };
    }
}

pub fn logFmtArg(fmt_slice: []const u8, value: anytype) FmtErrors!void {
    const T = @TypeOf(value);
    if (@typeInfo(T) == .void) return;

    if (!std.mem.startsWith(u8, fmt_slice, "{") or
        !std.mem.endsWith(u8, fmt_slice, "}"))
        return error.FmtParseError;

    const inner = fmt_slice[1 .. fmt_slice.len - 1];

    if (std.mem.eql(u8, inner, "")) {
        logPrint("{}", .{value});
        return;
    }

    if (std.mem.eql(u8, inner, "x")) {
        switch (@typeInfo(T)) {
            .int => {
                logPrint("{x}", .{value});
                return;
            },
            else => return error.FmtParseError,
        }
    }

    if (std.mem.eql(u8, inner, "s")) {
        switch (@typeInfo(T)) {
            .pointer, .array => {
                logPrint("{s}", .{value});
                return;
            },
            else => return error.FmtParseError,
        }
    }

    return error.FmtParseError;
}
