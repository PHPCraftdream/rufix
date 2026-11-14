//! The repository side of the install: where rufix keeps its settings for one
//! repository (.claude/settings.local.json) and the self-ignoring .gitignore of
//! the folders that name this machine's binary. The binary itself lives in the
//! system (the installer puts it on the PATH); nothing here copies it.
const std = @import("std");
const io = @import("../platform/io.zig");
const os = @import("../platform/os.zig");

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

/// True for a plain subfolder of a repository: it has no `.git` of its own, but
/// a folder above does. A folder with its own `.git` is a repository root even
/// inside another repository (a submodule, a nested checkout).
pub fn isSubfolder(a: std.mem.Allocator, start: []const u8, stop: []const u8) bool {
    const own = os.join(a, start, ".git") catch return false;
    if (os.exists(a, own)) return false;
    return repositoryAbove(a, start, stop) != null;
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
