//! Per-repository Claude Code mod: `rufix install --project --mod` writes a
//! plugin into the repository's .claude/skills/rufix/, which Claude Code
//! loads for that project only. The mod masks what no settings hook can:
//! the user's own prompt (prompt.submit), the error text of a failed tool
//! (tool.call), the text the engine injects itself (prompt.attachment,
//! prompt.section, prompt.context), a skill's text (skill.prompt) and the task
//! given to a subagent (agent.spawn), all through `rufix redact`, failing closed.
const std = @import("std");
const io = @import("../platform/io.zig");
const os = @import("../platform/os.zig");
const json = @import("../core/json.zig");

/// Marks the files as ours, so uninstall never removes a folder it did not write.
pub const marker = "Written by `rufix install --project --mod`";

const manifest =
    \\{
    \\  "name": "rufix",
    \\  "version": "0.1.0",
    \\  "description": "Masks secrets in your prompts, in failed tool output and in text the engine injects before the model reads them (rufix)."
    \\}
    \\
;

const hooks_json =
    \\{ "modules": ["./register.ts"] }
    \\
;

const module_head = "// ";

const module_body =
    \\. Re-run it after moving the rufix binary.
    \\import type { Register } from 'claude-code'
    \\
    \\// The command that masks stdin to stdout with this machine's rules.
    \\
;

const module_tail =
    \\
    \\// Outside register: the engine refuses `$` handed to a function declared inside it.
    \\// Masked texts by input: the injected sections repeat on every request.
    \\const masked = new Map<string, string>()
    \\
    \\async function mask($: any, text: string): Promise<string> {
    \\  const known = masked.get(text)
    \\  if (known !== undefined) return known
    \\  const r = await $.process.run(RUFIX, { stdin: text, timeoutMs: 10000 })
    \\  if (r.exitCode !== 0 || r.isStdoutTruncated) throw new Error('rufix redact failed')
    \\  if (masked.size >= 500) masked.clear()
    \\  masked.set(text, r.stdout)
    \\  return r.stdout
    \\}
    \\
    \\export const register: Register = on => {
    \\  // What the engine injects beside your prompt (a changed working directory,
    \\  // mentioned files, reminders): no settings hook sees it. A failure drops it.
    \\  on('prompt.attachment', async ($, e, next) => {
    \\    const r = await next(e)
    \\    if (r.text === null) return r
    \\    return { ...r, text: await mask($, r.text) }
    \\  }).catch(() => ({ text: null }))
    \\
    \\  // The system prompt's sections (the working directory it starts in).
    \\  on('prompt.section', async ($, e, next) => {
    \\    const r = await next(e)
    \\    if (r.text === null) return r
    \\    return { ...r, text: await mask($, r.text) }
    \\  }).catch(() => ({ text: null }))
    \\
    \\  // The first message's context blocks (CLAUDE.md, git status, ...). Rewriting
    \\  // a block's text makes the instruction files behind it unknown to the engine.
    \\  on('prompt.context', async ($, e, next) => {
    \\    const r = await next(e)
    \\    const blocks = []
    \\    for (const b of r.blocks) blocks.push({ ...b, text: await mask($, b.text) })
    \\    return { ...r, blocks }
    \\  }).catch(() => ({ blocks: [] }))
    \\
    \\  // A skill's text goes to the model as its own event, whoever wrote the skill.
    \\  on('skill.prompt', async ($, e, next) => {
    \\    return next({ ...e, text: await mask($, e.text) })
    \\  }).catch(() => ({ text: 'rufix could not mask this skill, so it was withheld' }))
    \\
    \\  // The task handed to a subagent: it starts from this text, not from yours.
    \\  on('agent.spawn', async ($, e, next) => {
    \\    const prompt = await mask($, e.prompt)
    \\    const description = await mask($, e.description)
    \\    return next(prompt === e.prompt && description === e.description ? e : { ...e, prompt, description })
    \\  }).catch(($, e, next) =>
    \\    next.called ? next(e) : { deny: 'rufix could not mask this task, so the subagent was not started' },
    \\  )
    \\
    \\  // The user's own prompt: the model reads it masked. Slash commands pass.
    \\  on('prompt.submit', async ($, e, next) => {
    \\    if (e.command) return next(e)
    \\    const text = await mask($, e.text)
    \\    return next(text === e.text ? e : { ...e, text })
    \\  }).catch(($, e, next) =>
    \\    next.called ? next(e) : { drop: 'rufix could not mask this prompt, so it was not sent' },
    \\  )
    \\
    \\  // A failed tool's error text never reaches PostToolUse hooks: mask it here.
    \\  on('tool.call', async ($, e, next) => {
    \\    const r = await next(e)
    \\    if (!('isError' in r) || !r.isError || !r.text) return r
    \\    const text = await mask($, r.text)
    \\    return text === r.text ? r : { deny: text }
    \\  }).catch(($, e, next) =>
    \\    next.called ? { deny: 'rufix could not mask this error, so it was withheld' } : next(e),
    \\  )
    \\}
    \\
;

pub fn dir(a: std.mem.Allocator, settings_path: []const u8) ![]const u8 {
    // settings_path is <repo>/.claude/settings.json: the mod sits beside it.
    return os.join(a, try os.join(a, os.dir(settings_path), "skills"), "rufix");
}

fn jsString(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try json.writeString(a, &out, s);
    return out.items;
}

/// The hooks module with this binary's absolute path baked in.
pub fn moduleSource(a: std.mem.Allocator, exe_path: []const u8, env_files: bool) ![]const u8 {
    const exe = try os.toSlash(a, exe_path);
    var argv: std.ArrayList(u8) = .empty;
    try argv.appendSlice(a, "const RUFIX = [");
    try argv.appendSlice(a, try jsString(a, exe));
    try argv.appendSlice(a, ", 'redact'");
    if (env_files) try argv.appendSlice(a, ", '--env-files'");
    try argv.appendSlice(a, "]\n");
    return std.mem.concat(a, u8, &.{ module_head, marker, module_body, argv.items, module_tail });
}

pub fn install(a: std.mem.Allocator, settings_path: []const u8, exe_path: []const u8, env_files: bool) ![]const u8 {
    const root = try dir(a, settings_path);
    const plugin_dir = try os.join(a, root, ".claude-plugin");
    const hooks_dir = try os.join(a, root, "hooks");
    try os.mkdirAll(a, plugin_dir);
    try os.mkdirAll(a, hooks_dir);
    try io.writeFileAtomic(a, try os.join(a, plugin_dir, "plugin.json"), manifest, .data);
    try io.writeFileAtomic(a, try os.join(a, hooks_dir, "hooks.json"), hooks_json, .data);
    try io.writeFileAtomic(a, try os.join(a, hooks_dir, "register.ts"), try moduleSource(a, exe_path, env_files), .data);
    return std.fmt.allocPrint(a, "mod written to {s}", .{root});
}

fn module(a: std.mem.Allocator, settings_path: []const u8) ![]const u8 {
    return os.join(a, try os.join(a, try dir(a, settings_path), "hooks"), "register.ts");
}

/// True when the repository holds the mod this binary writes.
pub fn status(a: std.mem.Allocator, settings_path: []const u8) !bool {
    const data = try io.readFile(a, try module(a, settings_path)) orelse return false;
    return std.mem.indexOf(u8, data, marker) != null;
}

/// Removes the three files written by install, and the folders if they end
/// up empty; a folder holding anything else is left alone.
pub fn uninstall(a: std.mem.Allocator, settings_path: []const u8) ![]const u8 {
    if (!try status(a, settings_path)) return "no mod";
    const root = try dir(a, settings_path);
    const files = [_][2][]const u8{
        .{ "hooks", "register.ts" },
        .{ "hooks", "hooks.json" },
        .{ ".claude-plugin", "plugin.json" },
    };
    for (files) |f| try os.remove(a, try os.join(a, try os.join(a, root, f[0]), f[1]));
    for ([_][]const u8{ "hooks", ".claude-plugin" }) |sub| os.removeEmptyDir(a, try os.join(a, root, sub));
    os.removeEmptyDir(a, root);
    os.removeEmptyDir(a, os.dir(root)); // .claude/skills, when only the mod was there
    return std.fmt.allocPrint(a, "mod removed from {s}", .{root});
}
