# rufix

[![CI](https://github.com/PHPCraftdream/rufix/actions/workflows/ci.yml/badge.svg)](https://github.com/PHPCraftdream/rufix/actions/workflows/ci.yml)
[![License: MIT OR Apache-2.0](https://img.shields.io/badge/License-MIT_OR_Apache--2.0-blue.svg)](#license)
[![Zig 0.16](https://img.shields.io/badge/Zig-0.16-f7a41d?logo=zig&logoColor=white)](https://ziglang.org)

Keep secrets and internal hosts out of the model context in Claude Code.

`rufix` is a single small binary (about 200 KiB, written in Zig, no
dependencies) that acts as a pair of
[Claude Code hooks](https://code.claude.com/docs/en/hooks): it redacts tool
output before it reaches the model, and restores placeholders in commands and
local file edits that legitimately target your internal hosts. It also wraps
the repository's shell, so even the output of a failing command is redacted,
and masks your prompts through a mod. The binary is installed once per
machine (on the PATH); the protection is switched on per repository — `rufix
install` in a repository writes only that repository's `.claude/`, never
`~/.claude`. The setup is built into the binary.

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

### What `rufix install` writes

Run in a repository, `rufix install` writes only inside its `.claude/`:

| Path | Content |
|---|---|
| `.claude/settings.local.json` | the two hooks and `CLAUDE_CODE_SHELL_PREFIX` — the personal settings file, since they name this machine's binary |
| `.claude/skills/rufix/` | the mod, with its own `.gitignore` |

Both name the installed binary (and its `rufix-shell` twin beside it) by its
absolute path; the binary itself stays outside the repository, because it
holds your private values and must never be committed. Hooks left in the
shared `.claude/settings.json` by older versions are moved out. `rufix
uninstall` takes it all out again and leaves foreign entries, settings and
folders alone.

### Shell wrapper

PostToolUse runs only for successful tools, so the output of a Bash command
that exits non-zero would reach the model unmasked. `CLAUDE_CODE_SHELL_PREFIX`
makes Claude Code run every shell command through `rufix-shell`: Bash tool
calls (recognised by Claude Code's shell-snapshot preamble) run with stdout
and stderr masked line by line and their exit code kept; hooks, the status
line and MCP server start-up pass through untouched. It never replaces a
prefix that points elsewhere.

### Prompt and error mod

No settings hook can rewrite what the user types. A Claude Code
[mod](https://code.claude.com/docs/en/plugins/mods/events.md) can, so the
install writes one to `.claude/skills/rufix/`, which Claude Code loads for
that project only. The mod replaces nothing itself: it hands the text to the
binary (`rufix redact`), which applies the same direction as for files and
shell output — masking.

- **Your prompt** (`prompt.submit`): the model, the transcript and the prompt
  history get the masked text. Slash commands pass unchanged.
- **A failed tool's error** (`tool.call`): the error text, which no
  PostToolUse hook ever sees, reaches the model masked — for every tool, MCP
  included.
- **What the engine injects itself** (`prompt.attachment`, `prompt.section`,
  `prompt.context`): working-directory notices, `@`-mentioned files,
  CLAUDE.md and git status.
- **A skill's text** (`skill.prompt`) and **the task given to a subagent**
  (`agent.spawn`).
- **Fail-closed**: when masking fails, the prompt is not sent and the error
  is withheld.

The mod, the hooks and the shell prefix name the installed binary by its
absolute path: set a repository up again (`rufix install`) if the binary moves,
for instance after changing `RUFIX_BIN_DIR`.

## Install

Requires [Zig 0.16](https://ziglang.org/download/). Two steps: the binary goes
into the system once, then each repository you want protected is set up.

**1. The binary, once per machine** (from any folder):

```bash
/path/to/rufix/install.sh                  # sh: Linux, macOS, Git Bash
C:\path\to\rufix\install.cmd               # Windows cmd.exe (runs install.ps1)
```

The installer builds with `zig build` (ReleaseSmall) in the rufix folder and
puts `rufix` and its `rufix-shell` twin into `$RUFIX_BIN_DIR` (default
`~/.local/bin`, on Windows `%LOCALAPPDATA%\rufix\bin`), which it adds to the
PATH (a profile line in `~/.profile`, and in `~/.bashrc`, `~/.bash_profile`
and `~/.zshrc` where they exist; `~/.zshrc` is made on macOS or for a zsh login
shell, since zsh does not read `~/.profile`; the user's PATH in the registry on
Windows). Open a new terminal afterwards. Run it again
after editing `secrets/values.zig`: every repository then uses the new
binary at once. It touches no repository and nothing in `~/.claude`.

**2. Each repository** (in its root, the folder that holds `.git`):

```bash
cd /path/to/your/repo
rufix install                              # hooks, shell wrapper and mod for this repository
rufix install --env-files                  # the hooks also load env files
rufix status                               # installed / stale / not installed
```

`rufix install` fully reinstalls the rufix entries and keeps foreign hooks;
`rufix status` reports `stale` when an entry differs from what this binary
installs. Claude Code reads `.claude/` from the folder it starts in, so run it
in the repository's root: in a subfolder of a repository (a folder without its
own `.git` below one that has it) rufix refuses (`rufix install --here` sets up
that folder anyway, for a package with its own `.claude/`), and `status` and
`uninstall` refuse alike. A submodule or a nested checkout, which has its own
`.git`, is a root. Restart Claude Code in the repository to load the hooks and
the mod.

### Remove

```bash
rufix uninstall                            # in a repository: hooks, shell prefix, mod
/path/to/rufix/install.sh --uninstall      # the machine: binaries and PATH entry
C:\path\to\rufix\install.cmd --uninstall
```

Take rufix out of the repositories first: once the binary is gone their hooks
call a missing program, and that blocks every tool call there.

### Coming from older versions

Older versions wrote the hooks into `~/.claude/settings.json`, where they apply
to every repository, or into a repository's shared `.claude/settings.json`.
`rufix install` moves the repository ones out. For the user's own file run
`rufix uninstall --global` once (`install.sh --uninstall` does it too): it
removes only the hook entries that are rufix's. While such hooks remain,
`install` and `status` say so (`rufix global: older hooks are still in …`):
they would run beside the repository's own.

## Replacement data

Your values and filters live in `secrets/values.zig` (git ignores `secrets/`);
without it the committed skeleton `src/values.zig` is compiled and nothing is
replaced. The skeleton holds commented examples with fake names: copy them
into your file. Same shape as the skeleton:

```zig
const rule = @import("rules");

pub const vars = .{
    .{ "JIRA_TOKEN", "..." },
    .{ "JIRA_URL", "https://jira.example.com" },
};

pub const rules = .{
    rule.domain("acme", "zephyr"),
    rule.import("acme", "zephyr"),
    rule.path("acme", "zephyr"),
    rule.word("acme", "zephyr"),
};
```

- `vars`: names with `TOKEN`/`SECRET`/`PASSWORD`/`PASSWD`/`PASS`/`PWD`/`PAT`/
  `KEY`/`COOKIE`/`BEARER`/`CREDENTIAL` parts (a whole part: `DB_PASS`, not
  `COMPASS`) protect the whole value (6+ bytes); URL values protect the
  URL, its host with and without port and a userinfo password. A host that is a
  single word (`prod`) is masked as a word only, not inside `production`.
  Any other name is ignored: give a credential a name that says so.
- `rules`: each helper takes the real name and what the model sees, and makes
  one reversible rule that keeps the letter case and counts as
  protected-host evidence (`src/core/rules.zig`):

  | Helper | Makes | Example |
  |---|---|---|
  | `domain(from, to)` | `*.from` → `*.to` (`a.from.org` stays) | `api.acme` → `api.zephyr` |
  | `import(from, to)` | `from.` → `to.`, the first part of a dotted name | `acme.io` → `zephyr.io` |
  | `path(from, to)` | `from/` and `from\` → `to/` and `to\` | `acme/src` → `zephyr/src` |
  | `word(from, to)` | the bare word, also glued to `_` | `my_acme` → `my_zephyr` |

  A name holds ASCII letters, digits, `_`, `-` and `.`; anything else is a
  build error. Non-ASCII names are refused on purpose: `\b` is an ASCII
  boundary, so such a rule would compile and then never match.
- Anything else is a plain rule, `.{ .name, .match, .replace }` plus the
  optional `.restore_match`, `.restore_replace`, `.allowlist_seed`,
  `.strict_tld`, `.preserve_case` and `.until_stable` (see the skeleton): RE2
  syntax as in Go's `regexp` (no lookaround, `\b` is ASCII); `${n}` templates;
  `strict_tld` rejects a match followed by `.label`; `preserve_case` carries the
  letter case into the mask and back; `until_stable` re-applies a rule while it
  still changes the text (for matches that consume the delimiter the next one
  needs, such as `_`). Unicode classes (`\p{..}`) and case folding outside
  Latin/Greek/Cyrillic are rejected at build time rather than matched
  partially.

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
rufix install [--env-files] [--here]           set up the current folder (hooks, shell, mod)
rufix uninstall                                take that out of the current folder
rufix uninstall --global                       one-off: remove old hooks from ~/.claude
rufix redact [--env-files]                     mask stdin to stdout (what the mod calls)
rufix status                                   installed / stale / not installed
rufix check [--env-files]                      what this binary protects: counts + fake-pattern demo, never real values
rufix version
```

## Fail-closed behaviour

Any internal error in hook mode exits 2 without stdout. On `PreToolUse` that
blocks the tool call. On `PostToolUse` the tool has already run, and by Claude
Code's hooks documentation exit 2 there only shows the hook's message to the
model and blocks nothing: the original output would reach it. So when the
masking of a `PostToolUse` result fails (a rule that never settles, colliding
MCP keys, a filter that does not compile, an unreadable env file), rufix
answers with exit 0 and replaces the output by one of the same shape in which
every string is `[rufix: output withheld because masking failed]` (an MCP
result becomes that notice alone). Only input rufix cannot read at all still
exits 2.

Hook entries carry `onFailure: "block"`, which needs Claude Code 2.1.295 or
later: it makes a hook that crashes, times out or prints invalid output block
a `PreToolUse` call. An older version ignores it and lets the call through; and
whatever the version, a `PostToolUse` hook that does not run at all (it cannot
start, it is killed) leaves the output unmasked, which no code of rufix can
prevent.

## What rufix does NOT protect

- **Repositories where you did not run `rufix install`**: protection is per
  repository, and there is no global fallback. Prompts are masked only where
  the mod is installed; CLAUDE.md and earlier conversation history are not
  masked either way.
- **The local session transcript and local telemetry** see original output
  (with the mod, the transcript holds your prompt masked).
- **Failed tool calls when the mod or the shell wrapper is switched off**
  (for instance a foreign `CLAUDE_CODE_SHELL_PREFIX` blocks the wrapper): a
  failing Bash command's output and MCP error results then reach the model
  unmasked.
- **`@` file mentions** bypass hooks; `CLAUDE_CODE_DISABLE_FILE_MENTIONS=1`
  turns them off.
- **A `PostToolUse` hook that does not run** (it cannot start, it times out, an
  old Claude Code ignores `onFailure`; see Fail-closed above): the tool's output
  reaches the model unmasked.
- **A short or guessable value behind a placeholder**: `[S:hash8]` is the first
  32 bits of the value's SHA-256, unsalted, so someone who can guess the value
  (a short password, a common host name) can confirm the guess against it.
- **Where a restored value goes**: a Bash command or file-tool call that holds
  one protected-host placeholder gets every `[S:...]` in it restored, whatever
  the command does with them.
- **A variable whose name says nothing**: only names with a credential part
  (`TOKEN`, `PASS`, `KEY`, ...) or URL values are protected.
- **A stale binary**: re-run the installer after editing `secrets/values.zig`.
- **Text your filters do not match** (`\b` does not separate `_` or letters).

## Development

```bash
zig build test      # conformance fixtures, CLI scenarios, repository linter
zig build           # release binary in zig-out/bin
```

[conformance/](conformance/README.md) holds the behaviour contract as JSON
fixtures (engine, rule helpers, hook, installer, regex dialect, CLI). The linter keeps every
file at most 500 lines and every folder except the root at most 7 entries.
See [AGENTS.md](AGENTS.md) for architecture and invariants.

## License

Dual-licensed under [MIT](LICENSE-MIT) OR [Apache-2.0](LICENSE-APACHE); see
[docs/licensing.md](docs/licensing.md).
