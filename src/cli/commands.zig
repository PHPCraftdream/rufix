//! rufix CLI: hook, install, uninstall, status, check, version, shell and
//! filter. Values and filters come from values.zig.
const std = @import("std");
const json = @import("../core/json.zig");
const engine = @import("../core/engine.zig");
const hook = @import("../hooks/hook.zig");
const install = @import("../hooks/install.zig");
const io = @import("../platform/io.zig");
const os = @import("../platform/os.zig");
const envfile = @import("../platform/envfile.zig");
const shell = @import("../hooks/shell.zig");
const shellinstall = @import("../hooks/shellinstall.zig");
const modinstall = @import("../hooks/modinstall.zig");
const local = @import("../hooks/local.zig");
const values = @import("values");

/// values.zig (the committed skeleton or secrets/values.zig) as engine data.
const compiled_vars = blk: {
    var out: [values.vars.len]engine.Var = undefined;
    for (&out, 0..) |*slot, i| slot.* = .{ .key = values.vars[i][0], .value = values.vars[i][1] };
    break :blk out;
};

const compiled_rules = blk: {
    var out: [values.rules.len]engine.RuleSpec = undefined;
    for (&out, 0..) |*slot, i| slot.* = toSpec(values.rules[i]);
    break :blk out;
};

fn toSpec(comptime r: anytype) engine.RuleSpec {
    var s = engine.RuleSpec{ .name = r.name, .match = r.match, .replace = r.replace };
    const T = @TypeOf(r);
    if (@hasField(T, "restore_match")) s.restore_match = r.restore_match;
    if (@hasField(T, "restore_replace")) s.restore_replace = r.restore_replace;
    if (@hasField(T, "allowlist_seed")) s.allowlist_seed = r.allowlist_seed;
    if (@hasField(T, "strict_tld")) s.strict_tld = r.strict_tld;
    if (@hasField(T, "preserve_case")) s.preserve_case = r.preserve_case;
    if (@hasField(T, "until_stable")) s.until_stable = r.until_stable;
    return s;
}

const version = "rufix 0.1.0";

const usage =
    \\rufix — keep secrets out of the model context
    \\
    \\Usage:
    \\  rufix hook [--env-files]   run as a Claude Code hook (dispatches on stdin JSON)
    \\  rufix install [--env-files] [--here]
    \\                            set up the current folder (a repository root; --here
    \\                            allows a subfolder of one), nothing else: the hooks and
    \\                            the shell wrapper go to .claude/settings.local.json and a
    \\                            mod (masks your prompts and failed tool output) to
    \\                            .claude/skills/rufix; they name this binary
    \\  rufix redact [--env-files]  mask stdin to stdout (what the mod calls)
    \\  rufix uninstall           take all of that out of the current folder
    \\  rufix status
    \\  rufix check   [--env-files]
    \\                            secrets stats + fake-pattern demo (never prints real values)
    \\  rufix uninstall --global  one-off: remove hooks older versions put into ~/.claude
    \\  rufix version
    \\
    \\Install: ./install.sh (or install.cmd) builds with `zig build` and puts rufix on the
    \\PATH, once per machine; then run `rufix install` in each repository to protect.
    \\Remove: `rufix uninstall` in a repository, ./install.sh --uninstall for the machine.
    \\
    \\Replacements use compiled values.zig only by default. --env-files enables
    \\$RUFIX_ENV_FILE, $RUFIX_SECRETS_DIR, .atlassian.env walking up from the hook
    \\cwd, <exe dir>/secrets, then ~/.config/rufix/secrets as fallbacks.
    \\Compiled values override external files. Never distribute a private binary.
    \\
;

// ---------- flags (-name, --name, -name=value; bools take true/false) ----------

const Flags = struct {
    bools: std.StringHashMap(bool),
    rest: []const []const u8,
};

const env_files_flag = [_][]const u8{"env-files"};

fn parseBool(v: []const u8) ?bool {
    for ([_][]const u8{ "1", "t", "T", "TRUE", "true", "True" }) |x| if (std.mem.eql(u8, v, x)) return true;
    for ([_][]const u8{ "0", "f", "F", "FALSE", "false", "False" }) |x| if (std.mem.eql(u8, v, x)) return false;
    return null;
}

/// Every flag is a bool, named in `known`; the rest of the arguments follow.
fn parseFlags(a: std.mem.Allocator, args: []const []const u8, known: []const []const u8) !Flags {
    var f = Flags{ .bools = .init(a), .rest = &.{} };
    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (arg.len < 2 or arg[0] != '-') break;
        var name = arg[1..];
        if (name[0] == '-') {
            name = name[1..];
            if (name.len == 0) {
                i += 1; // "--" ends the flags
                break;
            }
        }
        if (name.len == 0 or name[0] == '-' or name[0] == '=') return error.BadFlagSyntax;
        i += 1;
        var value: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, name, '=')) |eq| {
            value = name[eq + 1 ..];
            name = name[0..eq];
        }
        const flag = for (known) |k| {
            if (std.mem.eql(u8, k, name)) break k;
        } else return error.UnknownFlag;
        const b = if (value) |v| parseBool(v) orelse return error.InvalidFlagValue else true;
        try f.bools.put(flag, b);
    }
    f.rest = args[i..];
    return f;
}

// ---------- store ----------

fn compiledVars(a: std.mem.Allocator, base: []const engine.Var) ![]const engine.Var {
    // A compiled value overrides an external one of the same name.
    var out: std.ArrayList(engine.Var) = .empty;
    for (base) |v| {
        var overridden = false;
        for (compiled_vars) |c| if (c.value.len > 0 and std.mem.eql(u8, c.key, v.key)) {
            overridden = true;
        };
        if (!overridden) try out.append(a, v);
    }
    for (compiled_vars) |c| if (c.value.len > 0) try out.append(a, c);
    return out.items;
}

/// Index of the compiled filter that did not compile: the error names the
/// filter by its place in values.zig, never by its text.
var bad_filter: usize = 0;

fn buildStore(a: std.mem.Allocator, vars: []const engine.Var) !engine.Store {
    const rules = engine.compileRules(a, &compiled_rules, &bad_filter) catch |err| {
        if (err == error.OutOfMemory) return err;
        return error.InvalidFilter;
    };
    return .{ .gpa = a, .exact = try engine.buildExact(a, vars), .rules = rules };
}

// ---------- commands ----------

fn runHook(a: std.mem.Allocator, args: []const []const u8) u8 {
    const flags = parseFlags(a, args, &env_files_flag) catch |err| {
        io.writeStderr(std.fmt.allocPrint(a, "rufix: {s}\n", .{@errorName(err)}) catch "rufix: bad flags\n");
        return 2;
    };
    if (flags.rest.len != 0) {
        io.writeStderr("rufix: unexpected hook arguments\n");
        return 2;
    }
    var out = hook.Output{};
    const code = hookInner(a, flags.bools.get("env-files") orelse false, &out);
    io.writeStdout(out.stdout.items) catch return 2;
    io.writeStderr(out.stderr.items);
    return code;
}

fn hookInner(a: std.mem.Allocator, env_files: bool, out: *hook.Output) u8 {
    const stdin = io.readStdin(a) catch return hook.blocking(a, out, "read stdin");
    const req = hook.decodeRequest(a, stdin) catch |err| {
        return hook.blocking(a, out, std.fmt.allocPrint(a, "parse hook JSON: {s}", .{@errorName(err)}) catch "parse hook JSON");
    };
    var base: []const engine.Var = &.{};
    if (env_files) {
        const exe = os.exeDir(a) catch "";
        const home = os.home(a) catch "";
        const path = envfile.resolve(a, req.cwd, exe, home) catch return hook.failed(a, req, out, "resolve secrets");
        if (path.len > 0) {
            base = envfile.load(a, path) catch |err| {
                return hook.failed(a, req, out, std.fmt.allocPrint(a, "load secrets {s}: {s}", .{ path, @errorName(err) }) catch "load secrets");
            };
        } else {
            out.stderr.appendSlice(a, "rufix: secrets file not found; using compiled values with format rules\n") catch {};
        }
    }
    // From here on the request is known: a failure of ours still has to keep
    // the original tool output away from the model (see hook.failed).
    const vars = compiledVars(a, base) catch return hook.failed(a, req, out, "out of memory");
    var st = buildStore(a, vars) catch |err| return hook.failed(a, req, out, message(a, err));
    return hook.handle(a, &st, req, out);
}

const settings_flags = [_][]const u8{ "global", "here", "env-files" };

const Settings = struct {
    o: install.Options,
    /// The repository rufix works on: the current folder.
    repo: []const u8,
    /// The user's own ~/.claude/settings.json, where older versions wrote hooks.
    global: bool,
};

fn parseSettings(a: std.mem.Allocator, args: []const []const u8) !Settings {
    const f = try parseFlags(a, args, &settings_flags);
    if (f.rest.len != 0) return error.UnexpectedSettingsArguments;
    const global = f.bools.get("global") orelse false;
    const repo = try os.cwd(a);
    // Claude Code reads .claude/ from the folder it starts in, normally the
    // repository root: a subfolder would be set up for nothing.
    const here = f.bools.get("here") orelse false;
    if (!global and !here and local.isSubfolder(a, repo, "")) return error.InsideRepository;
    // The hooks name the binary that is running: the installed one.
    return .{
        .o = .{
            .path = if (global) try local.sharedSettings(a, try os.home(a)) else try local.settingsPath(a, repo),
            .exe_dir = try os.exeDir(a),
            .env_files = f.bools.get("env-files") orelse false,
        },
        .repo = repo,
        .global = global,
    };
}

fn say(a: std.mem.Allocator, out: *std.ArrayList(u8), tag: []const u8, text: []const u8) !void {
    try out.appendSlice(a, try std.fmt.allocPrint(a, "rufix {s}: {s}\n", .{ tag, text }));
}

/// Older versions wrote the hooks into the shared .claude/settings.json: take
/// our entries out of it (best effort, foreign entries stay).
fn legacyHooks(a: std.mem.Allocator, out: *std.ArrayList(u8), repo: []const u8) !void {
    const path = try local.sharedSettings(a, repo);
    if (!os.exists(a, path)) return;
    const r = install.uninstall(a, .{ .path = path, .exe_dir = "" }) catch |err| {
        return say(a, out, "legacy", try std.fmt.allocPrint(a, "{s} left alone: {s}", .{ path, message(a, err) }));
    };
    if (std.mem.startsWith(u8, r, "removed")) try say(a, out, "legacy", r);
}

/// A line when the user's own settings still hold the hooks of an older,
/// global install: they apply to every repository, run beside the
/// repository's own and may name a binary that is gone.
fn globalNote(a: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    const path = local.sharedSettings(a, os.home(a) catch return) catch return;
    if (!os.exists(a, path)) return;
    const state = install.status(a, .{ .path = path, .exe_dir = "" }) catch return;
    if (std.mem.startsWith(u8, state, "not installed")) return;
    try say(a, out, "global", try std.fmt.allocPrint(a, "older hooks are still in {s}; remove them: rufix uninstall --global", .{path}));
}

fn runSettings(a: std.mem.Allocator, action: []const u8, args: []const []const u8) !void {
    const s = try parseSettings(a, args);
    const o = s.o;
    const installing = std.mem.eql(u8, action, "install");
    // rufix is set up in one repository only; --global is for clearing out
    // what older versions put into the user's settings.
    if (s.global and installing) return error.GlobalIsCleanupOnly;
    var out: std.ArrayList(u8) = .empty;
    if (installing) {
        // The hooks, the shell prefix and the mod name the installed binary.
        const exe = try os.exePath(a);
        // Refuse before the first write: hooks without the shell prefix (or the
        // mod) would be a protection the user thinks is whole.
        try shellinstall.check(a, o.path);
        try say(a, &out, action, try install.install(a, o));
        try legacyHooks(a, &out, s.repo);
        try out.appendSlice(a, "rufix note: [S:xxxxxxxx] in tool output is a redacted value; it resolves automatically when a Bash command or local file-tool call references a protected host.\n");
        try say(a, &out, "shell", try shellinstall.install(a, o.path, exe, o.env_files));
        try say(a, &out, "mod", try modinstall.install(a, o.path, exe, o.env_files));
        try globalNote(a, &out);
    } else if (std.mem.eql(u8, action, "uninstall")) {
        try say(a, &out, action, try install.uninstall(a, o));
        if (!s.global) {
            try legacyHooks(a, &out, s.repo);
            const shell_line = try shellinstall.uninstall(a, o.path);
            if (!std.mem.eql(u8, shell_line, "no shell prefix")) try say(a, &out, "shell", shell_line);
            const mod_line = try modinstall.uninstall(a, o.path);
            if (!std.mem.eql(u8, mod_line, "no mod")) try say(a, &out, "mod", mod_line);
        }
    } else {
        try say(a, &out, action, try install.status(a, o));
        if (!s.global) {
            if (try shellinstall.status(a, o.path)) try out.appendSlice(a, "rufix shell: on\n");
            if (try modinstall.status(a, o.path)) try out.appendSlice(a, "rufix mod: on\n");
            try globalNote(a, &out);
        }
    }
    try io.writeStdout(out.items);
}

/// Store from compiled values, plus env files when asked.
fn loadStore(a: std.mem.Allocator, env_files: bool, start: []const u8) !engine.Store {
    var base: []const engine.Var = &.{};
    if (env_files) {
        const path = try envfile.resolve(a, start, try os.exeDir(a), try os.home(a));
        if (path.len > 0) base = try envfile.load(a, path);
    }
    return buildStore(a, try compiledVars(a, base));
}

/// Masks all of stdin as one text (multi-line rules apply), for the mod.
fn runRedact(a: std.mem.Allocator, args: []const []const u8) !void {
    const f = try parseFlags(a, args, &env_files_flag);
    if (f.rest.len != 0) return error.UnexpectedFilterArguments;
    var st = try loadStore(a, f.bools.get("env-files") orelse false, try os.cwd(a));
    const r = try st.redact(try io.readStdin(a));
    try io.writeStdout(r.out);
}

fn runFilter(a: std.mem.Allocator, args: []const []const u8) !void {
    const f = try parseFlags(a, args, &env_files_flag);
    if (f.rest.len != 0) return error.UnexpectedFilterArguments;
    const env_files = (f.bools.get("env-files") orelse false) or
        std.mem.eql(u8, try os.getenv(a, shellinstall.env_files_key), "1");
    var st = try loadStore(a, env_files, try os.cwd(a));
    try shell.filter(a, &st);
}

/// What this binary protects: counts and a demo on fake patterns. It looks at
/// the binary only, not at any repository, so the installer can run it
/// anywhere; `status` reports a repository.
fn runCheck(a: std.mem.Allocator, args: []const []const u8) !void {
    const f = try parseFlags(a, args, &env_files_flag);
    if (f.rest.len != 0) return error.UnexpectedSettingsArguments;
    var out: std.ArrayList(u8) = .empty;
    var base: []const engine.Var = &.{};
    var source: []const u8 = "compiled";
    if (f.bools.get("env-files") orelse false) {
        const path = try envfile.resolve(a, try os.cwd(a), try os.exeDir(a), try os.home(a));
        if (path.len == 0) {
            try out.appendSlice(a, "env files: not found; using compiled values with format rules\n");
        } else {
            base = try envfile.load(a, path);
            source = "compiled + env files";
        }
    }
    const vars = try compiledVars(a, base);
    var st = try buildStore(a, vars);
    var hosts: usize = 0;
    for (st.exact) |e| {
        if (e.host) hosts += 1;
    }
    var compiled: usize = 0;
    for (compiled_vars) |v| {
        if (v.value.len > 0) compiled += 1;
    }
    try out.appendSlice(a, try std.fmt.allocPrint(a, "secrets: {s} (variables: {d}, protected values: {d}, protected hosts: {d}, format rules: {d}, compiled values: {d})\n", .{ source, vars.len, st.exact.len, hosts, st.rules.len, compiled }));
    const demo = "Bearer DEMOdemoDEMOdemo12 ATATT3DEMOtokenDEMOtoken12345 query ?token=DEMOdemoDEMOdemo1234";
    const r = try st.redact(demo);
    try out.appendSlice(a, try std.fmt.allocPrint(a, "demo: {d} replacements on fake patterns:\n  in:  {s}\n  out: {s}\n", .{ r.count, demo, r.out }));
    try io.writeStdout(out.items);
}

fn message(a: std.mem.Allocator, err: anyerror) []const u8 {
    return switch (err) {
        error.InsideRepository => "this folder is inside a repository: run rufix in the folder that holds .git (--here sets up this folder anyway)",
        error.GlobalIsCleanupOnly => "rufix is set up per repository, never in ~/.claude; --global only removes what older versions left there (uninstall, status)",
        error.ForeignShellPrefix => "CLAUDE_CODE_SHELL_PREFIX already points at another program; remove it first",
        error.EnvNotAnObject => "settings \"env\" is not an object; fix it by hand",
        error.HooksNotAnObject => "settings \"hooks\" is not an object; fix it by hand",
        error.EventNotAList => "a settings hooks event is not a list; fix it by hand",
        error.SyntaxError => "settings file is not valid JSON",
        error.UnknownFlag, error.BadFlagSyntax, error.InvalidFlagValue => "invalid flags",
        error.UnexpectedSettingsArguments => "unexpected settings arguments",
        error.InvalidFilter => std.fmt.allocPrint(a, "compiled filter {d} of values.zig (counting from 0) does not compile", .{bad_filter}) catch "a compiled filter does not compile",
        error.PlaceholderCollision => "two different protected values share one [S:...] placeholder; change one of them",
        else => @errorName(err),
    };
}

/// An error from a failed file or folder operation says which path it was.
fn failedOnPath(err: anyerror) bool {
    return err == error.OpenFailed or err == error.RenameFailed or err == error.ChmodFailed or
        err == error.MkdirFailed or err == error.RemoveFailed;
}

fn fatal(a: std.mem.Allocator, err: anyerror) u8 {
    const text = message(a, err);
    const line = if (failedOnPath(err) and os.failed_path.len > 0)
        std.fmt.allocPrint(a, "rufix: {s}: {s}\n", .{ text, os.failed_path })
    else
        std.fmt.allocPrint(a, "rufix: {s}\n", .{text});
    io.writeStderr(line catch "rufix: error\n");
    return 1;
}

fn isShellBinary(a: std.mem.Allocator) bool {
    const p = os.exePath(a) catch return false;
    return os.isExecutableNamed(p, "rufix-shell");
}

fn run(a: std.mem.Allocator, args: []const []const u8) u8 {
    // As rufix-shell this binary is Claude Code's shell prefix: one argument,
    // the command line; its own `filter` calls come back here too.
    if (isShellBinary(a)) {
        if (args.len >= 1 and std.mem.eql(u8, args[0], "filter")) {
            runFilter(a, args[1..]) catch |err| return fatal(a, err);
            return 0;
        }
        if (args.len != 1) {
            io.writeStderr("rufix-shell: expected one command line\n");
            return 2;
        }
        return shell.run(a, os.exePath(a) catch "", args[0]);
    }
    if (args.len >= 1 and std.mem.eql(u8, args[0], "filter")) {
        runFilter(a, args[1..]) catch |err| return fatal(a, err);
        return 0;
    }
    if (args.len >= 1 and std.mem.eql(u8, args[0], "redact")) {
        runRedact(a, args[1..]) catch |err| return fatal(a, err);
        return 0;
    }
    if (args.len == 2 and std.mem.eql(u8, args[0], "shell")) return shell.run(a, os.exePath(a) catch "", args[1]);
    if (args.len == 0) {
        io.writeStderr(usage);
        return 1;
    }
    const cmd = args[0];
    const rest = args[1..];
    if (std.mem.eql(u8, cmd, "hook")) return runHook(a, rest);
    if (std.mem.eql(u8, cmd, "install") or std.mem.eql(u8, cmd, "uninstall") or std.mem.eql(u8, cmd, "status")) {
        runSettings(a, cmd, rest) catch |err| return fatal(a, err);
        return 0;
    }
    if (std.mem.eql(u8, cmd, "check")) {
        runCheck(a, rest) catch |err| return fatal(a, err);
        return 0;
    }
    if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v")) {
        io.writeStdout(version ++ "\n") catch return 1;
        return 0;
    }
    io.writeStderr(usage);
    return 1;
}

pub fn main(argc: c_int, argv: [*][*:0]u8) c_int {
    io.init();
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    const a = arena.allocator();
    const args = os.args(a, argc, argv) catch return 1;
    return run(a, args);
}
