//! Replacement engine: exact values first, then rules in order; reverse rules
//! in reverse order, then exact placeholders.
const std = @import("std");
const vm = @import("vm.zig");

pub const Exact = struct {
    value: []const u8,
    placeholder: []const u8,
    host: bool,
};

pub const Var = struct { key: []const u8, value: []const u8 };

/// A filter as written in values.zig (same fields as redact.RuleData).
pub const RuleSpec = struct {
    name: []const u8,
    match: []const u8,
    replace: []const u8,
    restore_match: []const u8 = "",
    restore_replace: []const u8 = "",
    allowlist_seed: bool = false,
    strict_tld: bool = false,
    preserve_case: bool = false,
    /// Apply the rule again while it still changes the text: a match that
    /// consumes a delimiter (`_` in `x_x`) otherwise hides the next one.
    until_stable: bool = false,
};

/// Passes an until_stable rule may take; a rule that never settles is an
/// error, not a hang.
pub const max_passes = 16;

/// Compiles every pattern; a pattern that fails to compile is an error
/// naming the filter index only, never its text.
pub fn compileRules(a: std.mem.Allocator, specs: []const RuleSpec, failed: *usize) ![]const Rule {
    const regex = @import("regex/regex.zig");
    var out: std.ArrayList(Rule) = .empty;
    for (specs, 0..) |s, i| {
        failed.* = i;
        const fwd = try regex.compile(a, s.match);
        const fp = try a.create(vm.Program);
        fp.* = fwd.program;
        var rule = Rule{
            .name = s.name,
            .fwd = fp,
            .replace = try regex.parseTemplate(a, s.replace, fwd.names),
            .allowlist_seed = s.allowlist_seed,
            .strict_tld = s.strict_tld,
            .preserve_case = s.preserve_case,
            .until_stable = s.until_stable,
        };
        if (s.restore_match.len > 0) {
            const rev = try regex.compile(a, s.restore_match);
            const rp = try a.create(vm.Program);
            rp.* = rev.program;
            rule.rev = rp;
            rule.restore = try regex.parseTemplate(a, s.restore_replace, rev.names);
        }
        try out.append(a, rule);
    }
    return out.items;
}

/// A name part equal to a credential word marks a credential variable.
pub fn secretKey(key: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, key, "_-");
    while (it.next()) |part| {
        for ([_][]const u8{ "TOKEN", "SECRET", "PASSWORD", "PASSWD", "PAT", "KEY", "CREDENTIAL", "CREDENTIALS" }) |w| {
            if (std.ascii.eqlIgnoreCase(part, w)) return true;
        }
    }
    return false;
}

pub fn placeholder(a: std.mem.Allocator, value: []const u8) ![]const u8 {
    var sum: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(value, &sum, .{});
    const hex = std.fmt.bytesToHex(sum[0..4].*, .lower);
    return std.mem.concat(a, u8, &.{ "[S:", &hex, "]" });
}

fn isProtectedHost(v: []const u8) bool {
    return std.mem.indexOfScalar(u8, v, '.') != null and std.mem.indexOfAny(u8, v, " \t\n") == null;
}

/// Derives the protected values from variables:
/// names in byte order; credentials (6+ bytes) or URL parts; longest first,
/// ties by value. Only URL-derived values can be host evidence, and a value
/// that is also a credential never is.
pub fn buildExact(a: std.mem.Allocator, vars_in: []const Var) ![]const Exact {
    const url = @import("url.zig");
    const vars = try a.dupe(Var, vars_in);
    std.mem.sort(Var, vars, {}, struct {
        fn lt(_: void, x: Var, y: Var) bool {
            return std.mem.lessThan(u8, x.key, y.key);
        }
    }.lt);
    var list: std.ArrayList(Exact) = .empty;
    const add = struct {
        fn f(al: std.mem.Allocator, l: *std.ArrayList(Exact), value: []const u8, from_url: bool) !void {
            if (value.len < 4 or std.mem.indexOfScalar(u8, value, '\n') != null) return;
            const p = try placeholder(al, value);
            const host = from_url and isProtectedHost(value);
            for (l.items) |*e| {
                if (std.mem.eql(u8, e.placeholder, p)) {
                    e.host = e.host and host;
                    return;
                }
            }
            try l.append(al, .{ .value = value, .placeholder = p, .host = host });
        }
    }.f;
    var last_key: ?[]const u8 = null;
    for (vars) |v| {
        // Later duplicates of a name lose, as in a Go map built first-wins.
        if (last_key) |k| if (std.mem.eql(u8, k, v.key)) continue;
        last_key = v.key;
        if (v.value.len == 0) continue;
        if (secretKey(v.key) and v.value.len >= 6) {
            try add(a, &list, v.value, false);
            continue;
        }
        const u = url.parse(a, v.value) catch continue;
        if (u.host.len == 0) continue;
        try add(a, &list, v.value, true);
        try add(a, &list, u.host, true);
        try add(a, &list, u.hostname(), true);
        if (u.password) |pw| if (pw.len >= 6) try add(a, &list, pw, false);
    }
    std.mem.sort(Exact, list.items, {}, struct {
        fn lt(_: void, x: Exact, y: Exact) bool {
            if (x.value.len != y.value.len) return x.value.len > y.value.len;
            return std.mem.lessThan(u8, x.value, y.value);
        }
    }.lt);
    return list.items;
}

pub const Rule = struct {
    name: []const u8,
    fwd: *const vm.Program,
    replace: []const vm.Segment,
    rev: ?*const vm.Program = null,
    restore: []const vm.Segment = &.{},
    allowlist_seed: bool = false,
    strict_tld: bool = false,
    preserve_case: bool = false,
    until_stable: bool = false,
};

pub const Store = struct {
    gpa: std.mem.Allocator,
    exact: []const Exact,
    rules: []const Rule,
    /// Forward replacements of allowlist-seed rules seen in this process.
    seeds: std.ArrayList([]const u8) = .empty,
    /// Off for the shell filter, which never restores and frees per line.
    remember_seeds: bool = true,

    pub const Result = struct { out: []const u8, count: usize };

    pub fn redact(st: *Store, input: []const u8) !Result {
        var s = input;
        var count: usize = 0;
        for (st.exact) |e| {
            const r = try replaceExact(st.gpa, s, e.value, e.placeholder);
            s = r.out;
            count += r.count;
        }
        for (st.rules) |rule| {
            const r = try st.applyRule(s, rule, rule.fwd, rule.replace, rule.allowlist_seed);
            s = r.out;
            count += r.count;
        }
        return .{ .out = s, .count = count };
    }

    /// One rule in one direction: once, or until it stops changing the text.
    fn applyRule(st: *Store, input: []const u8, rule: Rule, p: *const vm.Program, segs: []const vm.Segment, seed: bool) !Result {
        var s = input;
        var count: usize = 0;
        var pass: usize = 0;
        while (true) : (pass += 1) {
            if (pass == max_passes) return error.RuleNeverSettles;
            const r = try st.replaceRule(s, p, segs, rule.strict_tld, rule.preserve_case, seed);
            s = r.out;
            count += r.count;
            if (!rule.until_stable or r.count == 0) return .{ .out = s, .count = count };
        }
    }

    pub fn restoreDomains(st: *Store, input: []const u8) !Result {
        var s = input;
        var count: usize = 0;
        var i = st.rules.len;
        while (i > 0) {
            i -= 1;
            const rule = st.rules[i];
            const rev = rule.rev orelse continue;
            const r = try st.applyRule(s, rule, rev, rule.restore, false);
            s = r.out;
            count += r.count;
        }
        return .{ .out = s, .count = count };
    }

    pub fn restore(st: *Store, input: []const u8) !Result {
        var r = try st.restoreDomains(input);
        for (st.exact) |e| {
            const x = try replaceExact(st.gpa, r.out, e.placeholder, e.value);
            r.out = x.out;
            r.count += x.count;
        }
        return r;
    }

    pub fn hostPlaceholder(st: *Store, s: []const u8) !bool {
        var rest = s;
        while (nextPlaceholder(rest)) |found| {
            for (st.exact) |e| {
                if (e.host and std.mem.eql(u8, e.placeholder, found.token)) return true;
            }
            rest = found.tail;
        }
        if (try st.hasDomainMask(s)) return true;
        for (st.seeds.items) |seed| {
            if (std.mem.indexOf(u8, s, seed) != null) return true;
        }
        return false;
    }

    pub fn hasDomainMask(st: *Store, s: []const u8) !bool {
        for (st.rules) |rule| {
            if (!rule.allowlist_seed) continue;
            const rev = rule.rev orelse continue;
            if (try vm.matches(st.gpa, rev, s)) return true;
        }
        return false;
    }

    fn replaceRule(st: *Store, s: []const u8, p: *const vm.Program, segs: []const vm.Segment, strict: bool, preserve: bool, seed: bool) !Result {
        const locs = try vm.findAll(st.gpa, p, s);
        if (locs.len == 0) return .{ .out = s, .count = 0 };
        var out: std.ArrayList(u8) = .empty;
        var last: usize = 0;
        var count: usize = 0;
        for (locs) |loc| {
            const m0: usize = @intCast(loc[0]);
            const m1: usize = @intCast(loc[1]);
            if (strict and isMidLabelTail(s, m1)) continue;
            try out.appendSlice(st.gpa, s[last..m0]);
            const matched = s[m0..m1];
            var repl: []const u8 = undefined;
            if (strict or seed) {
                // Go re-runs the rule on the match alone in this path.
                repl = try vm.replaceAll(st.gpa, p, matched, segs);
            } else {
                var buf: std.ArrayList(u8) = .empty;
                try vm.expand(st.gpa, &buf, segs, s, loc);
                repl = buf.items;
            }
            if (preserve) repl = try matchCase(st.gpa, matched, repl);
            if (seed and st.remember_seeds) try st.seeds.append(st.gpa, repl);
            try out.appendSlice(st.gpa, repl);
            last = m1;
            count += 1;
        }
        if (count == 0) return .{ .out = s, .count = 0 };
        try out.appendSlice(st.gpa, s[last..]);
        return .{ .out = out.items, .count = count };
    }
};

fn replaceExact(gpa: std.mem.Allocator, s: []const u8, old: []const u8, new: []const u8) !Store.Result {
    var start = std.mem.indexOf(u8, s, old) orelse return .{ .out = s, .count = 0 };
    var out: std.ArrayList(u8) = .empty;
    var last: usize = 0;
    var count: usize = 0;
    while (true) {
        try out.appendSlice(gpa, s[last..start]);
        try out.appendSlice(gpa, new);
        last = start + old.len;
        count += 1;
        start = last + (std.mem.indexOf(u8, s[last..], old) orelse break);
    }
    try out.appendSlice(gpa, s[last..]);
    return .{ .out = out.items, .count = count };
}

fn isDomainChar(c: u8) bool {
    return c == '-' or c == '_' or std.ascii.isAlphanumeric(c);
}

fn isMidLabelTail(s: []const u8, end: usize) bool {
    return end < s.len and s[end] == '.' and end + 1 < s.len and isDomainChar(s[end + 1]);
}

fn fold(c: u8) u8 {
    return std.ascii.toLower(c);
}

/// Carries the letter case of matched into repl: shared edges are copied,
/// the differing middle takes the match's case (all upper, else per position).
pub fn matchCase(gpa: std.mem.Allocator, matched: []const u8, repl: []const u8) ![]const u8 {
    var p: usize = 0;
    while (p < matched.len and p < repl.len and fold(matched[p]) == fold(repl[p])) p += 1;
    var q: usize = 0;
    while (q < matched.len - p and q < repl.len - p and
        fold(matched[matched.len - 1 - q]) == fold(repl[repl.len - 1 - q])) q += 1;
    const src = matched[p .. matched.len - q];
    const dst = try gpa.dupe(u8, repl[p .. repl.len - q]);
    var upper: usize = 0;
    var lower: usize = 0;
    for (src) |c| {
        if (std.ascii.isUpper(c)) upper += 1;
        if (std.ascii.isLower(c)) lower += 1;
    }
    for (dst, 0..) |*c, i| {
        if (upper > 0 and lower == 0) {
            c.* = std.ascii.toUpper(c.*);
        } else if (i < src.len and std.ascii.isUpper(src[i])) {
            c.* = std.ascii.toUpper(c.*);
        } else if (i < src.len and std.ascii.isLower(src[i])) {
            c.* = std.ascii.toLower(c.*);
        }
    }
    return std.mem.concat(gpa, u8, &.{ matched[0..p], dst, matched[matched.len - q ..] });
}

const Found = struct { token: []const u8, tail: []const u8 };

/// Next well-formed [S:xxxxxxxx] placeholder (8 lower-case hex digits).
pub fn nextPlaceholder(input: []const u8) ?Found {
    var s = input;
    while (true) {
        const i = std.mem.indexOf(u8, s, "[S:") orelse return null;
        s = s[i..];
        if (s.len >= 12 and s[11] == ']') {
            var valid = true;
            for (s[3..11]) |c| {
                if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) {
                    valid = false;
                    break;
                }
            }
            if (valid) return .{ .token = s[0..12], .tail = s[12..] };
        }
        s = s[3..];
    }
}
