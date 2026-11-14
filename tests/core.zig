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
        failures += try t.runSteps(&st, name, t.array(c, "steps"));
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

fn sameRule(name: []const u8, what: []const u8, got: rufix.rules.Rule, want: anytype) bool {
    const text_ok = std.mem.eql(u8, got.name, want.name) and std.mem.eql(u8, got.match, want.match) and
        std.mem.eql(u8, got.replace, want.replace) and std.mem.eql(u8, got.restore_match, want.restore_match) and
        std.mem.eql(u8, got.restore_replace, want.restore_replace);
    const flags_ok = got.allowlist_seed == want.allowlist_seed and got.strict_tld == want.strict_tld and
        got.preserve_case == want.preserve_case and got.until_stable == want.until_stable;
    if (text_ok and flags_ok) return true;
    t.fail(name, "{s}: rule differs: match {s} replace {s} restore_match {s} restore_replace {s}", .{ what, got.match, got.replace, got.restore_match, got.restore_replace });
    return false;
}

test "rules fixtures" {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var failures: usize = 0;
    for (try t.cases(a, "rules")) |c| {
        const name = t.str(c, "name");
        const kind = std.meta.stringToEnum(rufix.rules.Kind, t.str(c, "helper")) orelse {
            t.fail(name, "unknown helper {s}", .{t.str(c, "helper")});
            failures += 1;
            continue;
        };
        const got = rufix.rules.expand(a, kind, t.str(c, "from"), t.str(c, "to")) catch |err| {
            if (!t.flag(c, "error") or err != error.InvalidName) {
                t.fail(name, "expand: {s}", .{@errorName(err)});
                failures += 1;
            }
            continue;
        };
        if (t.flag(c, "error")) {
            t.fail(name, "expected the names to be refused", .{});
            failures += 1;
            continue;
        }
        const want = c.get("rule").?.object;
        const expected = rufix.rules.Rule{
            .name = t.str(want, "name"),
            .match = t.str(want, "match"),
            .replace = t.str(want, "replace"),
            .restore_match = t.str(want, "restore_match"),
            .restore_replace = t.str(want, "restore_replace"),
            .allowlist_seed = t.flag(want, "allowlist_seed"),
            .strict_tld = t.flag(want, "strict_tld"),
            .preserve_case = t.flag(want, "preserve_case"),
            .until_stable = t.flag(want, "until_stable"),
        };
        if (!sameRule(name, "expansion", got, expected)) {
            failures += 1;
            continue;
        }
        // The fixture's own rule goes through the engine, so a wrong
        // expansion cannot hide behind a right-looking one.
        var failed: usize = 0;
        const specs = [_]rufix.engine.RuleSpec{expected};
        var st = rufix.engine.Store{ .gpa = a, .exact = &.{}, .rules = try rufix.engine.compileRules(a, &specs, &failed) };
        failures += try t.runSteps(&st, name, t.array(c, "steps"));
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "compile-time helpers expand like the run-time ones" {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = rufix.rules;
    var failures: usize = 0;
    inline for (.{
        .{ r.Kind.domain, "acme", "zephyr" },
        .{ r.Kind.import, "acme", "zephyr" },
        .{ r.Kind.path, "acme", "zephyr" },
        .{ r.Kind.word, "acme", "zephyr" },
        .{ r.Kind.word, "a.b", "c" },
        .{ r.Kind.import, "acme-co", "zephyr_1" },
    }) |case| {
        const built = comptime r.build(case[0], case[1], case[2]);
        const expanded = try r.expand(a, case[0], case[1], case[2]);
        if (!sameRule(case[1], "compile time vs run time", built, expanded)) failures += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}
