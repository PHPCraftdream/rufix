//! The per-repository home of rufix: <repo>/.claude/rufix/ holds a copy of the
//! binary (built with this machine's private values) and its shell twin, and
//! the hooks, shell prefix and mod all point there. Nothing is installed
//! outside the repository; the folder ignores itself, so the binary cannot be
//! committed by accident.
const std = @import("std");
const io = @import("../platform/io.zig");
const os = @import("../platform/os.zig");
const shellinstall = @import("shellinstall.zig");

/// First line of every .gitignore we write: uninstall removes only those.
pub const ignore_marker = "# Written by `rufix install`: machine-specific files, never commit them.";
pub const ignore_body = ignore_marker ++ "\n*\n";

fn claude(a: std.mem.Allocator, base: []const u8) ![]const u8 {
    return os.join(a, base, ".claude");
}

/// The personal settings file of a repository: hooks and the shell prefix
/// name this machine's binary, so they never belong in the shared file.
pub fn settingsPath(a: std.mem.Allocator, repo: []const u8) ![]const u8 {
    return os.join(a, try claude(a, repo), "settings.local.json");
}

/// settings.json under `base` (a repository or the user's home): where older
/// versions wrote the hooks.
pub fn sharedSettings(a: std.mem.Allocator, base: []const u8) ![]const u8 {
    return os.join(a, try claude(a, base), "settings.json");
}

pub fn dir(a: std.mem.Allocator, repo: []const u8) ![]const u8 {
    return os.join(a, try claude(a, repo), "rufix");
}

pub fn exePath(a: std.mem.Allocator, repo: []const u8) ![]const u8 {
    return os.join(a, try dir(a, repo), try os.exeName(a, "rufix"));
}

/// The nearest folder above `start` that holds a `.git` (a folder, or a file
/// in a linked worktree), or null. Claude Code reads a project's `.claude/`
/// from the folder it starts in, normally the repository root: setting up a
/// subfolder would silently protect nothing. `stop` is the highest folder
/// looked at ("" for no limit).
pub fn repositoryAbove(a: std.mem.Allocator, start: []const u8, stop: []const u8) ?[]const u8 {
    var cur = start;
    while (true) {
        if (stop.len > 0 and std.mem.eql(u8, cur, stop)) return null;
        const parent = os.dir(cur);
        if (std.mem.eql(u8, parent, cur)) return null;
        cur = parent;
        const marker = os.join(a, cur, ".git") catch return null;
        if (os.exists(a, marker)) return cur;
    }
}

/// Writes a self-ignoring .gitignore into `folder`.
pub fn writeIgnore(a: std.mem.Allocator, folder: []const u8) !void {
    try io.writeFileAtomic(a, try os.join(a, folder, ".gitignore"), ignore_body, .data);
}

/// Removes a .gitignore written by writeIgnore; any other is left alone.
pub fn removeIgnore(a: std.mem.Allocator, folder: []const u8) void {
    const path = os.join(a, folder, ".gitignore") catch return;
    const data = (io.readFile(a, path) catch return) orelse return;
    if (std.mem.startsWith(u8, data, ignore_marker)) os.remove(a, path) catch {};
}

/// Copies the running binary into the repository.
pub fn install(a: std.mem.Allocator, repo: []const u8, running: []const u8) ![]const u8 {
    const folder = try dir(a, repo);
    try os.mkdirAll(a, folder);
    try writeIgnore(a, folder);
    try io.copyExecutable(a, running, try exePath(a, repo));
    return std.fmt.allocPrint(a, "binary installed in {s}", .{folder});
}

/// True when the repository holds its copy of the binary.
pub fn status(a: std.mem.Allocator, repo: []const u8) bool {
    const p = exePath(a, repo) catch return false;
    return os.exists(a, p);
}

/// Removes both binaries and the folder. A copy that is running (Windows
/// cannot delete one) stays, with the .gitignore that keeps it out of commits.
pub fn uninstall(a: std.mem.Allocator, repo: []const u8) ![]const u8 {
    const folder = try dir(a, repo);
    const paths = [_][]const u8{ try exePath(a, repo), try shellinstall.shellExe(a, folder) };
    var removed: usize = 0;
    var left: std.ArrayList([]const u8) = .empty;
    for (paths) |p| {
        if (!os.exists(a, p)) continue;
        if (os.remove(a, p)) |_| removed += 1 else |_| try left.append(a, p);
    }
    if (left.items.len == 0) {
        removeIgnore(a, folder);
        os.removeEmptyDir(a, folder);
    }
    if (left.items.len > 0) {
        return std.fmt.allocPrint(a, "removed {d} binar(y/ies); in use, delete by hand: {s}", .{ removed, try std.mem.join(a, ", ", left.items) });
    }
    if (removed == 0) return "no local binaries";
    return std.fmt.allocPrint(a, "removed {d} binar(y/ies) from {s}", .{ removed, folder });
}
