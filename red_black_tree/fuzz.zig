const std = @import("std");
const fuzz = @import("fuzz");
const rbt_mod = @import("red_black_tree.zig");

const RedBlackTree = rbt_mod.RedBlackTree(u64, cmpFn, false);

var dbg_alloc = std.heap.DebugAllocator(.{}){};
var list: std.ArrayList(u64) = .empty;

pub fn main() !void {
    const Fuzzer = fuzz.Fuzzer(RedBlackTree, .{
        .{
            .func = RedBlackTree.insert,
            .fmt = "insert {}, {} -> !",
            .priority = 1,
            .callbacks = .{
                .{ .param_idx = 2, .callback = insertCallback },
            },
            .generators = .{
                .{ .param_idx = 1, .generator = allocatorGenerator },
            },
        },
        .{
            .func = RedBlackTree.remove,
            .fmt = "remove {}, {} -> !{}",
            .priority = 1,
            .generators = .{
                .{ .param_idx = 1, .generator = allocatorGenerator },
                .{ .param_idx = 2, .generator = removeInputGenerator },
            },
        },
    });

    var iterations: u64 = 0;
    var log_path: []const u8 = "fuzz.log";
    var seed: u64 = 0;

    const allocator = dbg_alloc.allocator();
    var argsIter = try std.process.ArgIterator.initWithAllocator(allocator);

    const base_10 = 10;
    while (argsIter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-i")) {
            if (argsIter.next()) |iters| {
                iterations = try std.fmt.parseInt(u64, iters, base_10);
            }
        } else if (std.mem.eql(u8, arg, "-o")) {
            if (argsIter.next()) |path| {
                log_path = path;
            }
        } else if (std.mem.eql(u8, arg, "-s")) {
            if (argsIter.next()) |s| {
                seed = try std.fmt.parseInt(u64, s, base_10);
            }
        } else continue;
    }

    var file = try std.fs.cwd().createFile(log_path, .{ .truncate = true });
    defer file.close();

    const four_KiB = 4 * 4096;
    const buffer = try allocator.alloc(u8, four_KiB);
    var file_writer = file.writer(buffer);
    const w = &file_writer.interface;
    defer w.flush() catch {};

    var rbt = RedBlackTree.init();
    var fuzzer = Fuzzer.init(validate, &rbt, seed, w);
    for (0..iterations) |_| {
        fuzzer.step() catch |err| {
            switch (err) {
                error.NotFound => continue,
                else => return err,
            }
        };
    }
}

fn cmpFn(a: u64, b: u64) std.math.Order {
    return std.math.order(a, b);
}

fn insertCallback(val: u64) void {
    list.append(
        dbg_alloc.allocator(),
        val,
    ) catch |err| std.debug.panic(
        "Failed to insert into arraylist. Error {}\n",
        .{err},
    );
}

fn allocatorGenerator() std.mem.Allocator {
    return dbg_alloc.allocator();
}

fn removeInputGenerator() u64 {
    if (list.items.len == 0) return 0;
    const rand = fuzz.rng.random();
    const idx = rand.intRangeLessThan(usize, 0, list.items.len);
    return list.swapRemove(idx);
}

fn validate(tree: *RedBlackTree) bool {
    const result = RedBlackTree.validateRedBlackTree(tree.root, null, null);
    return result.valid;
}
