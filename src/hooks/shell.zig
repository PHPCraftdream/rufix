//! Shell prefix (CLAUDE_CODE_SHELL_PREFIX): Claude Code runs every shell
//! command as `rufix-shell '<command line>'`. Bash tool calls are run with
//! their stdout and stderr masked line by line, keeping the exit code, so
//! the output of a failing command (which PostToolUse never sees) cannot
//! leak. Everything else — hooks, the status line, MCP server start-up — is
//! passed through untouched: masking a hook's or an MCP server's output
//! would break its protocol.
const std = @import("std");
const os = @import("../platform/os.zig");
const io = @import("../platform/io.zig");
const engine = @import("../core/engine.zig");

/// Claude Code's Bash tool sources a shell snapshot and records the final
/// working directory; hooks, status lines and MCP servers do neither.
pub fn isBashToolCall(cmd: []const u8) bool {
    return std.mem.indexOf(u8, cmd, "/shell-snapshots/snapshot-") != null and
        std.mem.indexOf(u8, cmd, "pwd -P >| ") != null;
}

/// Runs inside bash: $0 is this executable, $1 the command line. Both
/// streams go through `filter`; the command's own status is returned once
/// the stderr filter has drained.
const masked_script =
    \\{ eval "$1"; } 2> >("$0" filter >&2) | "$0" filter
    \\s=${PIPESTATUS[0]}
    \\wait $! 2>/dev/null
    \\exit $s
;

fn forwardSlashes(a: std.mem.Allocator, p: []const u8) ![]const u8 {
    const out = try a.dupe(u8, p);
    std.mem.replaceScalar(u8, out, '\\', '/');
    return out;
}

pub fn run(a: std.mem.Allocator, self_path: []const u8, cmd: []const u8) u8 {
    const bash = "bash";
    if (!isBashToolCall(cmd)) return os.spawnWait(a, &.{ bash, "-c", cmd }) catch failed();
    const self = forwardSlashes(a, self_path) catch return failed();
    return os.spawnWait(a, &.{ bash, "-c", masked_script, self, cmd }) catch failed();
}

fn failed() u8 {
    io.writeStderr("rufix-shell: cannot start bash\n");
    return 127;
}

/// Masks stdin to stdout line by line, flushing each line, so long-running
/// commands still stream. A secret never spans lines in tool output rules.
pub fn filter(a: std.mem.Allocator, st: *engine.Store) !void {
    // Each line's work lives in a scratch arena reset after the line, so
    // memory stays bounded however much a command prints.
    var scratch = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer scratch.deinit();
    st.gpa = scratch.allocator();
    st.remember_seeds = false;
    var pending: std.ArrayList(u8) = .empty;
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = io.readSome(&buf);
        if (n == 0) break;
        try pending.appendSlice(a, buf[0..n]);
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, pending.items, start, '\n')) |nl| {
            const r = try st.redact(pending.items[start .. nl + 1]);
            try io.writeStdout(r.out);
            _ = scratch.reset(.retain_capacity);
            start = nl + 1;
        }
        // Keep the partial last line; drop what was written.
        const rest = pending.items[start..];
        std.mem.copyForwards(u8, pending.items[0..rest.len], rest);
        pending.shrinkRetainingCapacity(rest.len);
    }
    if (pending.items.len > 0) {
        const r = try st.redact(pending.items);
        try io.writeStdout(r.out);
    }
}
