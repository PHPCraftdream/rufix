//! Replacement templates, as regexp.Regexp.expand reads them.
const std = @import("std");
const vm = @import("../vm.zig");
const Error = @import("parse.zig").Error;

// ---------- replacement templates (regexp.Regexp.expand) ----------

fn isNameRune(r: u32) bool {
    if (r < 0x80) return std.ascii.isAlphanumeric(@intCast(r)) or r == '_';
    // Non-ASCII: letters and digits count in Go; treat cased or CJK as letters.
    return true;
}

pub fn parseTemplate(a: std.mem.Allocator, t_in: []const u8, names: []const []const u8) Error![]const vm.Segment {
    var segs: std.ArrayList(vm.Segment) = .empty;
    var text: std.ArrayList(u8) = .empty;
    const flush = struct {
        fn f(al: std.mem.Allocator, s: *std.ArrayList(vm.Segment), tx: *std.ArrayList(u8)) !void {
            if (tx.items.len == 0) return;
            try s.append(al, .{ .text = try al.dupe(u8, tx.items) });
            tx.clearRetainingCapacity();
        }
    }.f;
    var t = t_in;
    while (t.len > 0) {
        const d = std.mem.indexOfScalar(u8, t, '$') orelse break;
        try text.appendSlice(a, t[0..d]);
        t = t[d + 1 ..];
        if (t.len > 0 and t[0] == '$') {
            try text.append(a, '$');
            t = t[1..];
            continue;
        }
        // extract
        var str = t;
        var brace = false;
        if (str.len > 0 and str[0] == '{') {
            brace = true;
            str = str[1..];
        }
        var i: usize = 0;
        while (i < str.len) {
            const dr = vm.decode(str, i);
            if (!isNameRune(dr.r)) break;
            i += dr.w;
        }
        var ok = i > 0;
        const name = str[0..i];
        if (ok and brace) {
            if (i >= str.len or str[i] != '}') ok = false else i += 1;
        }
        if (!ok) {
            try text.append(a, '$');
            continue;
        }
        t = str[i..];
        var num: i64 = 0;
        for (name) |ch| {
            if (ch < '0' or ch > '9' or num >= 100_000_000) {
                num = -1;
                break;
            }
            num = num * 10 + (ch - '0');
        }
        if (name[0] == '0' and name.len > 1) num = -1;
        if (num >= 0) {
            if (num < names.len) {
                try flush(a, &segs, &text);
                try segs.append(a, .{ .group = @intCast(num) });
            }
        } else {
            var groups: std.ArrayList(u32) = .empty;
            for (names, 0..) |n, gi| {
                if (gi > 0 and std.mem.eql(u8, n, name)) try groups.append(a, @intCast(gi));
            }
            if (groups.items.len > 0) {
                try flush(a, &segs, &text);
                try segs.append(a, .{ .named = groups.items });
            }
        }
    }
    try text.appendSlice(a, t);
    try flush(a, &segs, &text);
    return segs.items;
}

