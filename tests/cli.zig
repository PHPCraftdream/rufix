//! conformance/cli: the built binary (skeleton values) run as a process.
const std = @import("std");
const rufix = @import("rufix");
const build_options = @import("build_options");
const t = @import("support.zig");
const io = rufix.io;
const os = rufix.os;
const json = rufix.json;


const Result = struct { code: u8, stdout: []const u8, stderr: []const u8 };

fn expand(a: std.mem.Allocator, s: []const u8, root_slash: []const u8) ![]const u8 {
    return std.mem.replaceOwned(u8, a, s, "{tmp}", root_slash);
}

fn normalize(a: std.mem.Allocator, s: []const u8, root: []const u8) ![]const u8 {
    var out = try a.dupe(u8, s);
    const slash = try os.toSlash(a, root);
    const escaped = try std.mem.replaceOwned(u8, a, root, "\\", "\\\\");
    for ([_][]const u8{ escaped, root, slash }) |form| out = try std.mem.replaceOwned(u8, a, out, form, "{tmp}");
    return std.mem.replaceOwned(u8, a, out, "\r\n", "\n");
}

/// Paths under {tmp} use the platform separator in plain-text output; make
/// them slash-separated on both sides so one fixture serves every OS.
fn portable(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    const out = try a.dupe(u8, s);
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, out, i, "{tmp}")) |at| {
        var j = at + "{tmp}".len;
        while (j < out.len and out[j] != ' ' and out[j] != '\n' and out[j] != ')' and out[j] != '"') : (j += 1) {
            // A backslash before a quote is a JSON escape, not a separator.
            if (out[j] == '\\' and !(j + 1 < out.len and out[j + 1] == '"')) out[j] = '/';
        }
        i = j;
    }
    return out;
}

fn spawn(a: std.mem.Allocator, argv: []const []const u8, cwd: []const u8, env: *const std.process.Environ.Map, stdin: []const u8) !Result {
    const tio = std.testing.io;
    var child = try std.process.spawn(tio, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = env,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(tio);
    try child.stdin.?.writeStreamingAll(tio, stdin);
    child.stdin.?.close(tio);
    child.stdin = null;
    var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var reader: std.Io.File.MultiReader = undefined;
    reader.init(a, tio, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();
    while (reader.fill(64, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try reader.checkAnyError();
    const term = try child.wait(tio);
    const code: u8 = switch (term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .code = code, .stdout = try reader.toOwnedSlice(0), .stderr = try reader.toOwnedSlice(1) };
}

const candidates = [_][]const u8{
    "home/.claude/settings.json", "work/.claude/settings.json", "deep/dir/settings.json", "s.json", "bad.json",
};

test "cli fixtures" {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const binary = (try io.readFile(a, build_options.cli_exe)) orelse return error.NoBinary;
    var failures: usize = 0;
    for (try t.cases(a, "cli")) |c| {
        const name = t.str(c, "name");
        const root = try t.tempDir(a);
        const slash = try os.toSlash(a, root);
        for ([_][]const u8{ "bin", "home", "work" }) |d| try os.mkdirAll(a, try os.join(a, root, d));
        const exe = try os.join(a, try os.join(a, root, "bin"), try os.exeName(a, "rufix"));
        try io.writeFileAtomic(a, exe, binary, .executable);
        if (c.get("files")) |files| for (files.object.keys.items, files.object.vals.items) |rel, content| {
            const p = try os.join(a, root, rel);
            try os.mkdirAll(a, os.dir(p));
            try io.writeFileAtomic(a, p, content.string, .data);
        };
        var env = try std.testing.environ.createMap(a);
        _ = env.swapRemove("RUFIX_ENV_FILE");
        _ = env.swapRemove("RUFIX_SECRETS_DIR");
        _ = env.swapRemove("RUFIX_ENV_FILES");
        const home = try os.join(a, root, "home");
        try env.put("HOME", home);
        try env.put("USERPROFILE", home);
        if (c.get("env")) |e| for (e.object.keys.items, e.object.vals.items) |k, v| {
            try env.put(k, try expand(a, v.string, slash));
        };
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(a, exe);
        for (t.array(c, "args")) |arg| try argv.append(a, try expand(a, arg.string, slash));
        const r = try spawn(a, argv.items, try os.join(a, root, "work"), &env, try expand(a, t.str(c, "stdin"), slash));
        const stdout = try portable(a, try normalize(a, r.stdout, root));
        const stderr = try portable(a, try normalize(a, r.stderr, root));
        const want_out = try portable(a, t.str(c, "stdout"));
        const same_out = std.mem.eql(u8, stdout, want_out) or
            (want_out.len > 0 and t.equalText(a, stdout, json.parseAll(a, want_out) catch .null));
        if (r.code != (t.int(c, "exit") orelse -1) or !same_out) {
            t.fail(name, "exit {d} stdout {s}; want exit {d} stdout {s}", .{ r.code, stdout, t.int(c, "exit") orelse -1, want_out });
            failures += 1;
        }
        if ((stderr.len > 0) != t.flag(c, "stderr_nonempty")) {
            t.fail(name, "stderr presence: {s}", .{stderr});
            failures += 1;
        }
        if (c.get("stderr")) |want_err| if (!std.mem.eql(u8, stderr, try portable(a, want_err.string))) {
            t.fail(name, "stderr {s}, want {s}", .{ stderr, want_err.string });
            failures += 1;
        };
        const settings = c.get("settings");
        for (candidates) |rel| {
            if (c.get("files")) |files| if (files.object.get(rel) != null) continue;
            const data = try io.readFile(a, try os.join(a, root, rel));
            const want = if (settings) |s| s.object.get(rel) else null;
            if (want == null) {
                if (data != null) {
                    t.fail(name, "unexpected {s}", .{rel});
                    failures += 1;
                }
                continue;
            }
            const got = if (data) |d| try normalize(a, d, root) else "";
            if (data == null or !t.equalText(a, got, json.parseAll(a, want.?.string) catch .null)) {
                t.fail(name, "{s} differs: {s}", .{ rel, got });
                failures += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}
