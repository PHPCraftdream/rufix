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
src/core/                 engine, URL parser, Pike VM, JSON, regex/, rules.zig
                          (the rule type and the domain/import/path/word helpers;
                          a module of its own, "rules", imported by values.zig)
src/hooks/                hook contract, shell prefix, mod, repository paths and
                          the self-ignoring .gitignore (local.zig), settings
                          installers (settingsfile.zig: read/write)
src/platform/             C-runtime I/O, OS access (paths, env, spawn), env files
tests/                    zig build test: fixtures, CLI scenarios, linter
conformance/              behaviour contract as JSON fixtures (see its README)
install.sh / install.ps1 / install.cmd   build the binary and put it on the PATH
secrets/                  ignored by git: secrets/values.zig, local builds
```

## Commands

```bash
zig build test      # every suite; must pass on Windows, Linux and macOS
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
   has no active value or rule, only commented examples with fake names. The
   rule helpers (`src/core/rules.zig`) hold shapes, never names. An engine change required by a new filter is a P0 blocker —
   extend `RuleSpec` instead.
6. **No secrets in output.** `check` / `status` print counts and fake-pattern
   demos only. Errors name a filter index, never its text.
7. **Numbers round-trip.** JSON numbers keep their literal text.
8. **Test fixtures only.** Secret-like literals in fixtures use harmless
   phrases (`rufix_test_code_secret_number_001`) and `*.internal.example`.
9. **Regex dialect = Go's RE2.** `conformance/regex` pins it. Unsupported
   syntax (Unicode classes, folding outside the tables) is a compile error,
   never a partial match.
10. **The binary is global, the setup is per repository.** The installer
    scripts (`install.sh`/`.ps1`/`.cmd`) build the binary and put it, with
    its `rufix-shell` twin, in the bin dir (`$RUFIX_BIN_DIR`) and on the
    PATH; they touch no repository. `rufix install` works on the current
    folder only: hooks and shell prefix in `.claude/settings.local.json`,
    mod in `.claude/skills/rufix/`, all naming the installed binary by its
    absolute path. It never writes `~/.claude` (`uninstall --global` only
    removes what older versions left there) and never copies the binary into
    a repository: the binary holds private values, so it stays outside every
    repository. The mod's folder carries a self-ignoring `.gitignore`. In a
    subfolder of a repository the commands refuse unless `--here` is given.
    The prefix never overwrites a foreign `CLAUDE_CODE_SHELL_PREFIX`,
    anything that is not a Bash tool call passes through it untouched, and
    uninstall removes only files carrying our marker.
11. **Replacements go through the binary.** The mod never masks by itself:
    it calls `rufix redact`. User input takes the read direction (masking),
    never restore. The mod fails closed (`{ drop }`, `{ deny }`).
12. **Paths through the platform layer.** Path joins, separators, base names
    and the executable suffix go through `src/platform/os.zig`
    (`join`, `dir`, `base`, `toSlash`, `joinSlash`, `exeName`,
    `isExecutableNamed`); no OS-specific path literal anywhere else.

## Conventions

- English everywhere: code, comments, docs, tool output, commit messages.
- Comments explain why, not what.
- In regex strings (rules, fixtures, docs) a word after a boundary goes into
  a group: `\\b(?:word)`, never `\\bword` — the `b` fuses with the word and
  editors stop highlighting it on selection. Not needed where the next
  character is not a letter (`\\b(`, `\\b|`).
- Every file at most 500 lines, every folder except the root at most 7
  entries — `tests/lint.zig` enforces it.
- The rule helpers have fixtures too (`conformance/rules`): change the
  templates in `src/core/rules.zig` and the fixtures together. `build`
  (compile time, for values.zig) and `expand` (run time, for fixtures) render
  the same pieces; the tests check they agree.
- A behaviour change updates `conformance/` in the same change; never edit
  expectations to make a failing change pass.
- CLI text is lowercase-terse; errors to stderr, data to stdout.

## Git discipline

- Never sign commits.
- The project owner decides when to commit and push.
- Commit style: Conventional Commits with an emoji prefix (`✨ feat: …`).
- `secrets/`, `zig-out/` and `.zig-cache/` must never appear in `git status`.

## CI

`.github/workflows/ci.yml` runs `zig build test`, a release build with a
size budget and the installer smoke tests (`.github/smoke.sh`, plus
`.github/smoke.ps1` for `install.ps1` and `install.cmd` on Windows) on Ubuntu,
Windows and macOS. A change to the installers or to what `rufix install` writes
needs `bash .github/smoke.sh` (and `smoke.ps1`) to stay green.
