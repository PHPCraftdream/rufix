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
- Setup scripts build with `zig build` and install the binary to
  `$RUFIX_BIN_DIR` (default `~/.local/bin`, `%LOCALAPPDATA%\rufix\bin` on
  Windows); they accept `--project`, `--env-files`, `--shell`, `--revert`
  and reject unknown flags.
- CI runs `zig build test` and a release build with a size budget.

### Added

- Claude Code mod per repository: `rufix install --project --mod` writes
  `.claude/skills/rufix/`, which masks the user's prompt (`prompt.submit`)
  and the error text of failed tools (`tool.call`) through `rufix redact`,
  failing closed. `rufix status --project` reports it, `uninstall` removes it.
- The mod also masks text the engine injects itself (`prompt.attachment`,
  `prompt.section`, `prompt.context`: working-directory notices, `@`-mentions,
  CLAUDE.md, git status), skill text (`skill.prompt`) and subagent tasks
  (`agent.spawn`); each fails closed.
- `until_stable` rule field: re-apply a rule while it still changes the text.
- `rufix redact`: masks all of stdin as one text.
- Setup scripts put the binary on the PATH (profile line on Linux/macOS/Git
  Bash, user PATH on Windows with `%VARIABLE%` entries kept) and accept
  `--mod`; `--revert` removes the PATH entry too.
- Shell wrapper per repository: `rufix install --project --shell` sets
  `CLAUDE_CODE_SHELL_PREFIX` in the repository's `.claude/settings.local.json`
  to a `rufix-shell` copy of the binary. Bash tool calls run with stdout and
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
