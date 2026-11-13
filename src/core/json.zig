//! Minimal JSON for the hook contract: numbers stay as their literal text,
//! objects keep insertion order, a duplicate key keeps its first position
//! with the last value (as Go maps decode them).
const std = @import("std");

pub const Value = union(enum) {
    null,
    bool: bool,
    number: []const u8,
    string: []const u8,
    array: *Array,
    object: *Object,
};

pub const Array = struct {
    items: std.ArrayList(Value) = .empty,
};

pub const Object = struct {
    keys: std.ArrayList([]const u8) = .empty,
    vals: std.ArrayList(Value) = .empty,

    pub fn index(self: *const Object, key: []const u8) ?usize {
        for (self.keys.items, 0..) |k, i| {
            if (std.mem.eql(u8, k, key)) return i;
        }
        return null;
    }

    pub fn get(self: *const Object, key: []const u8) ?Value {
        const i = self.index(key) orelse return null;
        return self.vals.items[i];
    }

    pub fn put(self: *Object, a: std.mem.Allocator, key: []const u8, val: Value) !void {
        if (self.index(key)) |i| {
            self.vals.items[i] = val;
            return;
        }
        try self.keys.append(a, key);
        try self.vals.append(a, val);
    }

    pub fn remove(self: *Object, key: []const u8) void {
        const i = self.index(key) orelse return;
        _ = self.keys.orderedRemove(i);
        _ = self.vals.orderedRemove(i);
    }
};

pub fn newObject(a: std.mem.Allocator) !*Object {
    const o = try a.create(Object);
    o.* = .{};
    return o;
}

pub fn newArray(a: std.mem.Allocator) !*Array {
    const arr = try a.create(Array);
    arr.* = .{};
    return arr;
}

pub const Error = error{ SyntaxError, OutOfMemory };

pub const Parser = struct {
    a: std.mem.Allocator,
    s: []const u8,
    i: usize = 0,

    fn ws(p: *Parser) void {
        while (p.i < p.s.len) : (p.i += 1) {
            switch (p.s[p.i]) {
                ' ', '\t', '\n', '\r' => {},
                else => return,
            }
        }
    }

    /// Parses one value; bytes after it are left unread.
    pub fn value(p: *Parser) Error!Value {
        p.ws();
        if (p.i >= p.s.len) return error.SyntaxError;
        const c = p.s[p.i];
        switch (c) {
            '{' => return p.object(),
            '[' => return p.array(),
            '"' => return .{ .string = try p.string() },
            't' => return p.literal("true", .{ .bool = true }),
            'f' => return p.literal("false", .{ .bool = false }),
            'n' => return p.literal("null", .null),
            '-', '0'...'9' => return .{ .number = try p.number() },
            else => return error.SyntaxError,
        }
    }

    fn literal(p: *Parser, word: []const u8, v: Value) Error!Value {
        if (!std.mem.startsWith(u8, p.s[p.i..], word)) return error.SyntaxError;
        p.i += word.len;
        return v;
    }

    fn number(p: *Parser) Error![]const u8 {
        const start = p.i;
        if (p.s[p.i] == '-') p.i += 1;
        if (p.i >= p.s.len) return error.SyntaxError;
        if (p.s[p.i] == '0') {
            p.i += 1;
        } else if (p.s[p.i] >= '1' and p.s[p.i] <= '9') {
            while (p.i < p.s.len and std.ascii.isDigit(p.s[p.i])) p.i += 1;
        } else return error.SyntaxError;
        if (p.i < p.s.len and p.s[p.i] == '.') {
            p.i += 1;
            const d = p.i;
            while (p.i < p.s.len and std.ascii.isDigit(p.s[p.i])) p.i += 1;
            if (p.i == d) return error.SyntaxError;
        }
        if (p.i < p.s.len and (p.s[p.i] == 'e' or p.s[p.i] == 'E')) {
            p.i += 1;
            if (p.i < p.s.len and (p.s[p.i] == '+' or p.s[p.i] == '-')) p.i += 1;
            const d = p.i;
            while (p.i < p.s.len and std.ascii.isDigit(p.s[p.i])) p.i += 1;
            if (p.i == d) return error.SyntaxError;
        }
        return p.s[start..p.i];
    }

    fn hex4(p: *Parser) Error!u21 {
        if (p.i + 4 > p.s.len) return error.SyntaxError;
        const v = std.fmt.parseInt(u16, p.s[p.i .. p.i + 4], 16) catch return error.SyntaxError;
        p.i += 4;
        return v;
    }

    fn string(p: *Parser) Error![]const u8 {
        p.i += 1; // opening quote
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            if (p.i >= p.s.len) return error.SyntaxError;
            const c = p.s[p.i];
            if (c == '"') {
                p.i += 1;
                return out.items;
            }
            if (c < 0x20) return error.SyntaxError;
            if (c == '\\') {
                p.i += 1;
                if (p.i >= p.s.len) return error.SyntaxError;
                const e = p.s[p.i];
                p.i += 1;
                switch (e) {
                    '"' => try out.append(p.a, '"'),
                    '\\' => try out.append(p.a, '\\'),
                    '/' => try out.append(p.a, '/'),
                    'b' => try out.append(p.a, 8),
                    'f' => try out.append(p.a, 12),
                    'n' => try out.append(p.a, '\n'),
                    'r' => try out.append(p.a, '\r'),
                    't' => try out.append(p.a, '\t'),
                    'u' => {
                        var r: u21 = try p.hex4();
                        if (r >= 0xD800 and r < 0xDC00) {
                            // A lone or broken surrogate decodes to U+FFFD, as in Go.
                            if (p.i + 6 <= p.s.len and p.s[p.i] == '\\' and p.s[p.i + 1] == 'u') {
                                const save = p.i;
                                p.i += 2;
                                const lo = try p.hex4();
                                if (lo >= 0xDC00 and lo < 0xE000) {
                                    r = 0x10000 + ((r - 0xD800) << 10) + (lo - 0xDC00);
                                } else {
                                    p.i = save;
                                    r = 0xFFFD;
                                }
                            } else r = 0xFFFD;
                        } else if (r >= 0xDC00 and r < 0xE000) r = 0xFFFD;
                        try appendRune(p.a, &out, r);
                    },
                    else => return error.SyntaxError,
                }
                continue;
            }
            if (c < 0x80) {
                try out.append(p.a, c);
                p.i += 1;
                continue;
            }
            // Invalid UTF-8 decodes to U+FFFD, one byte at a time, as in Go.
            const len = std.unicode.utf8ByteSequenceLength(c) catch {
                try appendRune(p.a, &out, 0xFFFD);
                p.i += 1;
                continue;
            };
            if (p.i + len <= p.s.len) {
                if (std.unicode.utf8Decode(p.s[p.i .. p.i + len])) |_| {
                    try out.appendSlice(p.a, p.s[p.i .. p.i + len]);
                    p.i += len;
                    continue;
                } else |_| {}
            }
            try appendRune(p.a, &out, 0xFFFD);
            p.i += 1;
        }
    }

    fn array(p: *Parser) Error!Value {
        p.i += 1;
        const arr = try newArray(p.a);
        p.ws();
        if (p.i < p.s.len and p.s[p.i] == ']') {
            p.i += 1;
            return .{ .array = arr };
        }
        while (true) {
            try arr.items.append(p.a, try p.value());
            p.ws();
            if (p.i >= p.s.len) return error.SyntaxError;
            if (p.s[p.i] == ',') {
                p.i += 1;
                continue;
            }
            if (p.s[p.i] == ']') {
                p.i += 1;
                return .{ .array = arr };
            }
            return error.SyntaxError;
        }
    }

    fn object(p: *Parser) Error!Value {
        p.i += 1;
        const obj = try newObject(p.a);
        p.ws();
        if (p.i < p.s.len and p.s[p.i] == '}') {
            p.i += 1;
            return .{ .object = obj };
        }
        while (true) {
            p.ws();
            if (p.i >= p.s.len or p.s[p.i] != '"') return error.SyntaxError;
            const key = try p.string();
            p.ws();
            if (p.i >= p.s.len or p.s[p.i] != ':') return error.SyntaxError;
            p.i += 1;
            try obj.put(p.a, key, try p.value());
            p.ws();
            if (p.i >= p.s.len) return error.SyntaxError;
            if (p.s[p.i] == ',') {
                p.i += 1;
                continue;
            }
            if (p.s[p.i] == '}') {
                p.i += 1;
                return .{ .object = obj };
            }
            return error.SyntaxError;
        }
    }
};

pub fn appendRune(a: std.mem.Allocator, out: *std.ArrayList(u8), r: u21) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(r, &buf) catch {
        try out.appendSlice(a, "\xEF\xBF\xBD");
        return;
    };
    try out.appendSlice(a, buf[0..n]);
}

/// Parses the first value of s and ignores what follows, like a Go Decoder.
pub fn parseFirst(a: std.mem.Allocator, s: []const u8) Error!Value {
    var p = Parser{ .a = a, .s = s };
    return p.value();
}

/// Parses s as exactly one value surrounded by optional whitespace.
pub fn parseAll(a: std.mem.Allocator, s: []const u8) Error!Value {
    var p = Parser{ .a = a, .s = s };
    const v = try p.value();
    p.ws();
    if (p.i != s.len) return error.SyntaxError;
    return v;
}

pub fn writeString(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(a, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(a, "\\\""),
            '\\' => try out.appendSlice(a, "\\\\"),
            '\n' => try out.appendSlice(a, "\\n"),
            '\r' => try out.appendSlice(a, "\\r"),
            '\t' => try out.appendSlice(a, "\\t"),
            0...8, 11, 12, 14...0x1f => {
                const hex = "0123456789abcdef";
                try out.appendSlice(a, "\\u00");
                try out.append(a, hex[c >> 4]);
                try out.append(a, hex[c & 15]);
            },
            else => try out.append(a, c),
        }
    }
    try out.append(a, '"');
}

/// Writes v; indent > 0 pretty-prints with that many spaces per level.
pub fn write(a: std.mem.Allocator, out: *std.ArrayList(u8), v: Value, indent: usize, level: usize) !void {
    switch (v) {
        .null => try out.appendSlice(a, "null"),
        .bool => |b| try out.appendSlice(a, if (b) "true" else "false"),
        .number => |n| try out.appendSlice(a, n),
        .string => |s| try writeString(a, out, s),
        .array => |arr| {
            if (arr.items.items.len == 0) return out.appendSlice(a, "[]");
            try out.append(a, '[');
            for (arr.items.items, 0..) |item, i| {
                if (i > 0) try out.append(a, ',');
                try newline(a, out, indent, level + 1);
                try write(a, out, item, indent, level + 1);
            }
            try newline(a, out, indent, level);
            try out.append(a, ']');
        },
        .object => |obj| {
            if (obj.keys.items.len == 0) return out.appendSlice(a, "{}");
            try out.append(a, '{');
            for (obj.keys.items, obj.vals.items, 0..) |k, val, i| {
                if (i > 0) try out.append(a, ',');
                try newline(a, out, indent, level + 1);
                try writeString(a, out, k);
                try out.append(a, ':');
                if (indent > 0) try out.append(a, ' ');
                try write(a, out, val, indent, level + 1);
            }
            try newline(a, out, indent, level);
            try out.append(a, '}');
        },
    }
}

fn newline(a: std.mem.Allocator, out: *std.ArrayList(u8), indent: usize, level: usize) !void {
    if (indent == 0) return;
    try out.append(a, '\n');
    try out.appendNTimes(a, ' ', indent * level);
}
