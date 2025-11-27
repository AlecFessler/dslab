const std = @import("std");
const shared = @import("shared");

const makeOp = shared.makeOp.makeOp;
const makeOpsTable = shared.makeOp.makeOpsTable;
const makePriorityTable = shared.makeOp.makePriorityTable;
const logPrint = shared.log.logPrint;
const logFmtArg = shared.log.logFmtArg;
const setLogWriter = shared.log.setLogWriter;
const validateOpsCfg = shared.makeOp.validateOpsCfg;

const CollectErrorUnion = shared.makeOp.CollectErrorUnion;

const FmtErrors = shared.log.FmtErrors;
const FuzzErrors = error{
    DetectedInvalidState,
};

pub fn Fuzzer(comptime DStruct: type, comptime ops_cfg: anytype) type {
    validateOpsCfg(DStruct, ops_cfg);
    return struct {
        const Self = @This();
        const ErrorUnion = CollectErrorUnion(FuzzErrors || FmtErrors, ops_cfg);
        const ops_table = makeOpsTable(Self, ErrorUnion, ops_cfg);
        const priority_table = makePriorityTable(ops_cfg);

        const ops = ops_table;
        const priorities = priority_table;

        ds: *DStruct,
        rng: std.Random.DefaultPrng = undefined,
        step_idx: u64 = 0,
        validate: *const fn (*DStruct) bool,

        pub fn init(
            comptime validate: *const fn (*DStruct) bool,
            ds: *DStruct,
            seed: u64,
            w: *std.Io.Writer,
        ) Self {
            setLogWriter(w);
            return .{
                .ds = ds,
                .rng = std.Random.DefaultPrng.init(seed),
                .step_idx = 0,
                .validate = validate,
            };
        }

        pub fn callFn(
            self: *Self,
            comptime fmt: []const u8,
            comptime func: anytype,
            args: anytype,
        ) ErrorUnion!void {
            const fn_info = @typeInfo(@TypeOf(func)).@"fn";
            const returns_val = comptime fn_info.return_type != null;
            const returns_err = comptime blk: {
                if (fn_info.return_type) |rt| {
                    break :blk @typeInfo(rt) == .error_union;
                } else break :blk false;
            };

            const space = comptime std.mem.indexOfScalar(u8, fmt, ' ') orelse std.debug.panic("Fmt string must have a space following the name");
            const arrow = comptime std.mem.indexOf(u8, fmt, "->") orelse fmt.len;
            const arg_fmt = comptime fmt[space + 1 .. arrow];

            var r = std.io.Reader.fixed(fmt);
            const fn_name = r.takeDelimiterExclusive(' ') catch return error.FmtParseError;

            logPrint("#{}: {s}(", .{ self.step_idx, fn_name });
            logPrint(arg_fmt, args);
            logPrint(")", .{});

            if (returns_err) {
                const ret = @call(.auto, func, args) catch |err| {
                    logPrint(" = {}\n", .{err});
                    return err;
                };

                if (returns_val) {
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
            if (!self.validate(self.ds)) return error.DetectedInvalidState;
        }

        pub fn step(self: *Self) ErrorUnion!void {
            self.step_idx += 1;
            const rand = self.rng.random();
            const idx = blk: {
                const u = rand.float(f32);
                var acc: f32 = 0.0;

                for (priorities, 0..) |p, i| {
                    acc += p;
                    if (u < acc) break :blk i;
                }

                break :blk priorities.len - 1;
            };
            try ops[idx](self);
        }
    };
}
