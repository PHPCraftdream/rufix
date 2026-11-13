//! conformance/engine and conformance/regex.
const std = @import("std");
const rufix = @import("rufix");
const t = @import("support.zig");

test "engine fixtures" {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var failures: usize = 0;
    for (try t.cases(a, "engine")) |c| {
        const name = t.str(c, "name");
        var st = t.store(a, c) catch |err| {
            t.fail(name, "store: {s}", .{@errorName(err)});
            failures += 1;
            continue;
        };
        for (t.array(c, "steps"), 0..) |sv, i| {
            const s = sv.object;
            const op = t.str(s, "op");
            const input = t.str(s, "input");
            if (std.mem.eql(u8, op, "host_placeholder") or std.mem.eql(u8, op, "has_domain_mask")) {
                const got = if (op[1] == 'o') try st.hostPlaceholder(input) else try st.hasDomainMask(input);
                if (got != t.flag(s, "result")) {
                    t.fail(name, "step {d} {s}({s}) = {}", .{ i, op, input, got });
                    failures += 1;
                }
                continue;
            }
            const r = if (std.mem.eql(u8, op, "redact"))
                try st.redact(input)
            else if (std.mem.eql(u8, op, "restore"))
                try st.restore(input)
            else
                try st.restoreDomains(input);
            const want_out = t.str(s, "output");
            const want_count = t.int(s, "count") orelse -1;
            if (!std.mem.eql(u8, r.out, want_out) or @as(i64, @intCast(r.count)) != want_count) {
                t.fail(name, "step {d} {s}({s}) = {s} [{d}], want {s} [{d}]", .{ i, op, input, r.out, r.count, want_out, want_count });
                failures += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "regex fixtures" {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var failures: usize = 0;
    for (try t.cases(a, "regex")) |c| {
        const pattern = t.str(c, "pattern");
        const want_valid = t.flag(c, "valid");
        const compiled = rufix.regex.compile(a, pattern) catch null;
        if (compiled == null) {
            if (want_valid and !t.flag(c, "may_reject")) {
                t.fail(pattern, "rejected a valid pattern", .{});
                failures += 1;
            }
            continue;
        }
        if (!want_valid) {
            t.fail(pattern, "accepted an invalid pattern", .{});
            failures += 1;
            continue;
        }
        const matches = t.array(c, "matches");
        for (t.array(c, "inputs"), 0..) |iv, i| {
            const got = try rufix.vm.findAll(a, &compiled.?.program, iv.string);
            const want = matches[i].array.items.items;
            var same = got.len == want.len;
            if (same) for (got, want) |g, w| {
                const wl = w.array.items.items;
                if (g.len != wl.len) {
                    same = false;
                    break;
                }
                for (g, wl) |x, y| {
                    if (x != (std.fmt.parseInt(isize, y.number, 10) catch -2)) same = false;
                }
            };
            if (!same) {
                t.fail(pattern, "input {d} {s}: matches differ (got {d} matches)", .{ i, iv.string, got.len });
                failures += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "until_stable stops a rule that never settles" {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var failed: usize = 0;
    const specs = [_]rufix.engine.RuleSpec{.{ .name = "grow", .match = "x+", .replace = "xy", .until_stable = true }};
    var st = rufix.engine.Store{ .gpa = a, .exact = &.{}, .rules = try rufix.engine.compileRules(a, &specs, &failed) };
    try std.testing.expectError(error.RuleNeverSettles, st.redact("x"));
}
