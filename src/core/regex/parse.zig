//! RE2-syntax parser (the subset Go's regexp accepts with Perl flags):
//! builds the tree compile.zig turns into a vm.Program. Unsupported syntax
//! (Unicode classes, folding outside the built-in tables) is an error.
const std = @import("std");
const vm = @import("../vm.zig");
const fold = @import("fold.zig");
const esc = @import("escape.zig");
const Set = fold.Set;
const negate = fold.negate;
const simpleOrbit = fold.simpleOrbit;
const hasUnknownCase = fold.hasUnknownCase;

pub const Error = error{ InvalidRegex, OutOfMemory };

pub const max_rune: u32 = 0x10FFFF;
pub const max_repeat: u32 = 1000;

pub const Flags = struct {
    fold: bool = false,
    multi: bool = false,
    dotnl: bool = false,
    ungreedy: bool = false,
};

pub const Node = union(enum) {
    empty,
    class: []const u32,
    assert: u32,
    cap: struct { index: u32, sub: *Node },
    cat: []*Node,
    alt: []*Node,
    rep: struct { sub: *Node, min: u32, max: ?u32, greedy: bool },
};

pub const Compiled = struct {
    program: vm.Program,
    names: []const []const u8,
};

pub const Parser = struct {
    a: std.mem.Allocator,
    s: []const u8,
    i: usize = 0,
    flags: Flags = .{},
    ncap: u32 = 0,
    names: std.ArrayList([]const u8) = .empty,

    pub fn node(p: *Parser, n: Node) !*Node {
        const x = try p.a.create(Node);
        x.* = n;
        return x;
    }

    pub fn eof(p: *Parser) bool {
        return p.i >= p.s.len;
    }

    pub fn peek(p: *Parser) u8 {
        return p.s[p.i];
    }

    pub fn rune(p: *Parser) Error!u32 {
        if (p.eof()) return error.InvalidRegex;
        const c = p.s[p.i];
        if (c < 0x80) {
            p.i += 1;
            return c;
        }
        const len = std.unicode.utf8ByteSequenceLength(c) catch return error.InvalidRegex;
        if (p.i + len > p.s.len) return error.InvalidRegex;
        const r = std.unicode.utf8Decode(p.s[p.i .. p.i + len]) catch return error.InvalidRegex;
        p.i += len;
        return r;
    }

    pub fn literal(p: *Parser, r: u32) Error!*Node {
        var set = Set{ .a = p.a };
        if (p.flags.fold) {
            var buf: [4]u32 = undefined;
            if (simpleOrbit(r, &buf)) |orbit| {
                for (orbit) |o| try set.add(o, o);
            } else {
                if (hasUnknownCase(r)) return error.InvalidRegex;
                try set.add(r, r);
            }
        } else try set.add(r, r);
        return p.node(.{ .class = try set.finish() });
    }

    pub fn alternation(p: *Parser) Error!*Node {
        var branches: std.ArrayList(*Node) = .empty;
        try branches.append(p.a, try p.concat());
        while (!p.eof() and p.peek() == '|') {
            p.i += 1;
            try branches.append(p.a, try p.concat());
        }
        if (branches.items.len == 1) return branches.items[0];
        return p.node(.{ .alt = branches.items });
    }

    pub fn concat(p: *Parser) Error!*Node {
        var items: std.ArrayList(*Node) = .empty;
        while (!p.eof() and p.peek() != '|' and p.peek() != ')') {
            const item = try p.atom() orelse continue; // flag-only group
            try items.append(p.a, try p.repeat(item));
        }
        if (items.items.len == 0) return p.node(.empty);
        if (items.items.len == 1) return items.items[0];
        return p.node(.{ .cat = items.items });
    }

    pub fn parseInt(p: *Parser) ?u32 {
        const start = p.i;
        while (!p.eof() and std.ascii.isDigit(p.peek())) p.i += 1;
        if (p.i == start) return null;
        // Go rejects leading zeros only implicitly via the 1000 cap; values are
        // parsed in decimal.
        return std.fmt.parseInt(u32, p.s[start..p.i], 10) catch max_repeat + 1;
    }

    pub fn repeat(p: *Parser, sub: *Node) Error!*Node {
        var cur = sub;
        var count: usize = 0;
        while (!p.eof()) {
            const c = p.peek();
            var min: u32 = 0;
            var max: ?u32 = null;
            const save = p.i;
            switch (c) {
                '*' => p.i += 1,
                '+' => {
                    p.i += 1;
                    min = 1;
                },
                '?' => {
                    p.i += 1;
                    max = 1;
                },
                '{' => {
                    p.i += 1;
                    const lo = p.parseInt() orelse {
                        p.i = save;
                        return cur;
                    };
                    min = lo;
                    max = lo;
                    if (!p.eof() and p.peek() == ',') {
                        p.i += 1;
                        if (!p.eof() and p.peek() == '}') {
                            max = null;
                        } else {
                            max = p.parseInt() orelse {
                                p.i = save;
                                return cur;
                            };
                        }
                    }
                    if (p.eof() or p.peek() != '}') {
                        p.i = save;
                        return cur;
                    }
                    p.i += 1;
                    if (min > max_repeat or (max != null and (max.? > max_repeat or max.? < min))) return error.InvalidRegex;
                },
                else => return cur,
            }
            count += 1;
            if (count > 1) return error.InvalidRegex; // invalid nested repetition operator
            var greedy = true;
            if (!p.eof() and p.peek() == '?') {
                p.i += 1;
                greedy = false;
            }
            if (p.flags.ungreedy) greedy = !greedy;
            if (cur.* == .empty) return error.InvalidRegex;
            cur = try p.node(.{ .rep = .{ .sub = cur, .min = min, .max = max, .greedy = greedy } });
        }
        return cur;
    }

    /// Returns null for a flag-only group like (?i).
    pub fn atom(p: *Parser) Error!?*Node {
        const c = p.peek();
        switch (c) {
            '(' => return p.group(),
            '*', '+', '?' => return error.InvalidRegex,
            '^' => {
                p.i += 1;
                return try p.node(.{ .assert = if (p.flags.multi) 1 else 4 });
            },
            '$' => {
                p.i += 1;
                return try p.node(.{ .assert = if (p.flags.multi) 2 else 8 });
            },
            '.' => {
                p.i += 1;
                var set = Set{ .a = p.a };
                if (p.flags.dotnl) {
                    try set.add(0, max_rune);
                } else {
                    try set.add(0, '\n' - 1);
                    try set.add('\n' + 1, max_rune);
                }
                return try p.node(.{ .class = try set.finish() });
            },
            '[' => return try esc.class(p),
            '\\' => return try esc.escape(p),
            else => return try p.literal(try p.rune()),
        }
    }

    pub fn group(p: *Parser) Error!?*Node {
        p.i += 1;
        const saved = p.flags;
        var name: ?[]const u8 = null;
        var capture = true;
        if (!p.eof() and p.peek() == '?') {
            p.i += 1;
            if (std.mem.startsWith(u8, p.s[p.i..], "P<") or (!p.eof() and p.peek() == '<')) {
                p.i += if (p.peek() == 'P') 2 else 1;
                const start = p.i;
                while (!p.eof() and p.peek() != '>') p.i += 1;
                if (p.eof()) return error.InvalidRegex;
                const n = p.s[start..p.i];
                p.i += 1;
                if (n.len == 0) return error.InvalidRegex;
                for (n) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return error.InvalidRegex;
                name = n;
            } else {
                // Flags: (?flags) or (?flags:re)
                var neg = false;
                var any = false;
                var f = p.flags;
                while (true) {
                    if (p.eof()) return error.InvalidRegex;
                    const ch = p.peek();
                    p.i += 1;
                    switch (ch) {
                        'i' => f.fold = !neg,
                        'm' => f.multi = !neg,
                        's' => f.dotnl = !neg,
                        'U' => f.ungreedy = !neg,
                        '-' => {
                            if (neg) return error.InvalidRegex;
                            neg = true;
                            any = false;
                            continue;
                        },
                        ')' => {
                            if (!any) return error.InvalidRegex;
                            p.flags = f; // persists to the end of the enclosing group
                            return null;
                        },
                        ':' => {
                            if (neg and !any) return error.InvalidRegex;
                            capture = false;
                            p.flags = f;
                            break;
                        },
                        else => return error.InvalidRegex,
                    }
                    any = true;
                }
            }
        }
        var index: u32 = 0;
        if (capture) {
            p.ncap += 1;
            index = p.ncap;
            try p.names.append(p.a, name orelse "");
        }
        const sub = try p.alternation();
        if (p.eof() or p.peek() != ')') return error.InvalidRegex;
        p.i += 1;
        p.flags = saved;
        if (!capture) return sub;
        return try p.node(.{ .cap = .{ .index = index, .sub = sub } });
    }

};
