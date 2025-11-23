const std = @import("std");

pub fn CollectErrorUnion(comptime ops_cfg: anytype, comptime BaseErrorSet: type) type {
    comptime var ErrorUnion = BaseErrorSet;
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

    return ErrorUnion;
}

fn OpsTableType(
    comptime DStruct: type,
    comptime ops_cfg: anytype,
    comptime ErrorUnion: type,
    comptime callFn: *const fn (
        comptime returns_err: bool,
        comptime returns_val: bool,
        comptime fmt: []const u8,
        comptime func: anytype,
        comptime ErrorUnion: type,
        args: anytype,
    ) ErrorUnion!void,
) type {
    const struct_info = @typeInfo(@TypeOf(ops_cfg)).@"struct";
    const FnPtr = @TypeOf(makeOp(DStruct, ops_cfg[0], ErrorUnion, callFn));
    return [struct_info.fields.len]FnPtr;
}

pub fn makeOpsTable(
    comptime DStruct: type,
    comptime ops_cfg: anytype,
    comptime ErrorUnion: type,
    comptime callFn: *const fn (
        comptime returns_err: bool,
        comptime returns_val: bool,
        comptime fmt: []const u8,
        comptime func: anytype,
        comptime ErrorUnion: type,
        args: anytype,
    ) ErrorUnion!void,
) OpsTableType(DStruct, ops_cfg, ErrorUnion, callFn) {
    var array: OpsTableType(DStruct, ops_cfg, ErrorUnion, callFn) = undefined;
    inline for (ops_cfg, 0..) |op_cfg, i| {
        array[i] = makeOp(DStruct, op_cfg, ErrorUnion, callFn);
    }
    return array;
}

pub fn makeOp(
    comptime DStruct: type,
    comptime op_cfg: anytype,
    comptime ErrorUnion: type,
    comptime callFn: *const fn (
        comptime returns_err: bool,
        comptime returns_val: bool,
        comptime fmt: []const u8,
        comptime func: anytype,
        comptime ErrorUnion: type,
        args: anytype,
    ) ErrorUnion!void,
) *const fn (*DStruct, std.Random) ErrorUnion!void {
    const fn_info = @typeInfo(@TypeOf(op_cfg.func)).@"fn";
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

            const args = blk: {
                const num_params = fn_info.params.len;
                if (num_params == 1) break :blk .{ds};

                const a = genParam(1, rand);
                if (num_params == 2) break :blk .{ ds, a };

                const b = genParam(2, rand);
                if (num_params == 3) break :blk .{ ds, a, b };

                const c = genParam(3, rand);
                if (num_params == 4) break :blk .{ ds, a, b, c };

                const d = genParam(4, rand);
                if (num_params == 5) break :blk .{ ds, a, b, c, d };
            };

            try callFn(
                returns_err,
                returns_val,
                op_cfg.fmt,
                op_cfg.func,
                ErrorUnion,
                args,
            );
        }
    };

    return Op.call;
}

pub fn validateOpsCfg(comptime DStruct: type, comptime ops_cfg: anytype) void {
    const ds_info = @typeInfo(DStruct);
    if (ds_info != .@"struct") std.debug.panic(
        "Expected struct type. Invalid type: {s}\n",
        .{@typeName(DStruct)},
    );

    const cfg_info = @typeInfo(@TypeOf(ops_cfg));
    if (cfg_info != .@"struct") std.debug.panic(
        "Expected struct type. Invalid type: {s}\n",
        .{@typeName(@TypeOf(ops_cfg))},
    );

    inline for (ops_cfg) |op_cfg| {
        const CfgType = @TypeOf(op_cfg);
        if (!@hasField(CfgType, "func")) std.debug.panic("Expected Op Cfg to have a `func` field\n", .{});
        if (!@hasField(CfgType, "fmt")) std.debug.panic("Expected Op Cfg to have a `fmt` field\n", .{});

        const func = op_cfg.func;
        const fn_info = @typeInfo(@TypeOf(func)).@"fn";

        if (fn_info.params.len > 5) std.debug.panic("Profiler currently only supports functions with up to 4 args", .{});

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
                        std.debug.panic("Expected a generator arg type {s} at index {} in func {s}\n", .{
                            @typeName(T),
                            i,
                            @typeName(@TypeOf(func)),
                        });
                    }
                },
            }
        }
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
