//! Opt-in KEY=VALUE secret files.
const std = @import("std");
const os = @import("os.zig");
const io = @import("io.zig");
const engine = @import("../core/engine.zig");

const space = " \t\r\n\x0b\x0c";

fn stripInlineComment(v: []const u8) []const u8 {
    if (std.mem.startsWith(u8, v, "\"") or std.mem.startsWith(u8, v, "'")) return v;
    if (std.mem.indexOf(u8, v, " #")) |i| return std.mem.trimEnd(u8, v[0..i], " \t");
    return v;
}

fn unquote(v: []const u8) []const u8 {
    for ([_][]const u8{ "\"", "'" }) |q| {
        if (v.len >= 2 and std.mem.startsWith(u8, v, q) and std.mem.endsWith(u8, v, q)) return v[1 .. v.len - 1];
    }
    return v;
}

/// Appends parsed pairs; a key already present keeps its first value.
pub fn parse(a: std.mem.Allocator, data: []const u8, vars: *std.ArrayList(engine.Var)) !void {
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        var line = std.mem.trim(u8, std.mem.trimEnd(u8, raw, "\r"), space);
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "export ")) line = line["export ".len..];
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], space);
        const value = unquote(stripInlineComment(std.mem.trim(u8, line[eq + 1 ..], space)));
        if (key.len == 0) continue;
        if (has(vars.items, key)) continue;
        try vars.append(a, .{ .key = key, .value = value });
    }
}

pub fn has(vars: []const engine.Var, key: []const u8) bool {
    for (vars) |v| if (std.mem.eql(u8, v.key, key)) return true;
    return false;
}

/// A file, or every *.env file of a directory in name order.
pub fn load(a: std.mem.Allocator, path: []const u8) ![]const engine.Var {
    var vars: std.ArrayList(engine.Var) = .empty;
    switch (os.kind(a, path)) {
        .missing => return error.NotFound,
        .file => try parse(a, (try io.readFile(a, path)) orelse return error.ReadFailed, &vars),
        .directory => for (try os.listDir(a, path)) |name| {
            if (!std.mem.endsWith(u8, name, ".env")) continue;
            const data = (try io.readFile(a, try os.join(a, path, name))) orelse return error.ReadFailed;
            try parse(a, data, &vars);
        },
    }
    return vars.items;
}

/// $RUFIX_ENV_FILE → $RUFIX_SECRETS_DIR → a directory holding .atlassian.env
/// walking up from start → exe_dir/secrets → home/.config/rufix/secrets.
pub fn resolve(a: std.mem.Allocator, start: []const u8, exe_dir: []const u8, home: []const u8) ![]const u8 {
    const file = try os.getenv(a, "RUFIX_ENV_FILE");
    if (file.len > 0) {
        if (os.exists(a, file)) return file;
        const d = os.dir(file);
        if (os.exists(a, d)) return d;
    }
    const secrets = try os.getenv(a, "RUFIX_SECRETS_DIR");
    if (secrets.len > 0 and os.exists(a, secrets)) return secrets;
    var d: []const u8 = if (start.len == 0) "." else start;
    while (true) {
        if (os.exists(a, try os.join(a, d, ".atlassian.env"))) return d;
        const parent = os.dir(d);
        if (std.mem.eql(u8, parent, d)) break;
        d = parent;
    }
    if (exe_dir.len > 0) {
        const p = try os.join(a, exe_dir, "secrets");
        if (os.exists(a, p)) return p;
    }
    const fallback = try os.join(a, try os.join(a, try os.join(a, home, ".config"), "rufix"), "secrets");
    if (os.exists(a, fallback)) return fallback;
    return "";
}
