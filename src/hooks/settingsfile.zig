//! Reading and writing a Claude Code settings file (settings.json,
//! settings.local.json) as a JSON object, keeping what is not ours.
const std = @import("std");
const json = @import("../core/json.zig");
const io = @import("../platform/io.zig");
const os = @import("../platform/os.zig");

/// The file's top-level object; a missing file or `null` is an empty one, any
/// other JSON value is `error.SyntaxError`.
pub fn load(a: std.mem.Allocator, path: []const u8) !*json.Object {
    const data = (try io.readFile(a, path)) orelse return json.newObject(a);
    return switch (try json.parseFirst(a, data)) {
        .object => |o| o,
        .null => json.newObject(a),
        else => error.SyntaxError,
    };
}

/// Writes the object indented, newline-terminated, creating the folder.
pub fn save(a: std.mem.Allocator, path: []const u8, settings: *json.Object) !void {
    var out: std.ArrayList(u8) = .empty;
    try json.write(a, &out, .{ .object = settings }, 2, 0);
    try out.append(a, '\n');
    try os.mkdirAll(a, os.dir(path));
    try io.writeFileAtomic(a, path, out.items, .data);
}
