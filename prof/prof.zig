const std = @import("std");
const makeOp_mod = @import("makeOp");

const makeOp = makeOp_mod.makeOp;

const ProfErrors = error{
    DetectedInvalidState,
    FmtParseError,
};

pub var log_writer: ?*std.Io.Writer = null;
pub var rng: std.Random.DefaultPrng = undefined;
pub var step_idx: u64 = 0;

fn callFn(
    comptime returns_err: bool,
    comptime returns_val: bool,
    comptime fmt: []const u8,
    comptime func: anytype,
    comptime ErrorUnion: type,
    args: anytype,
) ErrorUnion!void {
    const fn_info = @typeInfo(@TypeOf(func)).@"fn";
    const ReturnType = if (fn_info.return_type) |rt| rt else void;

    var r = std.io.Reader.fixed(fmt);
    const fn_name = r.takeDelimiterExclusive(' ') catch return error.FmtParseError;

    logPrint("#{}: {s}(", .{ step_idx, fn_name });

    const args_info = @typeInfo(@TypeOf(args));
    if (args_info.@"struct".fields.len > 1) {
        inline for (args_info.@"struct".fields[1..], 0..) |field, i| {
            if (i > 0) logPrint(", ", .{});

            _ = r.discardDelimiterExclusive('{') catch return error.FmtParseError;
            const arg_fmt = r.takeDelimiterInclusive('}') catch return error.FmtParseError;

            if (field.type == std.mem.Allocator) {
                logPrint("allocator", .{});
            } else {
                const v = @field(args, field.name);
                try logFmtArg(arg_fmt, v);
            }
        }
    }

    logPrint(")", .{});

    if (returns_err) {
        const ret = @call(.auto, func, args) catch |err| {
            logPrint(" = {}\n", .{err});
            return err;
        };

        if (ReturnType != void) {
            _ = r.discardDelimiterInclusive('!') catch return error.FmtParseError;

            const remaining = r.peek(1) catch &[_]u8{};
            if (remaining.len > 0 and remaining[0] == '{') {
                _ = r.discardDelimiterExclusive('{') catch return error.FmtParseError;
                const ret_fmt = r.takeDelimiterInclusive('}') catch return error.FmtParseError;
                logPrint(" = ", .{});
                try logFmtArg(ret_fmt, ret);
            }
        }

        logPrint("\n", .{});
    } else if (returns_val) {
        const ret = @call(.auto, func, args);

        _ = r.discardDelimiterInclusive('>') catch return error.FmtParseError;
        _ = r.discardDelimiterExclusive('{') catch return error.FmtParseError;
        const ret_fmt = r.takeDelimiterInclusive('}') catch return error.FmtParseError;

        logPrint(" = ", .{});
        try logFmtArg(ret_fmt, ret);
        logPrint("\n", .{});
    } else {
        @call(.auto, func, args);
        logPrint("\n", .{});
    }
}

fn logFmtArg(fmt_slice: []const u8, value: anytype) ProfErrors!void {
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

pub fn logPrint(comptime fmt: []const u8, args: anytype) void {
    if (log_writer) |w| {
        w.print(fmt, args) catch |err| {
            std.debug.panic("log writer failed: {}\n", .{err});
        };
    }
}

pub fn Profiler(comptime DStruct: type, comptime ops_cfg: anytype) type {
    const ds_info = @typeInfo(DStruct);
    if (ds_info != .@"struct") std.debug.panic(
        "Expected struct type. Invalid type: {s}\n",
        .{@typeName(DStruct)},
    );

    const fns_info = @typeInfo(@TypeOf(ops_cfg));
    if (fns_info != .@"struct") std.debug.panic(
        "Expected struct type. Invalid type: {s}\n",
        .{@typeName(@TypeOf(ops_cfg))},
    );
    const fn_count = fns_info.@"struct".fields.len;

    comptime var ErrorUnion = ProfErrors;
    inline for (ops_cfg) |op_cfg| {
        const func = op_cfg.func;
        const fn_info = @typeInfo(@TypeOf(func)).@"fn";
        if (fn_info.return_type) |rt| {
            const rt_info = @typeInfo(rt);
            switch (rt_info) {
                .error_union => {
                    const ErrorSet = rt_info.error_union.error_set;
                    ErrorUnion = ErrorUnion || ErrorSet;
                },
                else => {},
            }
        }
    }

    const ops_table = blk: {
        const FnPtr = @TypeOf(makeOp(DStruct, ops_cfg[0], ErrorUnion, callFn));
        var array: [fn_count]FnPtr = undefined;

        inline for (ops_cfg, 0..) |op_cfg, i| {
            array[i] = makeOp(DStruct, op_cfg, ErrorUnion, callFn);
        }

        break :blk array;
    };

    return struct {
        const ops = ops_table;

        ds: *DStruct,
        validate: *const fn (*DStruct) bool,

        pub fn init(
            comptime validate: *const fn (*DStruct) bool,
            ds: *DStruct,
            seed: u64,
        ) @This() {
            rng = std.Random.DefaultPrng.init(seed);
            return .{
                .ds = ds,
                .validate = validate,
            };
        }

        pub fn step(self: *@This()) ErrorUnion!void {
            const rand = rng.random();
            const idx = rand.intRangeLessThan(usize, 0, ops.len);
            step_idx += 1;
            try ops[idx](self.ds, rand);
            if (!self.validate(self.ds)) return error.DetectedInvalidState;
        }
    };
}

pub fn setLogWriter(writer: *std.Io.Writer) void {
    log_writer = writer;
}
