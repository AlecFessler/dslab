const std = @import("std");

var log_writer: ?*std.Io.Writer = null;

pub const FmtErrors = error{
    FmtParseError,
};

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
