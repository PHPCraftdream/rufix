//! Byte-exact stdio and whole-file access through the C runtime (UCRT on
//! Windows), which keeps the executable small.
const std = @import("std");
const builtin = @import("builtin");
const windows = builtin.os.tag == .windows;

extern "c" fn fread([*]u8, usize, usize, *anyopaque) usize;
extern "c" fn fwrite([*]const u8, usize, usize, *anyopaque) usize;
extern "c" fn fclose(*anyopaque) c_int;
extern "c" fn fflush(?*anyopaque) c_int;
extern "c" fn ferror(*anyopaque) c_int;
extern "c" fn fopen([*:0]const u8, [*:0]const u8) ?*anyopaque;
extern "c" fn rename([*:0]const u8, [*:0]const u8) c_int;
extern "c" fn _wfopen([*:0]const u16, [*:0]const u16) ?*anyopaque;
extern "c" fn _wremove([*:0]const u16) c_int;
extern "c" fn _wrename([*:0]const u16, [*:0]const u16) c_int;
extern "c" fn __acrt_iob_func(c_uint) *anyopaque;
extern "c" fn _fileno(*anyopaque) c_int;
extern "c" fn _setmode(c_int, c_int) c_int;
extern "c" var stdin: *anyopaque;
extern "c" var stdout: *anyopaque;
extern "c" var stderr: *anyopaque;

fn stream(n: c_uint) *anyopaque {
    if (windows) return __acrt_iob_func(n);
    return switch (n) {
        0 => stdin,
        1 => stdout,
        else => stderr,
    };
}

/// Switches stdio to binary mode so bytes pass through unchanged.
pub fn init() void {
    if (windows) {
        _ = _setmode(_fileno(stream(0)), 0x8000);
        _ = _setmode(_fileno(stream(1)), 0x8000);
        _ = _setmode(_fileno(stream(2)), 0x8000);
    }
}

fn readAll(a: std.mem.Allocator, f: *anyopaque) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = fread(&buf, 1, buf.len, f);
        try out.appendSlice(a, buf[0..n]);
        if (n < buf.len) break;
    }
    if (ferror(f) != 0) return error.ReadFailed;
    return out.items;
}

extern "c" fn _read(c_int, [*]u8, c_uint) c_int;
extern "c" fn read(c_int, [*]u8, usize) isize;

/// Returns as soon as some input is available (0 at end of input), so a
/// filter can stream line by line.
pub fn readSome(buf: []u8) usize {
    if (windows) {
        const n = _read(0, buf.ptr, @intCast(@min(buf.len, std.math.maxInt(c_int))));
        return if (n > 0) @intCast(n) else 0;
    }
    const n = read(0, buf.ptr, buf.len);
    return if (n > 0) @intCast(n) else 0;
}

pub fn readStdin(a: std.mem.Allocator) ![]u8 {
    return readAll(a, stream(0));
}

fn writeAll(f: *anyopaque, data: []const u8) !void {
    if (data.len == 0) return;
    if (fwrite(data.ptr, 1, data.len, f) != data.len) return error.WriteFailed;
    if (fflush(f) != 0) return error.WriteFailed;
}

pub fn writeStdout(data: []const u8) !void {
    return writeAll(stream(1), data);
}

pub fn writeStderr(data: []const u8) void {
    writeAll(stream(2), data) catch {};
}

fn wide(a: std.mem.Allocator, s: []const u8) ![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(a, s);
}

fn open(a: std.mem.Allocator, path: []const u8, mode: []const u8) !?*anyopaque {
    if (windows) return _wfopen(try wide(a, path), try wide(a, mode));
    return fopen(try a.dupeZ(u8, path), try a.dupeZ(u8, mode));
}

/// Returns null when the file cannot be opened (treated as missing).
pub fn readFile(a: std.mem.Allocator, path: []const u8) !?[]u8 {
    const f = try open(a, path, "rb") orelse return null;
    defer _ = fclose(f);
    return try readAll(a, f);
}

extern "c" fn chmod([*:0]const u8, c_uint) c_int;

pub const Mode = enum { data, executable };

/// Writes through a temporary file renamed over the target. An executable
/// copy gets mode 0755 on POSIX; fopen alone would leave it unrunnable.
pub fn writeFileAtomic(a: std.mem.Allocator, path: []const u8, data: []const u8, mode: Mode) !void {
    const tmp = try std.mem.concat(a, u8, &.{ path, ".rufix-tmp" });
    {
        const f = try open(a, tmp, "wb") orelse return error.OpenFailed;
        defer _ = fclose(f);
        try writeAll(f, data);
    }
    if (windows) {
        const wp = try wide(a, path);
        _ = _wremove(wp);
        if (_wrename(try wide(a, tmp), wp) != 0) return error.RenameFailed;
    } else {
        const ztmp = try a.dupeZ(u8, tmp);
        if (mode == .executable and chmod(ztmp, 0o755) != 0) return error.ChmodFailed;
        if (rename(ztmp, try a.dupeZ(u8, path)) != 0) return error.RenameFailed;
    }
}
