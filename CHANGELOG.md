# Changelog

All notable changes to rufix are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- rufix is rewritten in Zig 0.16 and the Go implementation is removed. One
  ~200 KiB binary with no dependencies: own RE2-dialect regex compiler and
  Pike VM (Go `regexp` semantics), JSON with literal numbers, Go `net/url`
  host rules, SHA-256 from the Zig standard library.
- Private values move from the skip-worktree `values.go` to
  `secrets/values.zig` (ignored by git); `src/values.zig` is the empty
  committed skeleton.
- The binary is installed once per machine, the setup is per repository. The
  setup scripts build with `zig build` and put `rufix` and its `rufix-shell`
  twin into the bin dir (`$RUFIX_BIN_DIR`) and onto the PATH; they touch no
  repository. `rufix install`, run in a repository, writes the hooks and the
  shell prefix to its `.claude/settings.local.json` and the mod to
  `.claude/skills/rufix/`, naming the installed binary, and never anything
  under `~/.claude`. Script flag: `--uninstall` (`-Uninstall`); `--project`,
  `--path`, `--shell` and `--mod` of `rufix install` are gone (everything is
  set up). Hooks that older versions wrote to the repository's
  `.claude/settings.json` are moved out on install and uninstall.
- `rufix uninstall --global` removes the hook entries older versions put into
  `~/.claude/settings.json`, where they applied to every repository;
  `install.sh --uninstall` does it too.
- `rufix check` looks at the binary only (counts and the demo), not at a
  repository: it prints no settings line and runs in any folder.
- CI runs `zig build test`, a release build with a size budget and the
  installer smoke tests on Ubuntu, Windows and macOS. The platform layer now
  knows macOS: the executable path comes from dyld (there is no `/proc`), the
  directory entries use the macOS layout and the C streams their libSystem
  names.

### Added

- Claude Code mod per repository: `rufix install` writes
  `.claude/skills/rufix/`, which masks the user's prompt (`prompt.submit`)
  and the error text of failed tools (`tool.call`) through `rufix redact`,
  failing closed. `rufix status` reports it, `uninstall` removes it.
- The mod also masks text the engine injects itself (`prompt.attachment`,
  `prompt.section`, `prompt.context`: working-directory notices, `@`-mentions,
  CLAUDE.md, git status), skill text (`skill.prompt`) and subagent tasks
  (`agent.spawn`); each fails closed.
- Rule helpers for `values.zig`: `rule.domain`, `rule.import`, `rule.path` and
  `rule.word` (`const rule = @import("rules")`) build the usual reversible,
  case-preserving rules from a real name and its replacement; the commented
  examples in `src/values.zig` use them. Plain rules still work. The
  expansions are pinned by `conformance/rules`.
- `rufix install`, `status` and `uninstall` refuse in a subfolder of a
  repository (Claude Code reads `.claude/` from the folder it starts in, so
  it would protect nothing); `--here` sets up that folder anyway.
- `install` and `status` report hooks of an older global install that are
  still in `~/.claude/settings.json`.
- Installer smoke tests in CI (`.github/smoke.sh`; `.github/smoke.ps1` for
  `install.ps1` and `install.cmd` on Windows): install on the machine twice
  and once while rufix runs, the PATH entry (once, then gone), `rufix install`
  in a scratch repository twice, status, git not seeing the mod, subfolder
  refusal, `rufix uninstall`, `--uninstall` (stopping on a broken
  `~/.claude/settings.json`), the clean-up of old global hooks and unknown
  flags. `.gitattributes` keeps shell scripts on LF.
- CLI fixtures can name paths that must (`present`) or must not (`absent`)
  exist: `install` writes only into the repository's `.claude/`.
- `until_stable` rule field: re-apply a rule while it still changes the text.
- `rufix redact`: masks all of stdin as one text.
- Shell wrapper per repository: `rufix install` sets
  `CLAUDE_CODE_SHELL_PREFIX` in the repository's `.claude/settings.local.json`
  to the `rufix-shell` twin of the installed binary. Bash tool calls run with stdout and
  stderr masked line by line and their exit code kept, so failing commands
  no longer leak; hooks, status line and MCP start-up pass through.
- PreToolUse restore for the local file tools `Write`, `Edit`, `MultiEdit`,
  `NotebookEdit`, `Read`, `Grep`, `Glob`.
- `preserve_case` filters: the letter case of a match survives the mask and
  the way back.
- `rufix status` / `check` report `stale` installs (old matcher, timeout,
  missing fail-closed flag, duplicates, another binary).
- Conformance fixtures (`conformance/`): engine, hook, installer, regex
  dialect and CLI contract, run by `zig build test`.
- Repository linter: files at most 500 lines, folders (except the root) at
  most 7 entries.

### Fixed

- A failure while masking a `PostToolUse` result exited 2, which blocks
  nothing there (the tool has run): the original output reached the model. It
  now answers with the same-shaped output with every string replaced by a
  notice (an MCP result becomes the notice); `PreToolUse` still blocks. The
  README says what stays open (`onFailure` needs Claude Code 2.1.295+).
- `rufix install` with a foreign `CLAUDE_CODE_SHELL_PREFIX` stopped half way:
  the hooks were written, the mod was not. It now refuses before the first
  write.
- A one-word host of a URL (`prod` of `http://prod:8080`) was replaced inside
  other words (`production`), leaving `[S:...]uction` that never restores; it
  is now replaced as a word only. The URL, dotted hosts, hosts with a port and
  credentials still match anywhere.
- Names `PASS`, `PWD`, `COOKIE` and `BEARER` (as whole parts, `DB_PASS`) mark
  credential variables, as `TOKEN` and `PASSWORD` already did.
- Two different protected values with one `[S:hash8]` placeholder left one of
  them unprotected; it is now an error.
- JSON nested deeper than 512 levels is an error (the hook blocks) instead of
  a stack overflow, and `\u` takes hex digits only (it took a sign).
- A settings file that is a symlink stays one (the file behind it is written);
  a failed file or folder operation names its path; a compiled filter that does
  not compile is named by its index.
- Installer on a home folder with spaces; the PATH line also goes to
  `~/.bash_profile` where it exists and to `~/.zshrc` on macOS (zsh does not
  read `~/.profile`); a running copy left by an earlier update no longer blocks
  the next one on Windows.
- The CLI fixtures took an empty stdout for any text they expected.
- Tests remove their temporary folders (each held a copy of the binary).
- An `until_stable` rule whose match is replaced by itself never settled:
  after 16 passes the hook failed and blocked every tool call. A rule now
  settles when a pass leaves the text unchanged.
- Security: a credential containing a dot (JWT) counted as a protected
  host and opened the restore gate for foreign hosts.
- Security: a URL's userinfo password leaked when the URL appeared with
  another path; the portless IPv6 host was unprotected.
- Security: MCP output object keys were not masked.
- The PreToolUse matcher `Bash|…|mcp__` never matched MCP tools; it is now
  the regex `^(Bash|Write|Edit|MultiEdit|NotebookEdit|Read|Grep|Glob)$|^mcp__`.
- Exact values replace in a fixed order on every run.
- A non-object `tool_input` no longer gets an `updatedInput` of the wrong
  shape.
- `install` no longer overwrites a malformed `hooks` value, and `uninstall`
  removes only commands rufix installs, not foreign hooks mentioning rufix.

## [0.1.0] - 2026-11-05

Initial release.

### Added

- PostToolUse redaction hook: deep string walk over tool output preserving
  the exact shape (`updatedToolOutput` / `updatedMCPToolOutput`).
- Reversible exact-value masking `[S:hash8]` for secret values and internal
  hosts; irreversible `[REDACTED:<rule>]` for format-detected tokens.
- Data-driven filter rules (`redact.RuleData`) with optional reverse rules
  and `AllowlistSeed`; `StrictTLD` matching (a TLD is only matched at the
  end of a domain). The engine ships zero rules and zero values — everything
  lives in the skip-worktree `internal/secretvalues/values.go`.
- PreToolUse restore hook: placeholders and masked patterns are resolved in
  Bash commands honouring the restore allowlist, memory-free across hook
  processes.
- Fail-closed behaviour: any internal error exits 2 and blocks the tool
  call; hook entries carry `onFailure: "block"`.
- Built-in installer: `rufix install/uninstall/status/check/version`; every
  install fully reinstalls rufix hook entries while preserving foreign hooks.
- Setup scripts: `install.sh`, `install.ps1`, `install.cmd` (`--revert` to
  remove).
- Secrets resolution order: the compiled Go file → `$RUFIX_ENV_FILE` /
  `$RUFIX_SECRETS_DIR` → `.atlassian.env` walk-up → `<exe dir>/secrets` →
  `~/.config/rufix/secrets`.
- GitHub Actions CI: build, vet and tests on ubuntu and windows.

[0.1.0]: https://github.com/PHPCraftdream/rufix/releases/tag/v0.1.0
