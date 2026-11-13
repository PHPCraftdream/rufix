# AGENTS.md — guide for AI coding agents

rufix keeps secrets and internal hosts out of the model context in Claude
Code: a PostToolUse hook redacts tool output, a PreToolUse hook restores
placeholders in Bash commands and local file-tool arguments that carry
protected-host evidence, an optional per-repository shell prefix masks the
output of Bash commands (failing ones included), and the installer is built
into the same binary (`rufix install`).

This is a security tool. Treat every weakening of the defaults as a bug.

Written in Zig 0.16, no dependencies, linked against the C runtime only.
Hooks use compiled values only by default; env files are opt-in via
`rufix hook --env-files` (`rufix install --env-files` persists the flag).

## Layout

```
build.zig                 zig build (ReleaseSmall binary), zig build test
src/main.zig              entry point
src/rufix.zig             library root for the tests
src/values.zig            committed EMPTY skeleton of values and filters
src/cli/                  commands, flags, usage (main logic of the CLI)
src/core/                 engine, URL parser, Pike VM, JSON, regex/
src/hooks/                hook contract, shell prefix, settings.json installers
src/platform/             C-runtime I/O, OS access (paths, env, spawn), env files
tests/                    zig build test: fixtures, CLI scenarios, linter
conformance/              behaviour contract as JSON fixtures (see its README)
install.sh / install.ps1 / install.cmd   thin setup scripts over the CLI
secrets/                  ignored by git: secrets/values.zig, local builds
```

## Commands

```bash
zig build test      # every suite; must pass on Windows and Linux
zig build           # release binary in zig-out/bin
```

Run `zig build test` after every change.

## Invariants — do not break

1. **Fail-closed.** Any internal error in `hook` mode exits 2 and never
   writes stdout: Claude Code blocks the tool call. Exit codes other than 0/2
   from `hook` are a bug.
2. **Output shape is preserved exactly.** PostToolUse rewrites string values
   in place; built-in tool keys are never renamed (Claude Code would drop the
   replacement and show the original). MCP output keys are masked, colliding
   keys block.
3. **Exact before rules.** Exact values first (reversible `[S:hash8]`), rules
   second. Reordering demotes recoverable replacements to irreversible ones.
4. **Restore allowlist.** Full restore only for `Bash` (gated on `command`)
   and the local file tools `Write`, `Edit`, `MultiEdit`, `NotebookEdit`,
   `Read`, `Grep`, `Glob` (gated on any string), when a protected-host
   placeholder or an `allowlist_seed` mask is present. MCP tools get the
   domain-only restore; web tools and everything else restore nothing. Only
   URL-derived values are hosts. The PreToolUse matcher
   (`^(Bash|Write|Edit|MultiEdit|NotebookEdit|Read|Grep|Glob)$|^mcp__`) and
   the tool list in `src/hooks/hook.zig` must stay in sync, and the matcher
   must stay a regex. Widening the allowlist needs an explicit task.
5. **Values are data — P0.** The engine ships zero rules and zero values.
   Private data lives in `secrets/values.zig` (ignored); `src/values.zig`
   stays empty. An engine change required by a new filter is a P0 blocker —
   extend `RuleSpec` instead.
6. **No secrets in output.** `check` / `status` print counts and fake-pattern
   demos only. Errors name a filter index, never its text.
7. **Numbers round-trip.** JSON numbers keep their literal text.
8. **Test fixtures only.** Secret-like literals in fixtures use harmless
   phrases (`rufix_test_code_secret_number_001`) and `*.internal.example`.
9. **Regex dialect = Go's RE2.** `conformance/regex` pins it. Unsupported
   syntax (Unicode classes, folding outside the tables) is a compile error,
   never a partial match.
10. **Shell prefix is per repository.** `--shell` only with `--project` or
    `--path`; it never overwrites a foreign `CLAUDE_CODE_SHELL_PREFIX`;
    anything that is not a Bash tool call passes through untouched.

## Conventions

- English everywhere: code, comments, docs, tool output, commit messages.
- Comments explain why, not what.
- Every file at most 500 lines, every folder except the root at most 7
  entries — `tests/lint.zig` enforces it.
- A behaviour change updates `conformance/` in the same change; never edit
  expectations to make a failing change pass.
- CLI text is lowercase-terse; errors to stderr, data to stdout.

## Git discipline

- Never sign commits.
- The project owner decides when to commit and push.
- Commit style: Conventional Commits with an emoji prefix (`✨ feat: …`).
- `secrets/`, `zig-out/` and `.zig-cache/` must never appear in `git status`.

## CI

`.github/workflows/ci.yml` runs `zig build test` and a release build with a
size budget on Ubuntu and Windows.
