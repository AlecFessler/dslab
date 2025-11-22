const std = @import("std");
const fuzzlib = @import("fuzzlib");
const rbt_mod = @import("red_black_tree.zig");

const RedBlackTree = rbt_mod.RedBlackTree(u64, cmpFn, false);

var dbg_alloc = std.heap.DebugAllocator(.{}){};
var list: std.ArrayList(u64) = .empty;

pub fn main() !void {
    const Fuzzer = fuzzlib.Fuzzer(RedBlackTree, .{
        .{
            .func = RedBlackTree.insert,
            .name = "insert",
            .args_fmt = "{}",
            .callbacks = .{
                .{ .param_idx = 2, .callback = insertCallback },
            },
            .generators = .{
                .{ .param_idx = 1, .generator = allocatorGenerator },
            },
        },
        .{
            .func = RedBlackTree.remove,
            .name = "remove",
            .args_fmt = "{}",
            .ret_fmt = "{}",
            .generators = .{
                .{ .param_idx = 1, .generator = allocatorGenerator },
                .{ .param_idx = 2, .generator = removeInputGenerator },
            },
        },
    });

    const buffer = try dbg_alloc.allocator().alloc(u8, 4 * 4096);
    defer dbg_alloc.allocator().free(buffer);

    var file = try std.fs.cwd().createFile("fuzz.log", .{ .truncate = true });
    defer file.close();

    var file_writer = file.writer(buffer);
    const w = &file_writer.interface;
    defer w.flush() catch |err| {
        std.debug.panic("log writer flush failed: {}\n", .{err});
    };
    fuzzlib.setLogWriter(w);

    var rbt = RedBlackTree.init();
    const seed = 0;

    var fuzzer = Fuzzer.init(validate, &rbt, seed);
    for (0..100_000) |_| {
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
    const rand = fuzzlib.rng.random();
    const idx = rand.intRangeLessThan(usize, 0, list.items.len);
    return list.swapRemove(idx);
}

fn validate(tree: *RedBlackTree) bool {
    const result = RedBlackTree.validateRedBlackTree(tree.root, null, null);
    return result.valid;
}
