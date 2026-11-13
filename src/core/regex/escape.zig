//! Escapes, Perl and POSIX classes and bracket classes for the parser.
const std = @import("std");
const parse = @import("parse.zig");
const fold = @import("fold.zig");
const Parser = parse.Parser;
const Node = parse.Node;
const Error = parse.Error;
const Set = fold.Set;
const negate = fold.negate;
const foldRanges = fold.foldRanges;
const addFolded = fold.addFolded;
const max_rune = parse.max_rune;

pub fn perlClass(set: *Set, c: u8) !bool {
    switch (std.ascii.toLower(c)) {
        'd' => try set.add('0', '9'),
        's' => {
            try set.add('\t', '\n');
            try set.add(12, '\r');
            try set.add(' ', ' ');
        },
        'w' => {
            try set.add('0', '9');
            try set.add('A', 'Z');
            try set.add('_', '_');
            try set.add('a', 'z');
        },
        else => return false,
    }
    return true;
}

/// \d \s \w and their negations; folded first under (?i), as Go does.

pub fn perlRanges(p: *Parser, c: u8) Error![]const u32 {
    var set = Set{ .a = p.a };
    _ = try perlClass(&set, c);
    var r = try set.finish();
    if (p.flags.fold) r = try foldRanges(p.a, r);
    if (std.ascii.isUpper(c)) r = try negate(p.a, r);
    return r;
}


pub fn escapeRune(p: *Parser) Error!u32 {
    // After the backslash; returns a literal rune.
    const c = p.s[p.i];
    p.i += 1;
    switch (c) {
        'a' => return 7,
        'f' => return 12,
        't' => return '\t',
        'n' => return '\n',
        'r' => return '\r',
        'v' => return 11,
        'x' => {
            if (p.eof()) return error.InvalidRegex;
            if (p.peek() == '{') {
                p.i += 1;
                const start = p.i;
                while (!p.eof() and p.peek() != '}') p.i += 1;
                if (p.eof() or p.i == start) return error.InvalidRegex;
                const v = std.fmt.parseInt(u32, p.s[start..p.i], 16) catch return error.InvalidRegex;
                p.i += 1;
                if (v > max_rune) return error.InvalidRegex;
                return v;
            }
            if (p.i + 2 > p.s.len) return error.InvalidRegex;
            const v = std.fmt.parseInt(u32, p.s[p.i .. p.i + 2], 16) catch return error.InvalidRegex;
            p.i += 2;
            return v;
        },
        '1'...'7', '0' => {
            // A single non-zero digit would be a backreference (unsupported).
            if (c != '0' and (p.eof() or p.peek() < '0' or p.peek() > '7')) return error.InvalidRegex;
            var v: u32 = c - '0';
            var n: usize = 1;
            while (n < 3 and !p.eof() and p.peek() >= '0' and p.peek() <= '7') : (n += 1) {
                v = v * 8 + (p.peek() - '0');
                p.i += 1;
            }
            return v;
        },
        else => {
            if (c < 0x80 and !std.ascii.isAlphanumeric(c)) return c;
            return error.InvalidRegex;
        },
    }
}


pub fn escape(p: *Parser) Error!*Node {
    p.i += 1;
    if (p.eof()) return error.InvalidRegex;
    const c = p.peek();
    switch (c) {
        'A' => {
            p.i += 1;
            return p.node(.{ .assert = 4 });
        },
        'z' => {
            p.i += 1;
            return p.node(.{ .assert = 8 });
        },
        'b' => {
            p.i += 1;
            return p.node(.{ .assert = 16 });
        },
        'B' => {
            p.i += 1;
            return p.node(.{ .assert = 32 });
        },
        'Q' => {
            p.i += 1;
            const end = std.mem.indexOfPos(u8, p.s, p.i, "\\E") orelse p.s.len;
            var items: std.ArrayList(*Node) = .empty;
            while (p.i < end) try items.append(p.a, try p.literal(try p.rune()));
            p.i = @min(end + 2, p.s.len);
            if (items.items.len == 0) return p.node(.empty);
            if (items.items.len == 1) return items.items[0];
            return p.node(.{ .cat = items.items });
        },
        'd', 'D', 's', 'S', 'w', 'W' => {
            p.i += 1;
            return p.node(.{ .class = try perlRanges(p, c) });
        },
        'p', 'P' => return error.InvalidRegex,
        else => return p.literal(try escapeRune(p)),
    }
}


pub fn posix(name: []const u8, set: *Set) !bool {
    const eq = std.mem.eql;
    if (eq(u8, name, "alnum")) {
        try set.add('0', '9');
        try set.add('A', 'Z');
        try set.add('a', 'z');
    } else if (eq(u8, name, "alpha")) {
        try set.add('A', 'Z');
        try set.add('a', 'z');
    } else if (eq(u8, name, "ascii")) {
        try set.add(0, 0x7F);
    } else if (eq(u8, name, "blank")) {
        try set.add('\t', '\t');
        try set.add(' ', ' ');
    } else if (eq(u8, name, "cntrl")) {
        try set.add(0, 0x1F);
        try set.add(0x7F, 0x7F);
    } else if (eq(u8, name, "digit")) {
        try set.add('0', '9');
    } else if (eq(u8, name, "graph")) {
        try set.add('!', '~');
    } else if (eq(u8, name, "lower")) {
        try set.add('a', 'z');
    } else if (eq(u8, name, "print")) {
        try set.add(' ', '~');
    } else if (eq(u8, name, "punct")) {
        try set.add('!', '/');
        try set.add(':', '@');
        try set.add('[', '`');
        try set.add('{', '~');
    } else if (eq(u8, name, "space")) {
        try set.add('\t', '\r');
        try set.add(' ', ' ');
    } else if (eq(u8, name, "upper")) {
        try set.add('A', 'Z');
    } else if (eq(u8, name, "word")) {
        try set.add('0', '9');
        try set.add('A', 'Z');
        try set.add('_', '_');
        try set.add('a', 'z');
    } else if (eq(u8, name, "xdigit")) {
        try set.add('0', '9');
        try set.add('A', 'F');
        try set.add('a', 'f');
    } else return false;
    return true;
}


pub fn class(p: *Parser) Error!*Node {
    p.i += 1;
    var neg = false;
    if (!p.eof() and p.peek() == '^') {
        neg = true;
        p.i += 1;
    }
    var set = Set{ .a = p.a };
    var first = true;
    while (true) {
        if (p.eof()) return error.InvalidRegex;
        const c = p.peek();
        if (c == ']' and !first) {
            p.i += 1;
            break;
        }
        // POSIX class [:name:] / [:^name:]
        if (c == '[' and p.i + 1 < p.s.len and p.s[p.i + 1] == ':') {
            if (std.mem.indexOfPos(u8, p.s, p.i + 2, ":]")) |end| {
                var name = p.s[p.i + 2 .. end];
                var pneg = false;
                if (name.len > 0 and name[0] == '^') {
                    pneg = true;
                    name = name[1..];
                }
                var sub = Set{ .a = p.a };
                if (!(try posix(name, &sub))) return error.InvalidRegex;
                var r = try sub.finish();
                // Go folds a group first, then negates it.
                if (p.flags.fold) r = try foldRanges(p.a, r);
                if (pneg) r = try negate(p.a, r);
                var i: usize = 0;
                while (i + 1 < r.len) : (i += 2) try set.add(r[i], r[i + 1]);
                p.i = end + 2;
                first = false;
                continue;
            }
        }
        if (c == '\\' and p.i + 1 < p.s.len) {
            const e = p.s[p.i + 1];
            if (e == 'd' or e == 'D' or e == 's' or e == 'S' or e == 'w' or e == 'W') {
                p.i += 2;
                const r = try perlRanges(p, e);
                var i: usize = 0;
                while (i + 1 < r.len) : (i += 2) try set.add(r[i], r[i + 1]);
                first = false;
                continue;
            }
            if (e == 'p' or e == 'P') return error.InvalidRegex;
        }
        const lo = try classRune(p);
        var hi = lo;
        if (p.i + 1 < p.s.len and p.peek() == '-' and p.s[p.i + 1] != ']') {
            p.i += 1;
            hi = try classRune(p);
            if (hi < lo) return error.InvalidRegex;
        }
        try addClassRange(p, &set, lo, hi);
        first = false;
    }
    var r = try set.finish();
    if (neg) r = try negate(p.a, r);
    return p.node(.{ .class = r });
}


pub fn classRune(p: *Parser) Error!u32 {
    if (p.eof()) return error.InvalidRegex;
    if (p.peek() == '\\') {
        p.i += 1;
        if (p.eof()) return error.InvalidRegex;
        return escapeRune(p);
    }
    return p.rune();
}


pub fn addClassRange(p: *Parser, set: *Set, lo: u32, hi: u32) Error!void {
    if (p.flags.fold) return addFolded(set, lo, hi);
    try set.add(lo, hi);
}
