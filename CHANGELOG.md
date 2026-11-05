# Changelog

All notable changes to rufix are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project adheres to [Semantic Versioning](https://semver.org/).

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
