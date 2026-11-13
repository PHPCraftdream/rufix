//! Pike VM over the programs regex/ compiles:
//! leftmost-first matching identical to
//! Go's regexp, including its UTF-8 and empty-match rules.
const std = @import("std");

pub const Op = enum { alt, cap, empty, rune, nop, match, fail };

pub const Inst = struct {
    op: Op,
    out: u32 = 0,
    arg: u32 = 0,
    ranges: []const u32 = &.{},
};

pub const Segment = union(enum) {
    text: []const u8,
    group: u32,
    /// A name shared by several groups: the first that took part expands.
    named: []const u32,
};

pub const Template = struct {
    source: []const u8,
    segments: []const Segment,
};

pub const Program = struct {
    start: u32,
    num_cap: u32,
    insts: []const Inst,
    templates: []const Template = &.{},

    pub fn template(self: *const Program, source: []const u8) ?[]const Segment {
        for (self.templates) |t| {
            if (std.mem.eql(u8, t.source, source)) return t.segments;
        }
        return null;
    }
};

pub const rune_error: u32 = 0xFFFD;

/// Decodes one rune like Go's utf8.DecodeRuneInString: invalid input
/// yields (U+FFFD, 1).
pub fn decode(s: []const u8, i: usize) struct { r: u32, w: usize } {
    const c = s[i];
    if (c < 0x80) return .{ .r = c, .w = 1 };
    const len = std.unicode.utf8ByteSequenceLength(c) catch return .{ .r = rune_error, .w = 1 };
    if (i + len > s.len) return .{ .r = rune_error, .w = 1 };
    const r = std.unicode.utf8Decode(s[i .. i + len]) catch return .{ .r = rune_error, .w = 1 };
    return .{ .r = r, .w = len };
}

/// Decodes the rune ending at i like Go's utf8.DecodeLastRuneInString.
fn decodeLast(s: []const u8, i: usize) u32 {
    var start = i - 1;
    const lim = if (i >= 4) i - 4 else 0;
    while (start > lim and (s[start] & 0xC0) == 0x80) start -= 1;
    const d = decode(s, start);
    if (start + d.w != i) return rune_error;
    return d.r;
}

fn isWord(r: ?u32) bool {
    const c = r orelse return false;
    return c == '_' or (c >= '0' and c <= '9') or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn emptyOk(op: u32, s: []const u8, at: usize) bool {
    const before: ?u32 = if (at > 0) decodeLast(s, at) else null;
    const after: ?u32 = if (at < s.len) decode(s, at).r else null;
    var ctx: u32 = 0;
    if (before == null) ctx |= 4 | 1;
    if (before != null and before.? == '\n') ctx |= 1;
    if (after == null) ctx |= 8 | 2;
    if (after != null and after.? == '\n') ctx |= 2;
    if (isWord(before) != isWord(after)) ctx |= 16 else ctx |= 32;
    return op & ~ctx == 0;
}

fn inRanges(ranges: []const u32, r: u32) bool {
    var i: usize = 0;
    while (i + 1 < ranges.len) : (i += 2) {
        if (ranges[i] <= r and r <= ranges[i + 1]) return true;
    }
    return false;
}

const Thread = struct { pc: u32, cap: []isize };

const Machine = struct {
    p: *const Program,
    s: []const u8,
    a: std.mem.Allocator,
    ncap: usize,

    fn add(m: *Machine, list: *std.ArrayList(Thread), seen: []bool, pc: u32, cap: []isize, at: usize) !void {
        if (seen[pc]) return;
        seen[pc] = true;
        const in = m.p.insts[pc];
        switch (in.op) {
            .alt => {
                try m.add(list, seen, in.out, cap, at);
                try m.add(list, seen, in.arg, cap, at);
            },
            .nop => try m.add(list, seen, in.out, cap, at),
            .cap => {
                const c = try m.a.dupe(isize, cap);
                if (in.arg < c.len) c[in.arg] = @intCast(at);
                try m.add(list, seen, in.out, c, at);
            },
            .empty => if (emptyOk(in.arg, m.s, at)) try m.add(list, seen, in.out, cap, at),
            .fail => {},
            .rune, .match => try list.append(m.a, .{ .pc = pc, .cap = cap }),
        }
    }
};

/// Finds the leftmost-first match starting at or after pos, searching the
/// whole string for context. Returns the capture slots (-1 = unset).
pub fn find(gpa: std.mem.Allocator, p: *const Program, s: []const u8, pos: usize) !?[]isize {
    var arenas = [2]std.heap.ArenaAllocator{ .init(gpa), .init(gpa) };
    defer arenas[0].deinit();
    defer arenas[1].deinit();
    var cur: usize = 0;
    const ncap: usize = @max(p.num_cap, 2);
    var m = Machine{ .p = p, .s = s, .a = arenas[cur].allocator(), .ncap = ncap };
    var clist: std.ArrayList(Thread) = .empty;
    var cseen = try m.a.alloc(bool, p.insts.len);
    @memset(cseen, false);
    var matched: ?[]isize = null;
    var at = pos;
    while (true) {
        if (matched == null) {
            const init = try m.a.alloc(isize, ncap);
            @memset(init, -1);
            init[0] = @intCast(at);
            try m.add(&clist, cseen, p.start, init, at);
        }
        var r: u32 = rune_error;
        var w: usize = 0;
        if (at < s.len) {
            const d = decode(s, at);
            r = d.r;
            w = d.w;
        }
        const next = 1 - cur;
        _ = arenas[next].reset(.retain_capacity);
        m.a = arenas[next].allocator();
        var nlist: std.ArrayList(Thread) = .empty;
        const nseen = try m.a.alloc(bool, p.insts.len);
        @memset(nseen, false);
        for (clist.items) |t| {
            const in = p.insts[t.pc];
            if (in.op == .match) {
                const c = try gpa.dupe(isize, t.cap);
                c[1] = @intCast(at);
                matched = c;
                break;
            }
            if (in.op == .rune and w > 0 and inRanges(in.ranges, r)) {
                // Threads move to the next arena with their own copy: the
                // arena holding t.cap is reset two steps from now.
                try m.add(&nlist, nseen, in.out, try m.a.dupe(isize, t.cap), at + w);
            }
        }
        if (at >= s.len or (nlist.items.len == 0 and matched != null)) return matched;
        clist = nlist;
        cseen = nseen;
        cur = next;
        at += w;
    }
}

/// All matches, as Go's regexp.allMatches delivers them.
pub fn findAll(gpa: std.mem.Allocator, p: *const Program, s: []const u8) ![][]isize {
    var out: std.ArrayList([]isize) = .empty;
    var pos: usize = 0;
    var prev_end: isize = -1;
    while (pos <= s.len) {
        const mm = try find(gpa, p, s, pos) orelse break;
        var accept = true;
        if (mm[1] == @as(isize, @intCast(pos))) {
            if (mm[0] == prev_end) accept = false;
            if (pos < s.len) pos += decode(s, pos).w else pos = s.len + 1;
        } else {
            pos = @intCast(mm[1]);
        }
        prev_end = mm[1];
        if (accept) try out.append(gpa, mm);
    }
    return out.items;
}

pub fn expand(gpa: std.mem.Allocator, out: *std.ArrayList(u8), segs: []const Segment, s: []const u8, caps: []const isize) !void {
    for (segs) |seg| switch (seg) {
        .text => |t| try out.appendSlice(gpa, t),
        .group => |g| {
            const i = 2 * @as(usize, g);
            if (i + 1 < caps.len and caps[i] >= 0) {
                try out.appendSlice(gpa, s[@intCast(caps[i])..@intCast(caps[i + 1])]);
            }
        },
        .named => |groups| for (groups) |g| {
            const i = 2 * @as(usize, g);
            if (i + 1 < caps.len and caps[i] >= 0) {
                try out.appendSlice(gpa, s[@intCast(caps[i])..@intCast(caps[i + 1])]);
                break;
            }
        },
    };
}

/// regexp.Regexp.ReplaceAllString with a parsed template.
pub fn replaceAll(gpa: std.mem.Allocator, p: *const Program, s: []const u8, segs: []const Segment) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var last_end: usize = 0;
    var search: usize = 0;
    while (search <= s.len) {
        const mm = try find(gpa, p, s, search) orelse break;
        const m0: usize = @intCast(mm[0]);
        const m1: usize = @intCast(mm[1]);
        try out.appendSlice(gpa, s[last_end..m0]);
        if (m1 > last_end or m0 == 0) try expand(gpa, &out, segs, s, mm);
        last_end = m1;
        const width: usize = if (search < s.len) decode(s, search).w else 0;
        if (search + width > m1) {
            search += width;
        } else if (search + 1 > m1) {
            search += 1;
        } else {
            search = m1;
        }
    }
    try out.appendSlice(gpa, s[last_end..]);
    return out.items;
}

pub fn matches(gpa: std.mem.Allocator, p: *const Program, s: []const u8) !bool {
    return (try find(gpa, p, s, 0)) != null;
}
