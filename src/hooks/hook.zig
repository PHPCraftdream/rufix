//! Claude Code hook contract: returns the exit code,
//! 0 or 2; on 2 nothing is written to stdout.
const std = @import("std");
const json = @import("../core/json.zig");
const engine = @import("../core/engine.zig");

pub const Output = struct {
    stdout: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,
};

pub const Request = struct {
    event: []const u8 = "",
    tool: []const u8 = "",
    cwd: []const u8 = "",
    input: json.Value = .null,
    response: json.Value = .null,
};

fn foldEql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

pub fn decodeRequest(a: std.mem.Allocator, stdin: []const u8) !Request {
    const v = try json.parseFirst(a, stdin);
    var req = Request{};
    switch (v) {
        .null => return req,
        .object => |obj| {
            // Go matches struct fields case-insensitively; the last one wins.
            for (obj.keys.items, obj.vals.items) |k, val| {
                if (foldEql(k, "hook_event_name")) {
                    req.event = try stringField(val);
                } else if (foldEql(k, "tool_name")) {
                    req.tool = try stringField(val);
                } else if (foldEql(k, "cwd")) {
                    req.cwd = try stringField(val);
                } else if (foldEql(k, "tool_input")) {
                    req.input = val;
                } else if (foldEql(k, "tool_response")) {
                    req.response = val;
                }
            }
            return req;
        },
        else => return error.SyntaxError,
    }
}

fn stringField(v: json.Value) ![]const u8 {
    return switch (v) {
        .null => "",
        .string => |s| s,
        else => error.SyntaxError,
    };
}

const Mode = enum { redact, restore, restore_domains };

fn apply(st: *engine.Store, mode: Mode, s: []const u8) !engine.Store.Result {
    return switch (mode) {
        .redact => st.redact(s),
        .restore => st.restore(s),
        .restore_domains => st.restoreDomains(s),
    };
}

/// Rewrites every string value in place; with keys, object keys too.
fn mapStrings(a: std.mem.Allocator, st: *engine.Store, v: *json.Value, mode: Mode, keys: bool, n: *usize) !void {
    switch (v.*) {
        .string => |s| {
            const r = try apply(st, mode, s);
            n.* += r.count;
            v.* = .{ .string = r.out };
        },
        .array => |arr| for (arr.items.items) |*item| try mapStrings(a, st, item, mode, keys, n),
        .object => |obj| {
            if (keys) {
                const fresh = try json.newObject(a);
                for (obj.keys.items, obj.vals.items) |k, val| {
                    const r = try st.redact(k);
                    if (fresh.index(r.out) != null) return error.KeyCollision;
                    n.* += r.count;
                    try fresh.keys.append(a, r.out);
                    try fresh.vals.append(a, val);
                }
                v.* = .{ .object = fresh };
            }
            for (v.object.vals.items) |*item| try mapStrings(a, st, item, mode, keys, n);
        },
        else => {},
    }
}

fn anyString(st: *engine.Store, v: json.Value, comptime pred: fn (*engine.Store, []const u8) anyerror!bool) !bool {
    switch (v) {
        .string => |s| return pred(st, s),
        .array => |arr| {
            for (arr.items.items) |item| if (try anyString(st, item, pred)) return true;
            return false;
        },
        .object => |obj| {
            for (obj.vals.items) |item| if (try anyString(st, item, pred)) return true;
            return false;
        },
        else => return false,
    }
}

fn hostPred(st: *engine.Store, s: []const u8) anyerror!bool {
    return st.hostPlaceholder(s);
}

fn maskPred(st: *engine.Store, s: []const u8) anyerror!bool {
    return st.hasDomainMask(s);
}

const local_tools = [_][]const u8{ "Write", "Edit", "MultiEdit", "NotebookEdit", "Read", "Grep", "Glob" };

fn isLocalTool(name: []const u8) bool {
    for (local_tools) |t| if (std.mem.eql(u8, t, name)) return true;
    return false;
}

fn emit(a: std.mem.Allocator, out: *Output, event: []const u8, field: []const u8, v: json.Value) !void {
    const inner = try json.newObject(a);
    try inner.put(a, "hookEventName", .{ .string = event });
    try inner.put(a, field, v);
    const outer = try json.newObject(a);
    try outer.put(a, "hookSpecificOutput", .{ .object = inner });
    try json.write(a, &out.stdout, .{ .object = outer }, 0, 0);
    try out.stdout.append(a, '\n');
}

pub fn blocking(a: std.mem.Allocator, out: *Output, msg: []const u8) u8 {
    out.stdout.clearRetainingCapacity();
    out.stderr.appendSlice(a, "rufix: blocking error: ") catch {};
    out.stderr.appendSlice(a, msg) catch {};
    out.stderr.append(a, '\n') catch {};
    return 2;
}

pub fn run(a: std.mem.Allocator, st: *engine.Store, stdin: []const u8, out: *Output) u8 {
    const req = decodeRequest(a, stdin) catch |err| return blocking(a, out, @errorName(err));
    return handle(a, st, req, out);
}

/// Runs a decoded request; the CLI decodes first to learn the cwd for
/// env-file resolution, as Go's hook does.
pub fn handle(a: std.mem.Allocator, st: *engine.Store, req: Request, out: *Output) u8 {
    return handleInner(a, st, req, out) catch |err| blocking(a, out, @errorName(err));
}

fn note(a: std.mem.Allocator, out: *Output, comptime fmt: []const u8, args: anytype) void {
    const line = std.fmt.allocPrint(a, fmt, args) catch return;
    out.stderr.appendSlice(a, line) catch {};
}

fn handleInner(a: std.mem.Allocator, st: *engine.Store, request: Request, out: *Output) !u8 {
    var req = request;
    if (std.mem.eql(u8, req.event, "PostToolUse")) {
        var n: usize = 0;
        const mcp = std.mem.startsWith(u8, req.tool, "mcp__");
        try mapStrings(a, st, &req.response, .redact, mcp, &n);
        if (n == 0) return 0;
        try emit(a, out, "PostToolUse", if (mcp) "updatedMCPToolOutput" else "updatedToolOutput", req.response);
        note(a, out, "rufix: redacted {d} occurrence(s) in {s}\n", .{ n, req.tool });
        return 0;
    }
    if (!std.mem.eql(u8, req.event, "PreToolUse")) return 0;
    if (req.input != .object) return 0;
    var mode: Mode = .restore;
    if (std.mem.eql(u8, req.tool, "Bash")) {
        const cmd = req.input.object.get("command") orelse return 0;
        if (cmd != .string or !try st.hostPlaceholder(cmd.string)) return 0;
    } else if (isLocalTool(req.tool)) {
        if (!try anyString(st, req.input, hostPred)) return 0;
    } else if (std.mem.startsWith(u8, req.tool, "mcp__")) {
        if (!try anyString(st, req.input, maskPred)) return 0;
        mode = .restore_domains;
    } else return 0;
    var n: usize = 0;
    try mapStrings(a, st, &req.input, mode, false, &n);
    if (n == 0) return 0;
    try emit(a, out, "PreToolUse", "updatedInput", req.input);
    const verb = if (mode == .restore_domains) "restored domain masks in" else "restored";
    note(a, out, "rufix: {s} {d} placeholder(s) in {s}\n", .{ verb, n, req.tool });
    return 0;
}
