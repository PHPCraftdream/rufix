//! Process environment for the CLI: arguments, cwd, environment, home and
//! executable directories, file existence, directory listing and creation.
//! Windows uses the wide-character APIs so non-ASCII paths work; Linux uses
//! libc.
const std = @import("std");
const builtin = @import("builtin");
pub const windows = builtin.os.tag == .windows;
pub const sep: u8 = if (windows) '\\' else '/';

const W = if (windows) struct {
    extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]const u16;
    extern "shell32" fn CommandLineToArgvW([*:0]const u16, *c_int) callconv(.winapi) ?[*][*:0]u16;
    extern "kernel32" fn GetModuleFileNameW(?*anyopaque, [*]u16, u32) callconv(.winapi) u32;
    extern "kernel32" fn GetCurrentDirectoryW(u32, ?[*]u16) callconv(.winapi) u32;
    extern "kernel32" fn GetEnvironmentVariableW([*:0]const u16, ?[*]u16, u32) callconv(.winapi) u32;
    extern "kernel32" fn GetFileAttributesW([*:0]const u16) callconv(.winapi) u32;
    extern "kernel32" fn CreateDirectoryW([*:0]const u16, ?*anyopaque) callconv(.winapi) c_int;
    extern "kernel32" fn FindFirstFileW([*:0]const u16, *FindData) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn FindNextFileW(*anyopaque, *FindData) callconv(.winapi) c_int;
    extern "kernel32" fn FindClose(*anyopaque) callconv(.winapi) c_int;
    const FindData = extern struct {
        attributes: u32,
        creation: [2]u32,
        access: [2]u32,
        write: [2]u32,
        size_high: u32,
        size_low: u32,
        reserved0: u32,
        reserved1: u32,
        name: [260]u16,
        alt_name: [14]u16,
        obsolete: [3]u32,
    };
} else struct {};

const P = if (!windows) struct {
    extern "c" fn getcwd([*]u8, usize) ?[*:0]u8;
    extern "c" fn getenv([*:0]const u8) ?[*:0]const u8;
    extern "c" fn readlink([*:0]const u8, [*]u8, usize) isize;
    extern "c" fn access([*:0]const u8, c_int) c_int;
    extern "c" fn mkdir([*:0]const u8, c_uint) c_int;
    extern "c" fn opendir([*:0]const u8) ?*anyopaque;
    extern "c" fn readdir(*anyopaque) ?*Dirent;
    extern "c" fn closedir(*anyopaque) c_int;
    const Dirent = extern struct { ino: u64, off: i64, reclen: u16, kind: u8, name: [256]u8 };
} else struct {};

const invalid_attributes: u32 = 0xFFFFFFFF;
const attribute_directory: u32 = 0x10;

fn wide(a: std.mem.Allocator, s: []const u8) ![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(a, s);
}

fn narrow(a: std.mem.Allocator, s: []const u16) ![]u8 {
    return std.unicode.utf16LeToUtf8Alloc(a, s);
}

/// Command-line arguments without the program name, as UTF-8.
pub fn args(a: std.mem.Allocator, argc: c_int, argv: [*][*:0]u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (windows) {
        var n: c_int = 0;
        const list = W.CommandLineToArgvW(W.GetCommandLineW(), &n) orelse return error.Args;
        var i: usize = 1;
        while (i < @as(usize, @intCast(n))) : (i += 1) try out.append(a, try narrow(a, std.mem.span(list[i])));
    } else {
        var i: usize = 1;
        while (i < @as(usize, @intCast(argc))) : (i += 1) try out.append(a, std.mem.span(argv[i]));
    }
    return out.items;
}

pub fn getenv(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (windows) {
        const wn = try wide(a, name);
        const n = W.GetEnvironmentVariableW(wn, null, 0);
        if (n == 0) return "";
        const buf = try a.alloc(u16, n);
        const got = W.GetEnvironmentVariableW(wn, buf.ptr, n);
        return narrow(a, buf[0..got]);
    }
    const v = P.getenv(try a.dupeZ(u8, name)) orelse return "";
    return std.mem.span(v);
}

pub fn cwd(a: std.mem.Allocator) ![]const u8 {
    if (windows) {
        const n = W.GetCurrentDirectoryW(0, null);
        if (n == 0) return "";
        const buf = try a.alloc(u16, n);
        const got = W.GetCurrentDirectoryW(n, buf.ptr);
        return narrow(a, buf[0..got]);
    }
    var buf: [4096]u8 = undefined;
    const p = P.getcwd(&buf, buf.len) orelse return "";
    return a.dupe(u8, std.mem.span(p));
}

/// Go os.UserHomeDir: %USERPROFILE% on Windows, $HOME elsewhere.
pub fn home(a: std.mem.Allocator) ![]const u8 {
    return getenv(a, if (windows) "USERPROFILE" else "HOME");
}

/// Directory of the running executable ("" when unknown).
pub fn exeDir(a: std.mem.Allocator) ![]const u8 {
    const p = try exePath(a);
    return if (p.len == 0) "" else dir(p);
}

/// Full path of the running executable ("" when unknown).
pub fn exePath(a: std.mem.Allocator) ![]const u8 {
    var path: []const u8 = "";
    if (windows) {
        var buf: [32768]u16 = undefined;
        const n = W.GetModuleFileNameW(null, &buf, buf.len);
        if (n == 0) return "";
        path = try narrow(a, buf[0..n]);
    } else {
        var buf: [4096]u8 = undefined;
        const n = P.readlink("/proc/self/exe", &buf, buf.len);
        if (n <= 0) return "";
        path = try a.dupe(u8, buf[0..@intCast(n)]);
    }
    return path;
}

pub fn isSep(c: u8) bool {
    return c == '/' or (windows and c == '\\');
}

/// filepath.Join for two parts (no full Clean).
pub fn join(a: std.mem.Allocator, base: []const u8, name: []const u8) ![]const u8 {
    if (base.len == 0) return a.dupe(u8, name);
    if (isSep(base[base.len - 1])) return std.mem.concat(a, u8, &.{ base, name });
    return std.mem.concat(a, u8, &.{ base, &[_]u8{sep}, name });
}

/// filepath.Dir: everything before the last separator, keeping a root.
pub fn dir(p: []const u8) []const u8 {
    if (p.len == 0) return ".";
    var vol: usize = 0;
    if (windows and p.len >= 2 and p[1] == ':') vol = 2;
    var i = p.len;
    while (i > vol and !isSep(p[i - 1])) i -= 1;
    if (i == vol) return if (vol > 0) p[0..vol] else ".";
    // Drop trailing separators, but keep the root itself.
    var end = i;
    while (end > vol + 1 and isSep(p[end - 1])) end -= 1;
    return p[0..end];
}

pub const Kind = enum { missing, file, directory };

pub fn kind(a: std.mem.Allocator, path: []const u8) Kind {
    if (windows) {
        const wp = wide(a, path) catch return .missing;
        const attrs = W.GetFileAttributesW(wp);
        if (attrs == invalid_attributes) return .missing;
        return if (attrs & attribute_directory != 0) .directory else .file;
    }
    const zp = a.dupeZ(u8, path) catch return .missing;
    if (P.access(zp, 0) != 0) return .missing;
    if (P.opendir(zp)) |d| {
        _ = P.closedir(d);
        return .directory;
    }
    return .file;
}

pub fn exists(a: std.mem.Allocator, path: []const u8) bool {
    return kind(a, path) != .missing;
}

/// File names in dir (not recursive), sorted bytewise.
pub fn listDir(a: std.mem.Allocator, path: []const u8) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    if (windows) {
        var data: W.FindData = undefined;
        const pattern = try wide(a, try join(a, path, "*"));
        const h = W.FindFirstFileW(pattern, &data) orelse return names.items;
        defer _ = W.FindClose(h);
        while (true) {
            const n = std.mem.indexOfScalar(u16, &data.name, 0) orelse data.name.len;
            const name = try narrow(a, data.name[0..n]);
            if (data.attributes & attribute_directory == 0) try names.append(a, name);
            if (W.FindNextFileW(h, &data) == 0) break;
        }
    } else {
        const d = P.opendir(try a.dupeZ(u8, path)) orelse return names.items;
        defer _ = P.closedir(d);
        while (P.readdir(d)) |e| {
            const name = std.mem.sliceTo(&e.name, 0);
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            const full = try join(a, path, name);
            if (kind(a, full) == .file) try names.append(a, try a.dupe(u8, name));
        }
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return names.items;
}

extern "c" fn _wspawnvp(c_int, [*:0]const u16, [*:null]const ?[*:0]const u16) isize;
extern "c" fn execvp([*:0]const u8, [*:null]const ?[*:0]const u8) c_int;

/// Quotes one argument so the C runtime's parser gives it back unchanged.
fn quoteArg(a: std.mem.Allocator, arg: []const u8) ![]const u8 {
    if (arg.len > 0 and std.mem.indexOfAny(u8, arg, " \t\n\x0b\"") == null) return arg;
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '"');
    var slashes: usize = 0;
    for (arg) |c| {
        if (c == '\\') {
            slashes += 1;
            continue;
        }
        if (c == '"') {
            try out.appendNTimes(a, '\\', slashes * 2 + 1);
        } else try out.appendNTimes(a, '\\', slashes);
        slashes = 0;
        try out.append(a, c);
    }
    try out.appendNTimes(a, '\\', slashes * 2);
    try out.append(a, '"');
    return out.items;
}

/// Runs argv (searched on PATH) with inherited stdio and returns its exit
/// code. On POSIX the process is replaced, so the code propagates itself.
pub fn spawnWait(a: std.mem.Allocator, argv: []const []const u8) !u8 {
    if (windows) {
        const list = try a.alloc(?[*:0]const u16, argv.len + 1);
        for (argv, 0..) |arg, i| list[i] = (try wide(a, try quoteArg(a, arg))).ptr;
        list[argv.len] = null;
        const file = try wide(a, argv[0]);
        const code = _wspawnvp(0, file, @ptrCast(list.ptr));
        if (code < 0) return error.SpawnFailed;
        return @truncate(@as(usize, @intCast(code)));
    }
    const list = try a.alloc(?[*:0]const u8, argv.len + 1);
    for (argv, 0..) |arg, i| list[i] = (try a.dupeZ(u8, arg)).ptr;
    list[argv.len] = null;
    _ = execvp(list[0].?, @ptrCast(list.ptr));
    return error.SpawnFailed;
}

/// os.MkdirAll for the directory path.
pub fn mkdirAll(a: std.mem.Allocator, path: []const u8) !void {
    if (path.len == 0 or exists(a, path)) return;
    const parent = dir(path);
    if (!std.mem.eql(u8, parent, path)) try mkdirAll(a, parent);
    if (windows) {
        if (W.CreateDirectoryW(try wide(a, path), null) == 0 and !exists(a, path)) return error.MkdirFailed;
    } else {
        if (P.mkdir(try a.dupeZ(u8, path), 0o755) != 0 and !exists(a, path)) return error.MkdirFailed;
    }
}
