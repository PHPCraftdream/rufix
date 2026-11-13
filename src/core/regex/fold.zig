//! Rune sets and simple case folding for the regex compiler.
const std = @import("std");
const parse = @import("parse.zig");
const Error = parse.Error;
const max_rune = parse.max_rune;

// ---------- rune sets ----------

pub const Set = struct {
    a: std.mem.Allocator,
    r: std.ArrayList(u32) = .empty,

    pub fn add(s: *Set, lo: u32, hi: u32) !void {
        try s.r.append(s.a, lo);
        try s.r.append(s.a, hi);
    }

    /// Sorted, merged pairs.
    pub fn finish(s: *Set) ![]const u32 {
        const n = s.r.items.len / 2;
        const Pair = struct { lo: u32, hi: u32 };
        const pairs = try s.a.alloc(Pair, n);
        for (pairs, 0..) |*p, i| p.* = .{ .lo = s.r.items[2 * i], .hi = s.r.items[2 * i + 1] };
        std.mem.sort(Pair, pairs, {}, struct {
            fn lt(_: void, x: Pair, y: Pair) bool {
                return x.lo < y.lo;
            }
        }.lt);
        var out: std.ArrayList(u32) = .empty;
        for (pairs) |p| {
            const len = out.items.len;
            if (len > 0 and p.lo <= out.items[len - 1] +| 1) {
                out.items[len - 1] = @max(out.items[len - 1], p.hi);
            } else {
                try out.append(s.a, p.lo);
                try out.append(s.a, p.hi);
            }
        }
        return out.items;
    }
};

pub fn negate(a: std.mem.Allocator, ranges: []const u32) ![]const u32 {
    var out: std.ArrayList(u32) = .empty;
    var next: u32 = 0;
    var i: usize = 0;
    while (i + 1 < ranges.len) : (i += 2) {
        if (ranges[i] > next) {
            try out.append(a, next);
            try out.append(a, ranges[i] - 1);
        }
        next = ranges[i + 1] + 1;
    }
    if (next <= max_rune) {
        try out.append(a, next);
        try out.append(a, max_rune);
    }
    return out.items;
}

// ---------- simple case folding ----------
// Covers ASCII, Latin-1, Latin Extended-A, Greek and Cyrillic basics plus
// the two non-ASCII runes that fold to ASCII (U+017F ſ, U+212A K). Any other
// cased rune under (?i) is a compile error.

pub fn simpleOrbit(r: u32, buf: *[4]u32) ?[]const u32 {
    // Special orbits first.
    const specials = [_][]const u32{
        &.{ 'K', 'k', 0x212A },
        &.{ 'S', 's', 0x17F },
        &.{ 0xB5, 0x39C, 0x3BC },
        &.{ 0xC5, 0xE5, 0x212B },
        &.{ 0xFF, 0x178 },
        &.{ 0x3A3, 0x3C2, 0x3C3 },
        &.{ 0x398, 0x3B8, 0x3D1, 0x3F4 },
        &.{ 0x392, 0x3B2, 0x3D0 },
        &.{ 0x395, 0x3B5, 0x3F5 },
        &.{ 0x399, 0x345, 0x3B9, 0x1FBE },
        &.{ 0x39A, 0x3BA, 0x3F0 },
        &.{ 0x3A0, 0x3C0, 0x3D6 },
        &.{ 0x3A1, 0x3C1, 0x3F1 },
        &.{ 0x3A6, 0x3C6, 0x3D5 },
        &.{ 0x3A9, 0x3C9, 0x2126 },
        &.{ 0x412, 0x432, 0x1C80 },
        &.{ 0x414, 0x434, 0x1C81 },
        &.{ 0x41E, 0x43E, 0x1C82 },
        &.{ 0x421, 0x441, 0x1C83 },
        &.{ 0x422, 0x442, 0x1C84, 0x1C85 },
        &.{ 0x42A, 0x44A, 0x1C86 },
        &.{ 0x462, 0x463, 0x1C87 },
        &.{ 0xDF, 0x1E9E },
    };
    for (specials) |orbit| {
        for (orbit) |x| if (x == r) return orbit;
    }
    var other: ?u32 = null;
    if (r >= 'A' and r <= 'Z') other = r + 32 else if (r >= 'a' and r <= 'z') other = r - 32 else if (r >= 0xC0 and r <= 0xDE and r != 0xD7) other = r + 32 else if (r >= 0xE0 and r <= 0xFE and r != 0xF7) other = r - 32 else if (r >= 0x100 and r <= 0x17E and r != 0x130 and r != 0x131 and r != 0x138 and r != 0x149) {
        // Latin Extended-A alternates upper/lower; the block shifts parity at U+0139.
        const odd_upper = (r >= 0x139 and r <= 0x148) or (r >= 0x179 and r <= 0x17E);
        const is_upper = if (odd_upper) r % 2 == 1 else r % 2 == 0;
        other = if (is_upper) r + 1 else r - 1;
    } else if (r >= 0x391 and r <= 0x3AB and r != 0x3A2) other = r + 32 else if (r >= 0x3B1 and r <= 0x3CB and r != 0x3C2) other = r - 32 else if (r >= 0x410 and r <= 0x42F) other = r + 32 else if (r >= 0x430 and r <= 0x44F) other = r - 32 else if (r >= 0x400 and r <= 0x40F) other = r + 80 else if (r >= 0x450 and r <= 0x45F) other = r - 80;
    if (other) |o| {
        buf[0] = r;
        buf[1] = o;
        return buf[0..2];
    }
    return null;
}

/// Blocks holding cased letters the tables above do not cover.
pub const uncovered_cased = [_][2]u32{
    .{ 0x180, 0x24F },     .{ 0x250, 0x2AF },     .{ 0x370, 0x390 },     .{ 0x3CC, 0x3FF },
    .{ 0x460, 0x52F },     .{ 0x531, 0x586 },     .{ 0x10A0, 0x10FF },   .{ 0x13A0, 0x13FF },
    .{ 0x1C88, 0x1CBF },   .{ 0x1D79, 0x1D8E },   .{ 0x1E00, 0x1E9D },   .{ 0x1E9F, 0x1FBD },
    .{ 0x1FBF, 0x1FFF },   .{ 0x2132, 0x2132 },   .{ 0x214E, 0x214E },   .{ 0x2160, 0x2184 },
    .{ 0x24B6, 0x24E9 },   .{ 0x2C00, 0x2D2F },   .{ 0xA640, 0xA69F },   .{ 0xA722, 0xA7FF },
    .{ 0xAB53, 0xAB53 },   .{ 0xAB70, 0xABBF },   .{ 0xFF21, 0xFF3A },   .{ 0xFF41, 0xFF5A },
    .{ 0x10400, 0x1044F }, .{ 0x104B0, 0x104FB }, .{ 0x10570, 0x105BC }, .{ 0x10C80, 0x10CF2 },
    .{ 0x118A0, 0x118DF }, .{ 0x16E40, 0x16E7F }, .{ 0x1E900, 0x1E943 },
};

/// A rune with case the tables cannot fold: (?i) on it fails to compile
/// instead of matching fewer forms than Go would.
pub fn hasUnknownCase(r: u32) bool {
    var buf: [4]u32 = undefined;
    if (simpleOrbit(r, &buf) != null) return false;
    for (uncovered_cased) |b| if (r >= b[0] and r <= b[1]) return true;
    return false;
}

pub fn addFolded(set: *Set, lo: u32, hi: u32) Error!void {
    try set.add(lo, hi);
    for (uncovered_cased) |b| if (lo <= b[1] and hi >= b[0]) return error.InvalidRegex;
    var buf: [4]u32 = undefined;
    var r = lo;
    const lim = @min(hi, 0x52F);
    while (r <= lim) : (r += 1) {
        if (simpleOrbit(r, &buf)) |orbit| for (orbit) |o| try set.add(o, o);
    }
    for ([_]u32{ 0x1C80, 0x1C81, 0x1C82, 0x1C83, 0x1C84, 0x1C85, 0x1C86, 0x1C87, 0x1E9E, 0x1FBE, 0x2126, 0x212A, 0x212B }) |x| {
        if (x >= lo and x <= hi) {
            if (simpleOrbit(x, &buf)) |orbit| for (orbit) |o| try set.add(o, o);
        }
    }
}

/// Folds every range of a finished set (used for Perl and POSIX classes).
pub fn foldRanges(a: std.mem.Allocator, ranges: []const u32) Error![]const u32 {
    var set = Set{ .a = a };
    var i: usize = 0;
    while (i + 1 < ranges.len) : (i += 2) try addFolded(&set, ranges[i], ranges[i + 1]);
    return set.finish();
}

// ---------- parser ----------