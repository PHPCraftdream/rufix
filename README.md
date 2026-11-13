# rufix

[![CI](https://github.com/PHPCraftdream/rufix/actions/workflows/ci.yml/badge.svg)](https://github.com/PHPCraftdream/rufix/actions/workflows/ci.yml)
[![License: MIT OR Apache-2.0](https://img.shields.io/badge/License-MIT_OR_Apache--2.0-blue.svg)](#license)
[![Zig 0.16](https://img.shields.io/badge/Zig-0.16-f7a41d?logo=zig&logoColor=white)](https://ziglang.org)

Keep secrets and internal hosts out of the model context in Claude Code.

`rufix` is a single small binary (about 200 KiB, written in Zig, no
dependencies) that acts as a pair of
[Claude Code hooks](https://code.claude.com/docs/en/hooks): it redacts tool
output before it reaches the model, and restores placeholders in commands and
local file edits that legitimately target your internal hosts. Optionally it
also wraps the shell of chosen repositories, so even the output of a failing
command is redacted. The installer is built into the binary.

## Why

When Claude Code reads files, runs commands or calls MCP servers, the raw
output — with your tokens and internal hostnames — is sent verbatim to the
model provider. rufix closes that channel:

- known values (compiled into the binary; env files are opt-in) become
  **reversible** `[S:hash8]` placeholders;
- filters (regex rules you define) mask or redact everything else, optionally
  reversibly (`*.example.com` ↔ `*.intra`), with the letter case preserved;
- the tool output shape is preserved exactly, so the hook replacement is
  always accepted;
- any internal error blocks the tool call — fail-closed.

```
in:   Bearer rufix_test_code_secret_number_001 at https://jira.internal.example/x
out:  Bearer [S:173410ad] at [S:95132e89]/x
```

## How it works

| Hook | Matcher | Action |
|---|---|---|
| `PostToolUse` | all tools | deep string walk over the tool response → `updatedToolOutput` / `updatedMCPToolOutput` (MCP object keys are masked too) |
| `PreToolUse` | `Bash` | if the command references a protected host, restore all placeholders in it (`updatedInput`) |
| `PreToolUse` | `Write`, `Edit`, `MultiEdit`, `NotebookEdit`, `Read`, `Grep`, `Glob` | same restore, gated on any string argument referencing a protected host |
| `PreToolUse` | `mcp__*` | domain-only restore: masked names become real in comments/links; `[S:hash]` credentials are never restored into MCP arguments |

Placeholders the model prints back are inert: a call is restored only when it
references something the allowlist honours — a protected-host placeholder or
a mask of an `allowlist_seed` filter — so a secret cannot be smuggled to a
foreign host. Web tools and every other tool restore nothing. Only values that
come from a URL count as hosts; a credential that contains a dot never does.

The PreToolUse matcher is the regex
`^(Bash|Write|Edit|MultiEdit|NotebookEdit|Read|Grep|Glob)$|^mcp__`: Claude Code
reads a matcher of plain names and `|` as exact names, so a bare `mcp__` would
match no MCP tool.

### Shell wrapper (per repository)

PostToolUse runs only for successful tools, so the output of a Bash command
that exits non-zero would reach the model unmasked. In a repository:

```bash
rufix install --project --shell
```

copies the binary to `rufix-shell` next to itself and sets
`CLAUDE_CODE_SHELL_PREFIX` in that repository's `.claude/settings.local.json`.
Claude Code then runs every shell command through `rufix-shell`: Bash tool
calls (recognised by Claude Code's shell-snapshot preamble) run with stdout
and stderr masked line by line and their exit code kept; hooks, the status
line and MCP server start-up pass through untouched. The wrapper is never
installed globally, and it never replaces a prefix that points elsewhere.
`rufix uninstall --project` removes it again.

## Install

Requires [Zig 0.16](https://ziglang.org/download/).

```bash
./install.sh                     # sh: Linux, macOS, Git Bash
install.cmd                      # Windows cmd.exe (runs install.ps1)
./install.sh --project --shell   # hooks + shell wrapper for this repository only
./install.sh --revert            # uninstall hooks and remove the binaries
```

The installer builds `zig build` (ReleaseSmall), copies the binary to
`$RUFIX_BIN_DIR` (default `~/.local/bin`, on Windows
`%LOCALAPPDATA%\rufix\bin`) and runs `rufix install` and `rufix check` from
there, so the hook commands reference that absolute path. Every install fully
reinstalls the rufix entries and keeps foreign hooks; `rufix status` reports
`stale` when an entry differs from what this binary installs.

Flags: `--project` (repository settings instead of `~/.claude/settings.json`),
`--env-files` (hooks also load env files), `--shell` (needs `--project`),
`--revert`.

## Replacement data

Your values and filters live in `secrets/values.zig` (git ignores `secrets/`);
without it the empty committed skeleton `src/values.zig` is compiled and
nothing is replaced. Same shape as the skeleton:

```zig
pub const vars = .{
    .{ "JIRA_TOKEN", "..." },
    .{ "JIRA_URL", "https://jira.example.com" },
};

pub const rules = .{
    .{
        .name = "com-to-intra",
        .match = "(?i)\\b((?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\\.)+)com\\b",
        .replace = "${1}intra",
        .restore_match = "(?i)\\b((?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\\.)+)intra\\b",
        .restore_replace = "${1}com",
        .allowlist_seed = true,
        .preserve_case = true,
    },
};
```

- `vars`: names with `TOKEN`/`SECRET`/`PASSWORD`/`PASSWD`/`PAT`/`KEY`/
  `CREDENTIAL` parts protect the whole value (6+ bytes); URL values protect the
  URL, its host with and without port and a userinfo password.
- `rules`: RE2 syntax as in Go's `regexp` (no lookaround, `\b` is ASCII);
  `${n}` templates; `strict_tld` rejects a match followed by `.label`;
  `preserve_case` carries the letter case into the mask and back. Unicode
  classes (`\p{..}`) and case folding outside Latin/Greek/Cyrillic are
  rejected at build time rather than matched partially.

Values are compiled into the binary: **never distribute the executable**.
Rebuild (re-run the installer) after editing the file.

### Optional env files

`--env-files` (on `hook`, `install`, `check`) also reads `KEY=VALUE` files:
`$RUFIX_ENV_FILE` → `$RUFIX_SECRETS_DIR` → a folder with `.atlassian.env`
walking up from the hook's cwd → `<exe dir>/secrets` →
`~/.config/rufix/secrets`. Compiled values override external files.

## CLI

```
rufix hook [--env-files]                       process hook stdin JSON
rufix install [--project] [--env-files] [--shell]
rufix uninstall [--project]
rufix status [--project]                       installed / stale / not installed
rufix check [--project] [--env-files]          counts + fake-pattern demo, never real values
rufix version
```

## Fail-closed behaviour

Any internal error in hook mode exits 2 without stdout, so Claude Code blocks
the tool call; hook entries carry `onFailure: "block"`.

## What rufix does NOT protect

- **User prompts, CLAUDE.md, conversation history** — they reach the model
  before any hook.
- **The local session transcript and local telemetry** see original output.
- **Failed tool calls outside the shell wrapper**: without
  `--shell`, a failing Bash command's output reaches the model unmasked, and
  MCP error results always do.
- **`@` file mentions** bypass hooks; `CLAUDE_CODE_DISABLE_FILE_MENTIONS=1`
  turns them off.
- **A stale binary**: re-run the installer after editing `secrets/values.zig`.
- **Text your filters do not match** (`\b` does not separate `_` or letters).

## Development

```bash
zig build test      # conformance fixtures, CLI scenarios, repository linter
zig build           # release binary in zig-out/bin
```

[conformance/](conformance/README.md) holds the behaviour contract as JSON
fixtures (engine, hook, installer, regex dialect, CLI). The linter keeps every
file at most 500 lines and every folder except the root at most 7 entries.
See [AGENTS.md](AGENTS.md) for architecture and invariants.

## License

Dual-licensed under [MIT](LICENSE-MIT) OR [Apache-2.0](LICENSE-APACHE); see
[docs/licensing.md](docs/licensing.md).
