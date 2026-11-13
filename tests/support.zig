//! Shared helpers: loading conformance/<kind>/*.json, JSON comparison with
//! literal numbers, building a store from a case, temporary directories.
const std = @import("std");
const rufix = @import("rufix");
const json = rufix.json;
const engine = rufix.engine;
const os = rufix.os;
const io = rufix.io;

pub const Value = json.Value;

/// Every case of conformance/<kind>/, files in name order.
pub fn cases(a: std.mem.Allocator, kind: []const u8) ![]const *json.Object {
    var out: std.ArrayList(*json.Object) = .empty;
    const dir = try os.join(a, "conformance", kind);
    const names = try os.listDir(a, dir);
    if (names.len == 0) return error.NoFixtures;
    for (names) |name| {
        if (!std.mem.endsWith(u8, name, ".json")) continue;
        const data = (try io.readFile(a, try os.join(a, dir, name))) orelse return error.Unreadable;
        const doc = try json.parseAll(a, data);
        const list = doc.object.get("cases") orelse return error.NoCases;
        for (list.array.items.items) |c| try out.append(a, c.object);
    }
    return out.items;
}

pub fn str(o: *json.Object, key: []const u8) []const u8 {
    const v = o.get(key) orelse return "";
    return if (v == .string) v.string else "";
}

pub fn flag(o: *json.Object, key: []const u8) bool {
    const v = o.get(key) orelse return false;
    return v == .bool and v.bool;
}

pub fn int(o: *json.Object, key: []const u8) ?i64 {
    const v = o.get(key) orelse return null;
    if (v != .number) return null;
    return std.fmt.parseInt(i64, v.number, 10) catch null;
}

pub fn array(o: *json.Object, key: []const u8) []const Value {
    const v = o.get(key) orelse return &.{};
    return if (v == .array) v.array.items.items else &.{};
}

pub fn isNull(o: *json.Object, key: []const u8) bool {
    const v = o.get(key) orelse return true;
    return v == .null;
}

/// JSON values equal as documents: key order free, numbers by literal text.
pub fn equal(x: Value, y: Value) bool {
    switch (x) {
        .null => return y == .null,
        .bool => |b| return y == .bool and y.bool == b,
        .number => |n| return y == .number and std.mem.eql(u8, n, y.number),
        .string => |s| return y == .string and std.mem.eql(u8, s, y.string),
        .array => |arr| {
            if (y != .array or y.array.items.items.len != arr.items.items.len) return false;
            for (arr.items.items, y.array.items.items) |p, q| if (!equal(p, q)) return false;
            return true;
        },
        .object => |obj| {
            if (y != .object or y.object.keys.items.len != obj.keys.items.len) return false;
            for (obj.keys.items, obj.vals.items) |k, v| {
                const other = y.object.get(k) orelse return false;
                if (!equal(v, other)) return false;
            }
            return true;
        },
    }
}

/// Compares JSON text with an expected value; empty text equals null.
pub fn equalText(a: std.mem.Allocator, text: []const u8, want: Value) bool {
    const trimmed = std.mem.trim(u8, text, " \r\n\t");
    if (trimmed.len == 0) return want == .null;
    const got = json.parseAll(a, trimmed) catch return false;
    return equal(got, want);
}

pub fn render(a: std.mem.Allocator, v: Value) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    json.write(a, &out, v, 0, 0) catch return "<oom>";
    return out.items;
}

/// Store from a case's vars and rules, exactly as the CLI builds one.
pub fn store(a: std.mem.Allocator, c: *json.Object) !engine.Store {
    var vars: std.ArrayList(engine.Var) = .empty;
    if (c.get("vars")) |vv| if (vv == .object) {
        for (vv.object.keys.items, vv.object.vals.items) |k, v| try vars.append(a, .{ .key = k, .value = v.string });
    };
    var specs: std.ArrayList(engine.RuleSpec) = .empty;
    for (array(c, "rules")) |r| {
        const o = r.object;
        try specs.append(a, .{
            .name = str(o, "name"),
            .match = str(o, "match"),
            .replace = str(o, "replace"),
            .restore_match = str(o, "restore_match"),
            .restore_replace = str(o, "restore_replace"),
            .allowlist_seed = flag(o, "allowlist_seed"),
            .strict_tld = flag(o, "strict_tld"),
            .preserve_case = flag(o, "preserve_case"),
        });
    }
    var failed: usize = 0;
    return .{ .gpa = a, .exact = try engine.buildExact(a, vars.items), .rules = try engine.compileRules(a, specs.items, &failed) };
}

var tmp_counter: usize = 0;
extern "c" fn time(?*i64) i64;

/// A fresh directory under .zig-cache/tmp (absolute path).
pub fn tempDir(a: std.mem.Allocator) ![]const u8 {
    tmp_counter += 1;
    // Seconds since the epoch keep runs apart; the counter keeps cases apart.
    const name = try std.fmt.allocPrint(a, "rufix-{d}-{d}", .{ time(null), tmp_counter });
    const path = try os.join(a, try os.join(a, try os.join(a, try os.cwd(a), ".zig-cache"), "tmp"), name);
    try os.mkdirAll(a, path);
    return path;
}

pub fn fail(name: []const u8, comptime fmt: []const u8, args: anytype) void {
    std.debug.print("FAIL {s}: " ++ fmt ++ "\n", .{name} ++ args);
}
