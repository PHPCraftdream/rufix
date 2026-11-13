//! conformance/install: settings.json merges, step by step.
const std = @import("std");
const rufix = @import("rufix");
const t = @import("support.zig");
const io = rufix.io;
const os = rufix.os;
const install = rufix.install;

test "install fixtures" {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var failures: usize = 0;
    for (try t.cases(a, "install")) |c| {
        const name = t.str(c, "name");
        const dir = try t.tempDir(a);
        const path = try os.join(a, dir, "settings.json");
        if (c.get("initial_raw")) |raw| {
            try io.writeFileAtomic(a, path, raw.string, .data);
        } else if (!t.isNull(c, "initial")) {
            try io.writeFileAtomic(a, path, t.render(a, c.get("initial").?), .data);
        }
        for (t.array(c, "steps"), 0..) |sv, i| {
            const s = sv.object;
            const opts = s.get("options").?.object;
            const o = install.Options{ .path = path, .exe_dir = t.str(opts, "exe_dir"), .env_files = t.flag(opts, "env_files") };
            const action = t.str(s, "action");
            const result = if (std.mem.eql(u8, action, "install"))
                install.install(a, o)
            else if (std.mem.eql(u8, action, "uninstall"))
                install.uninstall(a, o)
            else
                install.status(a, o);
            if (t.flag(s, "error")) {
                if (result) |summary| {
                    t.fail(name, "step {d} {s} succeeded ({s}), want an error", .{ i, action, summary });
                    failures += 1;
                } else |_| {}
            } else if (result) |summary| {
                const got = try std.mem.replaceOwned(u8, a, summary, path, "{path}");
                if (!std.mem.eql(u8, got, t.str(s, "summary"))) {
                    t.fail(name, "step {d} {s}: summary {s}, want {s}", .{ i, action, got, t.str(s, "summary") });
                    failures += 1;
                }
            } else |err| {
                t.fail(name, "step {d} {s}: {s}", .{ i, action, @errorName(err) });
                failures += 1;
            }
            if (!try settingsMatch(a, path, s)) {
                t.fail(name, "step {d} {s}: settings differ", .{ i, action });
                failures += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

fn settingsMatch(a: std.mem.Allocator, path: []const u8, s: anytype) !bool {
    const data = try io.readFile(a, path);
    if (s.get("settings_raw")) |raw| return data != null and std.mem.eql(u8, data.?, raw.string);
    const want = s.get("settings") orelse .null;
    if (data == null) return want == .null;
    return t.equalText(a, data.?, want);
}

test "mod install writes, reports and removes only its own files" {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const modinstall = rufix.modinstall;
    const dir = try t.tempDir(a);
    const path = try os.join(a, try os.join(a, dir, ".claude"), "settings.json");
    try std.testing.expect(!try modinstall.status(a, path));
    const exe = try os.join(a, try os.join(a, dir, "bin"), try os.exeName(a, "rufix"));
    _ = try modinstall.install(a, path, exe, true);
    try std.testing.expect(try modinstall.status(a, path));
    const module = (try io.readFile(a, try os.join(a, try os.join(a, try modinstall.dir(a, path), "hooks"), "register.ts"))).?;
    // The module names the binary slash-separated, followed by its arguments.
    const argv = try std.fmt.allocPrint(a, "[\"{s}\", 'redact', '--env-files']", .{try os.toSlash(a, exe)});
    try std.testing.expect(std.mem.indexOf(u8, module, argv) != null);
    _ = try modinstall.uninstall(a, path);
    try std.testing.expect(!os.exists(a, try modinstall.dir(a, path)));
    // A folder without our marker is somebody else's: never removed.
    const foreign = try os.join(a, try os.join(a, try modinstall.dir(a, path), "hooks"), "register.ts");
    try os.mkdirAll(a, os.dir(foreign));
    try io.writeFileAtomic(a, foreign, "export const register = () => {}\n", .data);
    try std.testing.expectEqualStrings("no mod", try modinstall.uninstall(a, path));
    try std.testing.expect(os.exists(a, foreign));
}
