const std = @import("std");

const FuzzErrors = error{
    DetectedInvalidState,
};

pub var log_writer: ?*std.Io.Writer = null;
pub var rng: std.Random.DefaultPrng = undefined;
pub var step_idx: u64 = 0;

fn callFn(
    comptime returns_err: bool,
    comptime returns_val: bool,
    comptime fn_name: []const u8,
    comptime args_fmt: ?[]const u8,
    comptime ret_fmt: ?[]const u8,
    comptime func: anytype,
    comptime ErrorUnion: type,
    args: anytype,
) ErrorUnion!void {
    const func_info = @typeInfo(@TypeOf(func)).@"fn";
    const ReturnType = if (func_info.return_type) |rt| rt else void;

    logPrint("#{}: {s}(", .{ step_idx, fn_name });
    if (args_fmt) |fmt| {
        const args_info = @typeInfo(@TypeOf(args));
        if (args_info.@"struct".fields.len > 1) {
            inline for (args_info.@"struct".fields[1..], 0..) |field, i| {
                if (i > 0) logPrint(", ", .{});
                const T = field.type;
                if (T == std.mem.Allocator) {
                    logPrint("allocator", .{});
                } else {
                    logPrint(fmt, .{@field(args, field.name)});
                }
            }
        }
    }
    logPrint(")", .{});

    if (returns_err) {
        const ret = @call(.auto, func, args) catch |err| {
            logPrint(" = {}\n", .{err});
            return err;
        };
        if (ReturnType != void and ret_fmt != null) {
            logPrint(" = ", .{});
            logPrint(ret_fmt.?, .{ret});
        }
        logPrint("\n", .{});
    } else if (returns_val) {
        const ret = @call(.auto, func, args);
        if (ret_fmt) |fmt| {
            logPrint(" = ", .{});
            logPrint(fmt, .{ret});
        }
        logPrint("\n", .{});
    } else {
        @call(.auto, func, args);
        logPrint("\n", .{});
    }
}

fn getCallback(
    comptime ParamType: anytype,
    comptime param_idx: u64,
    comptime op_cfg: anytype,
) ?*const fn (ParamType) void {
    const cfg_type = @TypeOf(op_cfg);
    if (!@hasField(cfg_type, "callbacks")) return null;
    const cb_info = @typeInfo(@TypeOf(op_cfg.callbacks)).@"struct";
    inline for (cb_info.fields) |field| {
        if (field.defaultValue()) |val| {
            if (val.param_idx != param_idx) continue;
            return val.callback;
        }
    }
    return null;
}

fn getGenerator(
    comptime ParamType: anytype,
    comptime param_idx: u64,
    comptime op_cfg: anytype,
) ?*const fn () ParamType {
    const cfg_type = @TypeOf(op_cfg);
    if (!@hasField(cfg_type, "generators")) return null;
    const gen_info = @typeInfo(@TypeOf(op_cfg.generators)).@"struct";
    inline for (gen_info.fields) |field| {
        if (field.defaultValue()) |val| {
            if (val.param_idx != param_idx) continue;
            return val.generator;
        }
    }
    return null;
}

fn genRandNum(comptime T: type, rand: std.Random) T {
    return switch (@typeInfo(T)) {
        .int => rand.int(T),
        .float => rand.float(T),
        else => std.debug.panic("genRandNum expects numerical input types. Invalid type {s}\n", .{@typeName(T)}),
    };
}

fn logPrint(comptime fmt: []const u8, args: anytype) void {
    if (log_writer) |w| {
        w.print(fmt, args) catch |err| {
            std.debug.panic("log writer failed: {}\n", .{err});
        };
    }
}

fn makeOp(
    comptime DStruct: type,
    comptime op_cfg: anytype,
    comptime ErrorUnion: type,
) *const fn (*DStruct, std.Random) ErrorUnion!void {
    const func = op_cfg.func;
    const fn_info = @typeInfo(@TypeOf(func)).@"fn";
    const fn_name = if (@hasField(@TypeOf(op_cfg), "name"))
        op_cfg.name
    else
        @typeName(@TypeOf(func));
    const args_fmt = if (@hasField(@TypeOf(op_cfg), "args_fmt")) op_cfg.args_fmt else null;
    const ret_fmt = if (@hasField(@TypeOf(op_cfg), "ret_fmt")) op_cfg.ret_fmt else null;

    if (fn_info.params.len > 5) std.debug.panic("Fuzzer currently only supports functions with up to 4 args", .{});

    inline for (fn_info.params, 0..) |param, i| {
        const T = param.type orelse std.debug.panic("Expected typed arg in func {s}", .{
            @typeName(@TypeOf(func)),
        });
        const t_info = @typeInfo(T);
        switch (t_info) {
            .pointer => {
                if (i != 0) std.debug.panic("Expected numerical arg type in func {s}. Invalid type: {s}\n", .{
                    @typeName(@TypeOf(func)),
                    @typeName(T),
                });
                if (T != *DStruct) std.debug.panic("Expected first arg of func {s} to be *{s}. Invald type: {s}\n", .{
                    @typeName(@TypeOf(func)),
                    @typeName(DStruct),
                    @typeName(T),
                });
            },
            .int, .float => {
                if (i == 0) std.debug.panic("Expected first arg of func {s} to be *{s}. Invald type: {s}\n", .{
                    @typeName(@TypeOf(func)),
                    @typeName(DStruct),
                    @typeName(T),
                });
            },
            else => {
                if (i == 0) {
                    std.debug.panic("Expected first arg of func {s} to be *{s}. Invalid type: {s}\n", .{
                        @typeName(@TypeOf(func)),
                        @typeName(DStruct),
                        @typeName(T),
                    });
                }
                if (getGenerator(T, i, op_cfg) == null) {
                    std.debug.panic("Unexpected arg type in func {s}. Invalid type: {s}. Provide a generator for this parameter.\n", .{
                        @typeName(@TypeOf(func)),
                        @typeName(T),
                    });
                }
            },
        }
    }

    const Op = struct {
        fn genParam(
            comptime param_idx: usize,
            rand: std.Random,
        ) fn_info.params[param_idx].type.? {
            const ParamType = fn_info.params[param_idx].type.?;
            const val = if (getGenerator(ParamType, param_idx, op_cfg)) |genInput|
                genInput()
            else
                genRandNum(ParamType, rand);
            if (getCallback(ParamType, param_idx, op_cfg)) |cb| cb(val);
            return val;
        }

        fn call(
            ds: *DStruct,
            rand: std.Random,
        ) ErrorUnion!void {
            const returns_val = comptime fn_info.return_type != null;
            const returns_err = comptime blk: {
                if (fn_info.return_type) |rt| {
                    break :blk @typeInfo(rt) == .error_union;
                } else break :blk false;
            };

            switch (fn_info.params.len) {
                1 => {
                    try callFn(
                        returns_err,
                        returns_val,
                        fn_name,
                        args_fmt,
                        ret_fmt,
                        func,
                        ErrorUnion,
                        .{ds},
                    );
                },
                2 => {
                    const a = genParam(1, rand);
                    try callFn(
                        returns_err,
                        returns_val,
                        fn_name,
                        args_fmt,
                        ret_fmt,
                        func,
                        ErrorUnion,
                        .{ ds, a },
                    );
                },
                3 => {
                    const a = genParam(1, rand);
                    const b = genParam(2, rand);
                    try callFn(
                        returns_err,
                        returns_val,
                        fn_name,
                        args_fmt,
                        ret_fmt,
                        func,
                        ErrorUnion,
                        .{ ds, a, b },
                    );
                },
                4 => {
                    const a = genParam(1, rand);
                    const b = genParam(2, rand);
                    const c = genParam(3, rand);
                    try callFn(
                        returns_err,
                        returns_val,
                        fn_name,
                        args_fmt,
                        ret_fmt,
                        func,
                        ErrorUnion,
                        .{ ds, a, b, c },
                    );
                },
                5 => {
                    const a = genParam(1, rand);
                    const b = genParam(2, rand);
                    const c = genParam(3, rand);
                    const d = genParam(4, rand);
                    try callFn(
                        returns_err,
                        returns_val,
                        fn_name,
                        args_fmt,
                        ret_fmt,
                        func,
                        ErrorUnion,
                        .{ ds, a, b, c, d },
                    );
                },
                else => std.debug.panic("Fuzzer currently only supports functions with up to 4 args", .{}),
            }
        }
    };

    return Op.call;
}

pub fn Fuzzer(comptime DStruct: type, comptime ops_cfg: anytype) type {
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

    comptime var ErrorUnion = FuzzErrors;
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
        const FnPtr = @TypeOf(makeOp(DStruct, ops_cfg[0], ErrorUnion));
        var array: [fn_count]FnPtr = undefined;

        inline for (ops_cfg, 0..) |op_cfg, i| {
            array[i] = makeOp(DStruct, op_cfg, ErrorUnion);
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
