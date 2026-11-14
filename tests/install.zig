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

test "local install copies the binary, ignores itself and removes only its own files" {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const local = rufix.local;
    const repo = try t.tempDir(a);
    const running = try os.join(a, repo, "built");
    try io.writeFileAtomic(a, running, "binary-v1", .executable);
    try std.testing.expect(!local.status(a, repo));
    _ = try local.install(a, repo, running);
    try std.testing.expect(local.status(a, repo));
    const copy = (try io.readFile(a, try local.exePath(a, repo))).?;
    try std.testing.expectEqualStrings("binary-v1", copy);
    // The folder ignores itself, so the binary with private values is never committed.
    const ignore = (try io.readFile(a, try os.join(a, try local.dir(a, repo), ".gitignore"))).?;
    try std.testing.expect(std.mem.startsWith(u8, ignore, local.ignore_marker));
    try std.testing.expect(std.mem.endsWith(u8, ignore, "\n*\n"));
    // A newer build replaces the copy.
    try io.writeFileAtomic(a, running, "binary-v2", .executable);
    _ = try local.install(a, repo, running);
    try std.testing.expectEqualStrings("binary-v2", (try io.readFile(a, try local.exePath(a, repo))).?);
    _ = try local.uninstall(a, repo);
    try std.testing.expect(!os.exists(a, try local.dir(a, repo)));
    try std.testing.expectEqualStrings("no local binaries", try local.uninstall(a, repo));
    // A .gitignore that is not ours survives.
    const folder = try local.dir(a, repo);
    try os.mkdirAll(a, folder);
    try io.writeFileAtomic(a, try os.join(a, folder, ".gitignore"), "mine\n", .data);
    _ = try local.uninstall(a, repo);
    try std.testing.expect(os.exists(a, try os.join(a, folder, ".gitignore")));
}

test "repositoryAbove finds the nearest .git above a folder, up to a limit" {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const local = rufix.local;
    const root = try t.tempDir(a);
    const work = try os.join(a, root, "work");
    const deep = try os.join(a, try os.join(a, work, "pkg"), "deep");
    try os.mkdirAll(a, deep);
    // Nothing between the folder and the limit.
    try std.testing.expect(local.repositoryAbove(a, deep, root) == null);
    // A linked worktree has .git as a file: it counts too.
    try io.writeFileAtomic(a, try os.join(a, work, ".git"), "gitdir: elsewhere\n", .data);
    try std.testing.expectEqualStrings(work, local.repositoryAbove(a, deep, root).?);
    // A folder is not above itself: the repository root is where to install.
    try std.testing.expect(local.repositoryAbove(a, work, root) == null);
    // The nearest one wins.
    const inner = try os.join(a, work, "pkg");
    try os.mkdirAll(a, try os.join(a, inner, ".git"));
    try std.testing.expectEqualStrings(inner, local.repositoryAbove(a, deep, root).?);
}
