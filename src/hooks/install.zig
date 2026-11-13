//! settings.json merge: install, uninstall,
//! status. Returns the summary line or an error.
const std = @import("std");
const builtin = @import("builtin");
const json = @import("../core/json.zig");
const io = @import("../platform/io.zig");
const os = @import("../platform/os.zig");

pub const Options = struct {
    path: []const u8,
    exe_dir: []const u8,
    env_files: bool = false,
};

const Entry = struct { event: []const u8, matcher: []const u8, timeout: []const u8 };

const pre_matcher = "^(Bash|Write|Edit|MultiEdit|NotebookEdit|Read|Grep|Glob)$|^mcp__";

const entries = [_]Entry{
    .{ .event = "PostToolUse", .matcher = "", .timeout = "30" },
    .{ .event = "PreToolUse", .matcher = pre_matcher, .timeout = "10" },
};

/// Go strconv.Quote for the paths this tool writes.
fn quote(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '"');
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c >= 0x80) {
            const len = std.unicode.utf8ByteSequenceLength(c) catch 0;
            if (len > 0 and i + len <= s.len and (std.unicode.utf8ValidateSlice(s[i .. i + len]))) {
                try out.appendSlice(a, s[i .. i + len]);
                i += len;
                continue;
            }
        }
        switch (c) {
            '"' => try out.appendSlice(a, "\\\""),
            '\\' => try out.appendSlice(a, "\\\\"),
            7 => try out.appendSlice(a, "\\a"),
            8 => try out.appendSlice(a, "\\b"),
            12 => try out.appendSlice(a, "\\f"),
            '\n' => try out.appendSlice(a, "\\n"),
            '\r' => try out.appendSlice(a, "\\r"),
            '\t' => try out.appendSlice(a, "\\t"),
            11 => try out.appendSlice(a, "\\v"),
            0x20...0x21, 0x23...0x5b, 0x5d...0x7e => try out.append(a, c),
            else => {
                const hex = "0123456789abcdef";
                try out.appendSlice(a, "\\x");
                try out.append(a, hex[c >> 4]);
                try out.append(a, hex[c & 15]);
            },
        }
        i += 1;
    }
    try out.append(a, '"');
    return out.items;
}

/// Inverse of quote for the escapes it produces.
fn unquote(a: std.mem.Allocator, q: []const u8) !?[]const u8 {
    if (q.len < 2 or q[0] != '"' or q[q.len - 1] != '"') return null;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 1;
    while (i < q.len - 1) {
        const c = q[i];
        if (c == '"') return null;
        if (c != '\\') {
            try out.append(a, c);
            i += 1;
            continue;
        }
        if (i + 1 >= q.len - 1) return null;
        const e = q[i + 1];
        i += 2;
        switch (e) {
            '"' => try out.append(a, '"'),
            '\\' => try out.append(a, '\\'),
            'a' => try out.append(a, 7),
            'b' => try out.append(a, 8),
            'f' => try out.append(a, 12),
            'n' => try out.append(a, '\n'),
            'r' => try out.append(a, '\r'),
            't' => try out.append(a, '\t'),
            'v' => try out.append(a, 11),
            'x' => {
                if (i + 2 > q.len - 1) return null;
                const v = std.fmt.parseInt(u8, q[i .. i + 2], 16) catch return null;
                try out.append(a, v);
                i += 2;
            },
            else => return null,
        }
    }
    return out.items;
}

fn toSlash(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (builtin.os.tag != .windows) return s;
    const out = try a.dupe(u8, s);
    std.mem.replaceScalar(u8, out, '\\', '/');
    return out;
}

fn command(a: std.mem.Allocator, exe_dir: []const u8, env_files: bool) ![]const u8 {
    var cmd: []const u8 = "rufix hook";
    if (exe_dir.len > 0) {
        var dir = try toSlash(a, exe_dir);
        while (dir.len > 1 and dir[dir.len - 1] == '/') dir = dir[0 .. dir.len - 1];
        const exe = if (dir.len == 1 and dir[0] == '/') "/rufix" else try std.mem.concat(a, u8, &.{ dir, "/rufix" });
        cmd = try std.mem.concat(a, u8, &.{ try quote(a, exe), " hook" });
    }
    if (env_files) cmd = try std.mem.concat(a, u8, &.{ cmd, " --env-files" });
    return cmd;
}

fn baseName(p: []const u8) []const u8 {
    var s = p;
    while (s.len > 1 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
    if (s.len == 0) return ".";
    if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| {
        if (s.len > 1) return s[i + 1 ..];
    }
    return s;
}

/// Exactly the commands install writes: an executable named rufix or
/// rufix.exe (optionally quoted), then `hook`, optionally `--env-files`.
pub fn isRufixCommand(a: std.mem.Allocator, raw: []const u8) !bool {
    const cmd = std.mem.trim(u8, raw, " \t\r\n\x0b\x0c");
    var exe: []const u8 = undefined;
    var rest: []const u8 = undefined;
    if (cmd.len > 0 and cmd[0] == '"') {
        var end: usize = 1;
        while (end < cmd.len and cmd[end] != '"') {
            if (cmd[end] == '\\') end += 1;
            end += 1;
        }
        if (end >= cmd.len) return false;
        exe = (try unquote(a, cmd[0 .. end + 1])) orelse return false;
        rest = cmd[end + 1 ..];
    } else {
        if (std.mem.indexOfScalar(u8, cmd, ' ')) |i| {
            exe = cmd[0..i];
            rest = cmd[i..];
        } else {
            exe = cmd;
            rest = " ";
        }
    }
    if (rest.len == 0 or rest[0] != ' ') return false;
    const name = try std.ascii.allocLowerString(a, baseName(try toSlash(a, exe)));
    if (!std.mem.eql(u8, name, "rufix") and !std.mem.eql(u8, name, "rufix.exe")) return false;
    var args: [3][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, rest, " \t\r\n\x0b\x0c");
    while (it.next()) |tok| {
        if (n == args.len) return false;
        args[n] = tok;
        n += 1;
    }
    if (n == 1) return std.mem.eql(u8, args[0], "hook");
    if (n == 2) return std.mem.eql(u8, args[0], "hook") and std.mem.eql(u8, args[1], "--env-files");
    return false;
}

fn rufixEntry(a: std.mem.Allocator, item: json.Value) !bool {
    if (item != .object) return false;
    const inner = item.object.get("hooks") orelse return false;
    if (inner != .array) return false;
    for (inner.array.items.items) |h| {
        if (h != .object) continue;
        const cmd = h.object.get("command") orelse continue;
        if (cmd == .string and try isRufixCommand(a, cmd.string)) return true;
    }
    return false;
}

fn load(a: std.mem.Allocator, path: []const u8) !*json.Object {
    const data = (try io.readFile(a, path)) orelse return json.newObject(a);
    const v = try json.parseFirst(a, data);
    return switch (v) {
        .object => |o| o,
        .null => json.newObject(a),
        else => error.SyntaxError,
    };
}

fn save(a: std.mem.Allocator, path: []const u8, settings: *json.Object) !void {
    var out: std.ArrayList(u8) = .empty;
    try json.write(a, &out, .{ .object = settings }, 2, 0);
    try out.append(a, '\n');
    try os.mkdirAll(a, os.dir(path));
    try io.writeFileAtomic(a, path, out.items);
}

pub fn install(a: std.mem.Allocator, o: Options) ![]const u8 {
    const settings = try load(a, o.path);
    var hooks: *json.Object = undefined;
    if (settings.get("hooks")) |h| switch (h) {
        .object => |obj| hooks = obj,
        .null => {
            hooks = try json.newObject(a);
            try settings.put(a, "hooks", .{ .object = hooks });
        },
        else => return error.HooksNotAnObject,
    } else {
        hooks = try json.newObject(a);
        try settings.put(a, "hooks", .{ .object = hooks });
    }
    // Validate every event list before changing anything.
    for (entries) |e| {
        if (hooks.get(e.event)) |v| switch (v) {
            .array, .null => {},
            else => return error.EventNotAList,
        };
    }
    var replaced: usize = 0;
    const cmd = try command(a, o.exe_dir, o.env_files);
    for (entries) |e| {
        const list = try json.newArray(a);
        if (hooks.get(e.event)) |v| if (v == .array) {
            for (v.array.items.items) |item| {
                if (try rufixEntry(a, item)) {
                    replaced += 1;
                } else try list.items.append(a, item);
            }
        };
        const hook = try json.newObject(a);
        try hook.put(a, "type", .{ .string = "command" });
        try hook.put(a, "command", .{ .string = cmd });
        try hook.put(a, "timeout", .{ .number = e.timeout });
        try hook.put(a, "onFailure", .{ .string = "block" });
        const hooks_list = try json.newArray(a);
        try hooks_list.items.append(a, .{ .object = hook });
        const entry = try json.newObject(a);
        try entry.put(a, "matcher", .{ .string = e.matcher });
        try entry.put(a, "hooks", .{ .array = hooks_list });
        try list.items.append(a, .{ .object = entry });
        try hooks.put(a, e.event, .{ .array = list });
    }
    try save(a, o.path, settings);
    if (replaced > 0) return std.fmt.allocPrint(a, "reinstalled {d} hook entr(y/ies) in {s}", .{ replaced, o.path });
    return std.fmt.allocPrint(a, "installed {d} hook entr(y/ies) in {s}", .{ entries.len, o.path });
}

pub fn uninstall(a: std.mem.Allocator, o: Options) ![]const u8 {
    const settings = try load(a, o.path);
    const hv = settings.get("hooks") orelse return "no hooks section";
    if (hv != .object) return "no hooks section";
    const hooks = hv.object;
    var removed: usize = 0;
    var i: usize = 0;
    while (i < hooks.keys.items.len) {
        const v = hooks.vals.items[i];
        if (v != .array) {
            i += 1;
            continue;
        }
        const kept = try json.newArray(a);
        for (v.array.items.items) |item| {
            if (try rufixEntry(a, item)) removed += 1 else try kept.items.append(a, item);
        }
        if (kept.items.items.len == 0) {
            _ = hooks.keys.orderedRemove(i);
            _ = hooks.vals.orderedRemove(i);
            continue;
        }
        hooks.vals.items[i] = .{ .array = kept };
        i += 1;
    }
    if (hooks.keys.items.len == 0) settings.remove("hooks");
    if (removed == 0) return "no rufix entries found";
    try save(a, o.path, settings);
    return std.fmt.allocPrint(a, "removed {d} hook entr(y/ies) from {s}", .{ removed, o.path });
}

pub fn status(a: std.mem.Allocator, o: Options) ![]const u8 {
    const settings = try load(a, o.path);
    const hv = settings.get("hooks") orelse return "not installed (no hooks section)";
    if (hv != .object) return "not installed (no hooks section)";
    const hooks = hv.object;
    var events: std.ArrayList([]const u8) = .empty;
    var problems: std.ArrayList([]const u8) = .empty;
    const base = try command(a, o.exe_dir, false);
    for (entries) |e| {
        var found: std.ArrayList(json.Value) = .empty;
        if (hooks.get(e.event)) |v| if (v == .array) {
            for (v.array.items.items) |item| if (try rufixEntry(a, item)) try found.append(a, item);
        };
        switch (found.items.len) {
            0 => try problems.append(a, try std.mem.concat(a, u8, &.{ e.event, " missing" })),
            1 => {
                try events.append(a, e.event);
                try entryProblems(a, e, found.items[0], base, &problems);
            },
            else => {
                try events.append(a, e.event);
                try problems.append(a, try std.mem.concat(a, u8, &.{ e.event, " duplicated" }));
            },
        }
    }
    if (events.items.len == 0) return "not installed";
    if (problems.items.len > 0) {
        const joined = try std.mem.join(a, ", ", problems.items);
        return std.mem.concat(a, u8, &.{ "stale: ", joined, "; re-run rufix install" });
    }
    return std.mem.concat(a, u8, &.{ "installed: ", try std.mem.join(a, ", ", events.items) });
}

fn entryProblems(a: std.mem.Allocator, e: Entry, item: json.Value, base: []const u8, problems: *std.ArrayList([]const u8)) !void {
    const entry = item.object;
    const matcher = entry.get("matcher") orelse json.Value{ .string = "" };
    const m = if (matcher == .string) matcher.string else "";
    if (!std.mem.eql(u8, m, e.matcher)) try problems.append(a, try std.mem.concat(a, u8, &.{ e.event, " matcher outdated" }));
    const inner = entry.get("hooks").?;
    if (inner.array.items.items.len != 1) {
        try problems.append(a, try std.mem.concat(a, u8, &.{ e.event, " hook list changed" }));
        return;
    }
    const h = inner.array.items.items[0];
    const obj: ?*json.Object = if (h == .object) h.object else null;
    const timeout = if (obj) |o| o.get("timeout") else null;
    // Go compares fmt.Sprint of the value, so a string "30" passes too.
    const timeout_ok = if (timeout) |t| switch (t) {
        .number => |n| std.mem.eql(u8, n, e.timeout),
        .string => |s| std.mem.eql(u8, s, e.timeout),
        else => false,
    } else false;
    if (!timeout_ok) try problems.append(a, try std.mem.concat(a, u8, &.{ e.event, " timeout outdated" }));
    const fail = if (obj) |o| o.get("onFailure") else null;
    if (!(fail != null and fail.? == .string and std.mem.eql(u8, fail.?.string, "block")))
        try problems.append(a, try std.mem.concat(a, u8, &.{ e.event, " not fail-closed" }));
    const cmd = if (obj) |o| o.get("command") else null;
    const with_env = try std.mem.concat(a, u8, &.{ base, " --env-files" });
    const cmd_ok = cmd != null and cmd.? == .string and
        (std.mem.eql(u8, cmd.?.string, base) or std.mem.eql(u8, cmd.?.string, with_env));
    if (!cmd_ok) try problems.append(a, try std.mem.concat(a, u8, &.{ e.event, " runs another binary" }));
}
