const std = @import("std");
const shared = @import("shared");

const makeOp = shared.makeOp.makeOp;
const makeOpsTable = shared.makeOp.makeOpsTable;
const logPrint = shared.log.logPrint;
const logFmtArg = shared.log.logFmtArg;
const setLogWriter = shared.log.setLogWriter;
const validateOpsCfg = shared.makeOp.validateOpsCfg;

const CollectErrorUnion = shared.makeOp.CollectErrorUnion;

const FmtErrors = shared.log.FmtErrors;
const ProfErrors = error{};

pub var rng: std.Random.DefaultPrng = undefined;
pub var step_idx: u64 = 0;

// need a function to initialize perf counters, called in profiler init
// need a function to reset hardware counters
// need a function to snapshot hardware counters
// need a function to return diff of two hardware counters snapshots
// need a function to log hardware counters snapshot diff

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

pub fn Profiler(comptime DStruct: type, comptime ops_cfg: anytype) type {
    validateOpsCfg(DStruct, ops_cfg);
    const ErrorUnion = CollectErrorUnion(ops_cfg, ProfErrors || FmtErrors);
    const ops_table = makeOpsTable(DStruct, ops_cfg, ErrorUnion, callFn);
    return struct {
        const ops = ops_table;

        ds: *DStruct,

        pub fn init(
            ds: *DStruct,
            seed: u64,
            writer: *std.Io.Writer,
        ) @This() {
            setLogWriter(writer);
            rng = std.Random.DefaultPrng.init(seed);
            return .{ .ds = ds };
        }

        pub fn step(self: *@This()) ErrorUnion!void {
            const rand = rng.random();
            const idx = rand.intRangeLessThan(usize, 0, ops.len);
            step_idx += 1;
            try ops[idx](self.ds, rand);
        }
    };
}
