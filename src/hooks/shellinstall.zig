//! Per-repository shell prefix: `rufix install` points Claude Code's
//! CLAUDE_CODE_SHELL_PREFIX in the repository's .claude/settings.local.json at
//! the rufix-shell twin that sits next to the installed binary — a personal
//! file, since it holds a local path. The installer makes the twin; it is
//! created here only when it is missing (running a freshly built binary).
const std = @import("std");
const json = @import("../core/json.zig");
const io = @import("../platform/io.zig");
const os = @import("../platform/os.zig");
const settingsfile = @import("settingsfile.zig");

pub const prefix_key = "CLAUDE_CODE_SHELL_PREFIX";
pub const env_files_key = "RUFIX_ENV_FILES";

pub fn shellExe(a: std.mem.Allocator, exe_dir: []const u8) ![]const u8 {
    return os.join(a, exe_dir, try os.exeName(a, "rufix-shell"));
}

fn localPath(a: std.mem.Allocator, settings_path: []const u8) ![]const u8 {
    return os.join(a, os.dir(settings_path), "settings.local.json");
}

const load = settingsfile.load;
const save = settingsfile.save;

/// What `install` would refuse, found before anything is written: the hooks
/// share this file, and a half-done install is worse than none.
pub fn check(a: std.mem.Allocator, settings_path: []const u8) !void {
    const settings = try load(a, try localPath(a, settings_path));
    const env_v = settings.get("env") orelse return;
    switch (env_v) {
        .null => {},
        .object => |env| if (env.get(prefix_key)) |v| {
            if (v != .string or !isOurs(v.string)) return error.ForeignShellPrefix;
        },
        else => return error.EnvNotAnObject,
    }
}

pub fn install(a: std.mem.Allocator, settings_path: []const u8, exe_path: []const u8, env_files: bool) ![]const u8 {
    const target = try shellExe(a, os.dir(exe_path));
    // Never overwritten: another repository's session may be running it, and
    // Windows cannot replace a running executable.
    if (!os.exists(a, target)) try io.copyExecutable(a, exe_path, target);
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
    try env.put(a, prefix_key, .{ .string = try os.toSlash(a, target) });
    if (env_files) try env.put(a, env_files_key, .{ .string = "1" }) else env.remove(env_files_key);
    try save(a, path, settings);
    return std.fmt.allocPrint(a, "shell prefix set in {s}", .{path});
}

fn isOurs(prefix: []const u8) bool {
    return os.isExecutableNamed(prefix, "rufix-shell");
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
