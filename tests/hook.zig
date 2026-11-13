//! conformance/hook: one hook run per case.
const std = @import("std");
const rufix = @import("rufix");
const t = @import("support.zig");

test "hook fixtures" {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var failures: usize = 0;
    for (try t.cases(a, "hook")) |c| {
        const name = t.str(c, "name");
        var st = try t.store(a, c);
        // The input is replayed as JSON text with its literals intact.
        const stdin = if (c.get("stdin_raw")) |raw| raw.string else t.render(a, c.get("input") orelse .null);
        var out = rufix.hook.Output{};
        const code = rufix.hook.run(a, &st, stdin, &out);
        const want_exit = t.int(c, "exit") orelse -1;
        const want_stdout = c.get("stdout") orelse .null;
        if (code != want_exit or !t.equalText(a, out.stdout.items, want_stdout)) {
            t.fail(name, "exit {d} stdout {s}; want exit {d} stdout {s}", .{ code, out.stdout.items, want_exit, t.render(a, want_stdout) });
            failures += 1;
        }
        if (code == 2 and out.stdout.items.len != 0) {
            t.fail(name, "blocking error wrote stdout", .{});
            failures += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}
