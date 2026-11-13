//! Compiles the parse tree into a vm.Program the way Go's compiler does.
const std = @import("std");
const vm = @import("../vm.zig");
const parse = @import("parse.zig");
const Node = parse.Node;
const Error = parse.Error;
const Compiled = parse.Compiled;

// ---------- compiler ----------

fn nullable(n: *const Node) bool {
    return switch (n.*) {
        .empty, .assert => true,
        .class => false,
        .cap => |x| nullable(x.sub),
        .cat => |items| for (items) |i| {
            if (!nullable(i)) break false;
        } else true,
        .alt => |items| for (items) |i| {
            if (nullable(i)) break true;
        } else false,
        .rep => |x| x.min == 0 or nullable(x.sub),
    };
}

const Compiler = struct {
    a: std.mem.Allocator,
    insts: std.ArrayList(vm.Inst) = .empty,

    /// Greedy prefers the body, lazy prefers to leave.
    fn choice(_: *Compiler, greedy: bool, body: u32, next: u32) vm.Inst {
        return if (greedy) .{ .op = .alt, .out = body, .arg = next } else .{ .op = .alt, .out = next, .arg = body };
    }

    fn emit(c: *Compiler, in: vm.Inst) !u32 {
        try c.insts.append(c.a, in);
        return @intCast(c.insts.items.len - 1);
    }

    /// Compiles n so that it continues at next; returns the entry pc.
    fn compile(c: *Compiler, n: *const Node, next: u32) Error!u32 {
        switch (n.*) {
            .empty => return next,
            .class => |r| return c.emit(.{ .op = .rune, .out = next, .ranges = r }),
            .assert => |f| return c.emit(.{ .op = .empty, .out = next, .arg = f }),
            .cap => |x| {
                const close = try c.emit(.{ .op = .cap, .out = next, .arg = 2 * x.index + 1 });
                const body = try c.compile(x.sub, close);
                return c.emit(.{ .op = .cap, .out = body, .arg = 2 * x.index });
            },
            .cat => |items| {
                var pc = next;
                var i = items.len;
                while (i > 0) {
                    i -= 1;
                    pc = try c.compile(items[i], pc);
                }
                return pc;
            },
            .alt => |branches| {
                var pc = try c.compile(branches[branches.len - 1], next);
                var i = branches.len - 1;
                while (i > 0) {
                    i -= 1;
                    const b = try c.compile(branches[i], next);
                    pc = try c.emit(.{ .op = .alt, .out = b, .arg = pc });
                }
                return pc;
            },
            .rep => |x| {
                var pc = next;
                if (x.max) |max| {
                    // Optional copies, innermost first: x{n,m} = x^n (x(x(...)?)?)?
                    var k = max - x.min;
                    while (k > 0) : (k -= 1) {
                        const body = try c.compile(x.sub, pc);
                        pc = try c.emit(if (x.greedy)
                            .{ .op = .alt, .out = body, .arg = next }
                        else
                            .{ .op = .alt, .out = next, .arg = body });
                        // Each nested optional falls through to next when skipped.
                    }
                } else {
                    // As Go: x+ is one copy of x looping back to its own entry;
                    // x* is a loop, but (x+)? when x can match empty (so an
                    // empty iteration still records its captures); x{n,} is
                    // x^(n-1) x+.
                    if (x.min == 0 and !nullable(x.sub)) {
                        const loop = try c.emit(.{ .op = .alt });
                        const body = try c.compile(x.sub, loop);
                        c.insts.items[loop] = c.choice(x.greedy, body, next);
                        return loop;
                    }
                    const back = try c.emit(.{ .op = .alt });
                    const body = try c.compile(x.sub, back);
                    c.insts.items[back] = c.choice(x.greedy, body, next);
                    pc = body;
                    if (x.min == 0) return c.emit(c.choice(x.greedy, body, next));
                    var k = x.min - 1;
                    while (k > 0) : (k -= 1) pc = try c.compile(x.sub, pc);
                    return pc;
                }
                var k = x.min;
                while (k > 0) : (k -= 1) pc = try c.compile(x.sub, pc);
                return pc;
            },
        }
    }
};

pub fn compile(a: std.mem.Allocator, pattern: []const u8) Error!Compiled {
    var p = parse.Parser{ .a = a, .s = pattern };
    const root = try p.alternation();
    if (!p.eof()) return error.InvalidRegex; // unmatched ')'
    var c = Compiler{ .a = a };
    const match = try c.emit(.{ .op = .match });
    const start = try c.compile(root, match);
    var names: std.ArrayList([]const u8) = .empty;
    try names.append(a, "");
    try names.appendSlice(a, p.names.items);
    return .{
        .program = .{ .start = start, .num_cap = 2 * (p.ncap + 1), .insts = c.insts.items },
        .names = names.items,
    };
}

