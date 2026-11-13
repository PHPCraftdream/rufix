//! Per-repository shell prefix: `rufix install --project --shell` copies
//! this binary to rufix-shell next to it and points Claude Code's
//! CLAUDE_CODE_SHELL_PREFIX at it in the repository's
//! .claude/settings.local.json — a personal file, since it holds a local path.
const std = @import("std");
const json = @import("../core/json.zig");
const io = @import("../platform/io.zig");
const os = @import("../platform/os.zig");

pub const prefix_key = "CLAUDE_CODE_SHELL_PREFIX";
pub const env_files_key = "RUFIX_ENV_FILES";

pub fn shellExe(a: std.mem.Allocator, exe_dir: []const u8) ![]const u8 {
    return os.join(a, exe_dir, if (os.windows) "rufix-shell.exe" else "rufix-shell");
}

fn localPath(a: std.mem.Allocator, settings_path: []const u8) ![]const u8 {
    return os.join(a, os.dir(settings_path), "settings.local.json");
}

fn slashes(a: std.mem.Allocator, p: []const u8) ![]const u8 {
    const out = try a.dupe(u8, p);
    std.mem.replaceScalar(u8, out, '\\', '/');
    return out;
}

fn load(a: std.mem.Allocator, path: []const u8) !*json.Object {
    const data = (try io.readFile(a, path)) orelse return json.newObject(a);
    return switch (try json.parseFirst(a, data)) {
        .object => |o| o,
        .null => json.newObject(a),
        else => error.SyntaxError,
    };
}

fn save(a: std.mem.Allocator, path: []const u8, obj: *json.Object) !void {
    var out: std.ArrayList(u8) = .empty;
    try json.write(a, &out, .{ .object = obj }, 2, 0);
    try out.append(a, '\n');
    try os.mkdirAll(a, os.dir(path));
    try io.writeFileAtomic(a, path, out.items);
}

/// Copies the running binary to rufix-shell; an identical copy in use is kept.
fn copySelf(a: std.mem.Allocator, exe_path: []const u8, target: []const u8) !void {
    const data = (try io.readFile(a, exe_path)) orelse return error.SelfUnreadable;
    if (try io.readFile(a, target)) |old| {
        if (std.mem.eql(u8, old, data)) return;
    }
    try io.writeFileAtomic(a, target, data);
}

pub fn install(a: std.mem.Allocator, settings_path: []const u8, exe_path: []const u8, env_files: bool) ![]const u8 {
    const target = try shellExe(a, os.dir(exe_path));
    try copySelf(a, exe_path, target);
    const path = try localPath(a, settings_path);
    const settings = try load(a, path);
    var env: *json.Object = undefined;
    if (settings.get("env")) |v| switch (v) {
        .object => |o| env = o,
        .null => {
            env = try json.newObject(a);
            try settings.put(a, "env", .{ .object = env });
        },
        else => return error.EnvNotAnObject,
    } else {
        env = try json.newObject(a);
        try settings.put(a, "env", .{ .object = env });
    }
    if (env.get(prefix_key)) |v| {
        // Never take over somebody else's prefix.
        if (v != .string or !isOurs(v.string)) return error.ForeignShellPrefix;
    }
    try env.put(a, prefix_key, .{ .string = try slashes(a, target) });
    if (env_files) try env.put(a, env_files_key, .{ .string = "1" }) else env.remove(env_files_key);
    try save(a, path, settings);
    return std.fmt.allocPrint(a, "shell prefix set in {s}", .{path});
}

fn isOurs(prefix: []const u8) bool {
    const base = std.fs.path.basename(prefix);
    return std.ascii.eqlIgnoreCase(base, "rufix-shell") or std.ascii.eqlIgnoreCase(base, "rufix-shell.exe");
}

pub fn uninstall(a: std.mem.Allocator, settings_path: []const u8) ![]const u8 {
    const path = try localPath(a, settings_path);
    if (!os.exists(a, path)) return "no shell prefix";
    const settings = try load(a, path);
    const env_v = settings.get("env") orelse return "no shell prefix";
    if (env_v != .object) return "no shell prefix";
    const env = env_v.object;
    const v = env.get(prefix_key) orelse return "no shell prefix";
    if (v != .string or !isOurs(v.string)) return "no shell prefix";
    env.remove(prefix_key);
    env.remove(env_files_key);
    if (env.keys.items.len == 0) settings.remove("env");
    try save(a, path, settings);
    return std.fmt.allocPrint(a, "shell prefix removed from {s}", .{path});
}

/// "on" when the repository's local settings point at rufix-shell.
pub fn status(a: std.mem.Allocator, settings_path: []const u8) !bool {
    const path = try localPath(a, settings_path);
    if (!os.exists(a, path)) return false;
    const settings = load(a, path) catch return false;
    const env_v = settings.get("env") orelse return false;
    if (env_v != .object) return false;
    const v = env_v.object.get(prefix_key) orelse return false;
    return v == .string and isOurs(v.string);
}
