//! Repository linter: no file over 500 lines and no folder (except the
//! root) with more than 7 entries. Covers every file git would track:
//! committed or not, minus ignored ones.
const std = @import("std");
const rufix = @import("rufix");
const io = rufix.io;

const max_lines = 500;
const max_entries = 7;

fn trackedFiles(a: std.mem.Allocator) ![]const []const u8 {
    const r = try std.process.run(a, std.testing.io, .{
        .argv = &.{ "git", "ls-files", "--cached", "--others", "--exclude-standard", "-z" },
    });
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, r.stdout, 0);
    while (it.next()) |p| if (p.len > 0) try out.append(a, p);
    return out.items;
}

fn lineCount(data: []const u8) usize {
    if (data.len == 0) return 0;
    var n = std.mem.count(u8, data, "\n");
    if (data[data.len - 1] != '\n') n += 1;
    return n;
}

test "no file over 500 lines, no folder over 7 entries" {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var failures: usize = 0;
    var children = std.StringHashMap(std.StringHashMap(void)).init(a);
    for (try trackedFiles(a)) |path| {
        // A file deleted but still in the index is no longer part of the tree.
        const data = try io.readFile(a, path) orelse continue;
        const n = lineCount(data);
        if (n > max_lines) {
            std.debug.print("lint: {s} has {d} lines (max {d})\n", .{ path, n, max_lines });
            failures += 1;
        }
        // Record every (folder, entry) pair along the path.
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, path, start, '/')) |slash| {
            const parent = path[0..slash];
            const end = std.mem.indexOfScalarPos(u8, path, slash + 1, '/') orelse path.len;
            const gop = try children.getOrPut(parent);
            if (!gop.found_existing) gop.value_ptr.* = std.StringHashMap(void).init(a);
            try gop.value_ptr.put(path[slash + 1 .. end], {});
            start = slash + 1;
        }
    }
    var it = children.iterator();
    while (it.next()) |e| {
        const n = e.value_ptr.count();
        if (n > max_entries) {
            std.debug.print("lint: {s}/ has {d} entries (max {d})\n", .{ e.key_ptr.*, n, max_entries });
            failures += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}
