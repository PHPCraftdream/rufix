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
    \\  rufix install [--project] [--env-files] [--shell] [--mod]
    \\                            add hooks to ~/.claude/settings.json (default) or
    \\                            ./.claude/settings.json with --project; --shell also
    \\                            wraps this repository's shell (.claude/settings.local.json);
    \\                            --mod adds a mod masking your prompts and failed tool
    \\                            output (.claude/skills/rufix); both need --project
    \\  rufix redact [--env-files]  mask stdin to stdout (what the mod calls)
    \\  rufix uninstall [--project]
    \\  rufix status  [--project]
    \\  rufix check   [--project] [--env-files]
    \\                            secrets stats + fake-pattern demo (never prints real values)
    \\  rufix version
    \\
    \\Install: ./install.sh (or install.cmd) builds with `zig build`, copies the
    \\binary to ~/.local/bin and runs `rufix install` from there, so settings.json
    \\references that path. Full uninstall: ./install.sh --revert.
    \\
    \\Replacements use compiled values.zig only by default. --env-files enables
    \\$RUFIX_ENV_FILE, $RUFIX_SECRETS_DIR, .atlassian.env walking up from the hook
    \\cwd, <exe dir>/secrets, then ~/.config/rufix/secrets as fallbacks.
    \\Compiled values override external files. Never distribute a private binary.
    \\
;

// ---------- flags (-name, --name, -name=value; bools take true/false) ----------

const FlagSpec = struct { name: []const u8, is_bool: bool };

const Flags = struct {
    bools: std.StringHashMap(bool),
    strings: std.StringHashMap([]const u8),
    rest: []const []const u8,
};

fn parseBool(v: []const u8) ?bool {
    for ([_][]const u8{ "1", "t", "T", "TRUE", "true", "True" }) |x| if (std.mem.eql(u8, v, x)) return true;
    for ([_][]const u8{ "0", "f", "F", "FALSE", "false", "False" }) |x| if (std.mem.eql(u8, v, x)) return false;
    return null;
}

fn parseFlags(a: std.mem.Allocator, args: []const []const u8, specs: []const FlagSpec) !Flags {
    var f = Flags{ .bools = .init(a), .strings = .init(a), .rest = &.{} };
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
        const spec = for (specs) |s| {
            if (std.mem.eql(u8, s.name, name)) break s;
        } else return error.UnknownFlag;
        if (spec.is_bool) {
            const b = if (value) |v| parseBool(v) orelse return error.InvalidFlagValue else true;
            try f.bools.put(spec.name, b);
        } else {
            if (value == null) {
                if (i >= args.len) return error.MissingFlagValue;
                value = args[i];
                i += 1;
            }
            try f.strings.put(spec.name, value.?);
        }
    }
    f.rest = args[i..];
    return f;
}

// ---------- store ----------

fn compiledVars(a: std.mem.Allocator, base: []const engine.Var) ![]const engine.Var {
    // Compiled values override external files (secretvalues.Overlay).
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

fn buildStore(a: std.mem.Allocator, vars: []const engine.Var) !engine.Store {
    var failed: usize = 0;
    const rules = engine.compileRules(a, &compiled_rules, &failed) catch |err| {
        if (err == error.OutOfMemory) return err;
        return error.InvalidFilter;
    };
    return .{ .gpa = a, .exact = try engine.buildExact(a, vars), .rules = rules };
}

// ---------- commands ----------

fn runHook(a: std.mem.Allocator, args: []const []const u8) u8 {
    const flags = parseFlags(a, args, &.{.{ .name = "env-files", .is_bool = true }}) catch |err| {
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
        const path = envfile.resolve(a, req.cwd, exe, home) catch return hook.blocking(a, out, "resolve secrets");
        if (path.len > 0) {
            base = envfile.load(a, path) catch |err| {
                return hook.blocking(a, out, std.fmt.allocPrint(a, "load secrets {s}: {s}", .{ path, @errorName(err) }) catch "load secrets");
            };
        } else {
            out.stderr.appendSlice(a, "rufix: secrets file not found; using compiled values with format rules\n") catch {};
        }
    }
    const vars = compiledVars(a, base) catch return hook.blocking(a, out, "out of memory");
    var st = buildStore(a, vars) catch |err| return hook.blocking(a, out, @errorName(err));
    return hook.handle(a, &st, req, out);
}

const settings_flags = [_]FlagSpec{
    .{ .name = "project", .is_bool = true },
    .{ .name = "path", .is_bool = false },
    .{ .name = "env-files", .is_bool = true },
    .{ .name = "shell", .is_bool = true },
    .{ .name = "mod", .is_bool = true },
};

const Settings = struct {
    o: install.Options,
    /// Settings of one repository (--project or --path), not the user's.
    repository: bool,
    shell: bool,
    mod: bool,
};

fn parseSettings(a: std.mem.Allocator, args: []const []const u8) !Settings {
    const f = try parseFlags(a, args, &settings_flags);
    if (f.rest.len != 0) return error.UnexpectedSettingsArguments;
    var path = f.strings.get("path") orelse "";
    const project = f.bools.get("project") orelse false;
    const repository = project or path.len > 0;
    if (path.len == 0) {
        const base = if (project) try os.cwd(a) else try os.home(a);
        path = try os.join(a, try os.join(a, base, ".claude"), "settings.json");
    }
    return .{
        .o = .{ .path = path, .exe_dir = try os.exeDir(a), .env_files = f.bools.get("env-files") orelse false },
        .repository = repository,
        .shell = f.bools.get("shell") orelse false,
        .mod = f.bools.get("mod") orelse false,
    };
}

fn runSettings(a: std.mem.Allocator, action: []const u8, args: []const []const u8) !void {
    const s = try parseSettings(a, args);
    const o = s.o;
    // The shell prefix wraps every command Claude Code runs: it is only ever
    // installed into one repository, never into the user's settings.
    if (s.shell and !s.repository) return error.ShellNeedsProject;
    if (s.mod and !s.repository) return error.ModNeedsProject;
    const summary = if (std.mem.eql(u8, action, "install"))
        try install.install(a, o)
    else if (std.mem.eql(u8, action, "uninstall"))
        try install.uninstall(a, o)
    else
        try install.status(a, o);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, try std.fmt.allocPrint(a, "rufix {s}: {s}\n", .{ action, summary }));
    if (std.mem.eql(u8, action, "install")) {
        try out.appendSlice(a, "rufix note: [S:xxxxxxxx] in tool output is a redacted value; it resolves automatically when a Bash command or local file-tool call references a protected host.\n");
        if (s.shell) {
            const line = try shellinstall.install(a, o.path, try os.exePath(a), o.env_files);
            try out.appendSlice(a, try std.fmt.allocPrint(a, "rufix shell: {s}\n", .{line}));
        }
        if (s.mod) {
            const line = try modinstall.install(a, o.path, try os.exePath(a), o.env_files);
            try out.appendSlice(a, try std.fmt.allocPrint(a, "rufix mod: {s}\n", .{line}));
        }
    } else if (s.repository and std.mem.eql(u8, action, "uninstall")) {
        const line = try shellinstall.uninstall(a, o.path);
        if (!std.mem.eql(u8, line, "no shell prefix")) try out.appendSlice(a, try std.fmt.allocPrint(a, "rufix shell: {s}\n", .{line}));
        const mod_line = try modinstall.uninstall(a, o.path);
        if (!std.mem.eql(u8, mod_line, "no mod")) try out.appendSlice(a, try std.fmt.allocPrint(a, "rufix mod: {s}\n", .{mod_line}));
    } else if (s.repository and std.mem.eql(u8, action, "status")) {
        if (try shellinstall.status(a, o.path)) try out.appendSlice(a, "rufix shell: on\n");
        if (try modinstall.status(a, o.path)) try out.appendSlice(a, "rufix mod: on\n");
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
    const f = try parseFlags(a, args, &.{.{ .name = "env-files", .is_bool = true }});
    if (f.rest.len != 0) return error.UnexpectedFilterArguments;
    var st = try loadStore(a, f.bools.get("env-files") orelse false, try os.cwd(a));
    const r = try st.redact(try io.readStdin(a));
    try io.writeStdout(r.out);
}

fn runFilter(a: std.mem.Allocator, args: []const []const u8) !void {
    const f = try parseFlags(a, args, &.{.{ .name = "env-files", .is_bool = true }});
    if (f.rest.len != 0) return error.UnexpectedFilterArguments;
    const env_files = (f.bools.get("env-files") orelse false) or
        std.mem.eql(u8, try os.getenv(a, shellinstall.env_files_key), "1");
    var st = try loadStore(a, env_files, try os.cwd(a));
    try shell.filter(a, &st);
}

fn runCheck(a: std.mem.Allocator, args: []const []const u8) !void {
    const o = (try parseSettings(a, args)).o;
    const status = try install.status(a, o);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, try std.fmt.allocPrint(a, "settings: {s} ({s})\n", .{ o.path, status }));
    var base: []const engine.Var = &.{};
    var source: []const u8 = "compiled";
    if (o.env_files) {
        const path = try envfile.resolve(a, try os.cwd(a), o.exe_dir, try os.home(a));
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

fn message(err: anyerror) []const u8 {
    return switch (err) {
        error.ShellNeedsProject => "--shell installs into one repository only: add --project (or --path)",
        error.ModNeedsProject => "--mod installs into one repository only: add --project (or --path)",
        error.ForeignShellPrefix => "CLAUDE_CODE_SHELL_PREFIX already points at another program; remove it first",
        error.EnvNotAnObject => "settings \"env\" is not an object; fix it by hand",
        error.HooksNotAnObject => "settings \"hooks\" is not an object; fix it by hand",
        error.EventNotAList => "a settings hooks event is not a list; fix it by hand",
        error.SyntaxError => "settings file is not valid JSON",
        error.UnknownFlag, error.BadFlagSyntax, error.InvalidFlagValue, error.MissingFlagValue => "invalid flags",
        error.UnexpectedSettingsArguments => "unexpected settings arguments",
        error.InvalidFilter => "a compiled filter does not compile",
        else => @errorName(err),
    };
}

fn fatal(a: std.mem.Allocator, err: anyerror) u8 {
    io.writeStderr(std.fmt.allocPrint(a, "rufix: {s}\n", .{message(err)}) catch "rufix: error\n");
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
