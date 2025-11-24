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

const HWReadErrors = error{
    ShortRead,
    BadEventCount,
} || std.posix.ReadError;

const HWCounter = enum(u64) {
    cycles = @intFromEnum(std.os.linux.PERF.COUNT.HW.CPU_CYCLES),
    instructions = @intFromEnum(std.os.linux.PERF.COUNT.HW.INSTRUCTIONS),
    cache_misses = @intFromEnum(std.os.linux.PERF.COUNT.HW.CACHE_MISSES),
    branch_misses = @intFromEnum(std.os.linux.PERF.COUNT.HW.BRANCH_MISSES),
};

const Snapshot = struct {
    values: [NUM_COUNTERS]u64,
};

const NUM_COUNTERS = @typeInfo(HWCounter).@"enum".fields.len;
const PERF_FORMAT_GROUP: u64 = 1 << 3;

pub var rng: std.Random.DefaultPrng = undefined;
pub var step_idx: u64 = 0;

var counter_fds: [NUM_COUNTERS]std.os.linux.fd_t = undefined;

fn callFn(
    comptime fmt: []const u8,
    comptime func: anytype,
    comptime ErrorUnion: type,
    args: anytype,
) ErrorUnion!void {
    const fn_info = @typeInfo(@TypeOf(func)).@"fn";
    const returns_val = comptime fn_info.return_type != null;
    const returns_err = comptime blk: {
        if (fn_info.return_type) |rt| {
            break :blk @typeInfo(rt) == .error_union;
        } else break :blk false;
    };

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

    var snap_before: Snapshot = undefined;
    var snap_after: Snapshot = undefined;

    if (returns_err) {
        snap_before = try snapshot();
        const ret = @call(.auto, func, args) catch |err| {
            snap_after = try snapshot();
            logPrint(" = {}", .{err});

            const diff = diffSnapshots(snap_before, snap_after);
            logPrint(" PERF cycles={} instructions={} cache-misses={} branch-misses={}\n", .{
                diff.values[0],
                diff.values[1],
                diff.values[2],
                diff.values[3],
            });
            return err;
        };
        snap_after = try snapshot();

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
    } else if (returns_val) {
        snap_before = try snapshot();
        const ret = @call(.auto, func, args);
        snap_after = try snapshot();

        _ = r.discardDelimiterInclusive('>') catch return error.FmtParseError;
        _ = r.discardDelimiterExclusive('{') catch return error.FmtParseError;
        const ret_fmt = r.takeDelimiterInclusive('}') catch return error.FmtParseError;

        logPrint(" = ", .{});
        try logFmtArg(ret_fmt, ret);
    } else {
        snap_before = try snapshot();
        @call(.auto, func, args);
        snap_after = try snapshot();
    }

    const diff = diffSnapshots(snap_before, snap_after);
    logPrint(" PERF cycles={} instructions={} cache-misses={} branch-misses={}\n", .{
        diff.values[0],
        diff.values[1],
        diff.values[2],
        diff.values[3],
    });
}

fn openPerfEvent(
    maybe_group_fd: ?std.os.linux.fd_t,
    counter: HWCounter,
) !std.posix.fd_t {
    var attr: std.os.linux.perf_event_attr = .{
        .type = std.os.linux.PERF.TYPE.HARDWARE,
        .config = @intFromEnum(counter),
        .sample_period_or_freq = 0,
        .sample_type = 0,
        .read_format = PERF_FORMAT_GROUP,
        .flags = .{
            .disabled = false,
            .inherit = false,
            .exclude_user = false,
            .exclude_kernel = true,
            .exclude_hv = true,
        },
    };

    const pid: std.posix.pid_t = 0;
    const cpu: i32 = -1;
    const group_fd: std.posix.fd_t = maybe_group_fd orelse -1;
    const flags: usize = 0;

    return try std.posix.perf_event_open(&attr, pid, cpu, group_fd, flags);
}

fn snapshot() HWReadErrors!Snapshot {
    var raw: [1 + NUM_COUNTERS]u64 = undefined;

    const bytes = std.mem.asBytes(&raw);
    const n = try std.posix.read(counter_fds[0], bytes);
    if (n != bytes.len) return error.ShortRead;

    const nr = raw[0];
    if (nr != NUM_COUNTERS) return error.BadEventCount;

    return .{ .values = raw[1..].* };
}

fn diffSnapshots(before: Snapshot, after: Snapshot) Snapshot {
    var out: Snapshot = undefined;
    for (0..NUM_COUNTERS) |i| {
        out.values[i] = after.values[i] - before.values[i];
    }
    return out;
}

pub fn Profiler(comptime DStruct: type, comptime ops_cfg: anytype) type {
    validateOpsCfg(DStruct, ops_cfg);
    const ErrorUnion = CollectErrorUnion(ops_cfg, ProfErrors || FmtErrors || HWReadErrors);
    const ops_table = makeOpsTable(DStruct, ops_cfg, ErrorUnion, callFn);
    return struct {
        const ops = ops_table;

        ds: *DStruct,

        pub fn init(
            ds: *DStruct,
            seed: u64,
            writer: *std.Io.Writer,
        ) !@This() {
            setLogWriter(writer);
            rng = std.Random.DefaultPrng.init(seed);

            counter_fds[0] = try openPerfEvent(null, .cycles);
            inline for (@typeInfo(HWCounter).@"enum".fields[1..], 1..) |field, i| {
                counter_fds[i] = try openPerfEvent(counter_fds[0], @enumFromInt(field.value));
            }

            return .{ .ds = ds };
        }

        pub fn deinit(self: *@This()) void {
            _ = self;
            for (counter_fds) |fd| {
                std.posix.close(fd);
            }
        }

        pub fn step(self: *@This()) ErrorUnion!void {
            const rand = rng.random();
            const idx = rand.intRangeLessThan(usize, 0, ops.len);
            step_idx += 1;
            try ops[idx](self.ds, rand);
        }
    };
}
