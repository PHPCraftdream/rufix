# AGENTS.md — guide for AI coding agents

rufix keeps secrets and internal hosts out of the model context in Claude
Code: a PostToolUse hook redacts tool output, a PreToolUse hook restores
placeholders in Bash commands that target protected hosts, and the hook
installer is built into the same binary (`rufix install`).

This is a security tool. Treat every weakening of the defaults as a bug.

## Layout

```
main.go                      CLI: hook | install | uninstall | status | check | version
install.sh                   setup script (sh): build + go install . + rufix install; --revert uninstalls
install.ps1                  setup script (PowerShell): same, flags -Project / -Revert
internal/envfile/            KEY=VALUE parsing + secrets-file resolution order
internal/redact/             replacement core: exact-value map + format rules
internal/hook/               Claude Code hook contracts (stdin JSON in/out)
internal/install/            settings.json merge/uninstall (idempotent)
internal/secretvalues/       the compiled secrets file (see "Skip-worktree file")
```

Single Go module, standard library only — do not add dependencies without an
explicit reason stated in the task. The setup scripts must stay thin: every
real action goes through the CLI subcommands, the scripts only chain them.

## Commands

```bash
go build ./...               compile check
go vet ./...                 static analysis
go test ./...                full test suite
go build -o rufix.exe .      local binary
go install .                 install globally to $GOPATH/bin
```

Run build + vet + test after every change. Tests must pass on Windows and
Linux: `internal/hook` and `internal/envfile` tests run real files via
`t.TempDir()`, and path expectations must be built with `filepath.Join` /
`filepath.FromSlash`, never hand-written `/`-separated literals (they break on
Windows, where `filepath.Dir`/`Join` use `\`).

## Invariants — do not break

1. **Fail-closed.** Any internal error in `hook` mode exits with code 2 and
   never emits partial JSON: Claude Code blocks the tool call. Exit codes
   other than 0/2 are a bug.
2. **Output shape is preserved exactly.** PostToolUse replacement is a deep
   string walk over the decoded JSON (`mapStrings`); rebuilt structures must
   keep every field. A wrong shape makes Claude Code ignore
   `updatedToolOutput` and leak the original — this is the worst failure.
3. **Exact-before-rules.** `Store.Redact` applies exact values from the
   secrets map first (reversible `[S:hash8]`), regex rules second
   (irreversible `[REDACTED:<rule>]`). Reordering demotes recoverable
   replacements to irreversible ones.
4. **Restore allowlist.** `Restore` runs in hooks only for `tool_name ==
   "Bash"` and only when `HostPlaceholder` holds: an exact `[S:hash]` whose
   value is a protected host, or a masked `AllowlistSeed` pattern (its
   `RestoreMatch` matches memory-free — hook calls are separate processes).
   Widening the allowlist is out of the question without an explicit task.
5. **Filters and values are data — P0.** The engine ships **zero rules and
   zero values**: by default nothing is replaced. Every filter, mask and
   value lives in the skip-worktree `internal/secretvalues/values.go`
   (`Vars()` / `Rules()`); the committed skeleton stays empty
   (`TestSkeletonIsEmpty` skips when the working copy carries local data).
   An engine change required by a new filter is a P0 blocker — extend
   `RuleData` instead.
6. **No secrets in output.** `check` / `status` print counts, hashes and
   fake-pattern demos only. Never print a real value.
7. **Numbers round-trip.** Hook JSON is decoded with `UseNumber()`; re-marshaled
   tool output must not rewrite numbers.
8. **Test fixtures only.** Every secret-like literal in tests uses long
   harmless phrases (`rufix_test_code_secret_number_001`) and `*.internal.example`
   hosts. `TestStubIsEmpty` guards the committed skeleton; do not weaken it.
9. **RE2 constraints.** Go regexp has no lookahead/backreferences. Rules that
   must skip already-redacted text exclude `[` from the value charset (see
   `env-kv` in `internal/redact/rules.go`).

## Skip-worktree file

`internal/secretvalues/values.go` is tracked with a skip-worktree flag: the
committed stub stays empty, local values are never committed.

```bash
git ls-files -v internal/secretvalues/        # S = skip-worktree
git show :internal/secretvalues/values.go > internal/secretvalues/values.go  # restore stub
git update-index --no-skip-worktree internal/secretvalues/values.go          # unpin temporarily
```

Before any commit, verify `git status` does not list modifications to this
file, and `TestStubIsEmpty` passes.

## Conventions

- English everywhere: code, comments, docs, tool output, commit messages.
- Comments explain why, not what; no comment-only noise; never communicate
  with the user through code comments.
- No lint-suppression directives; fix the cause.
- Keep files small and focused; new features get a package under `internal/`
  with table-driven tests next to them.
- CLI text is lowercase-terse; errors to stderr, data to stdout.

## Git discipline

- Never sign commits (`git commit -S` is forbidden; use plain commits).
- The project owner decides when to commit and push — do not commit
  spontaneously. The commit-message style is Conventional Commits with an
  emoji prefix (`✨ feat: …`, `🐛 fix: …`, `📝 docs: …`).
- `.gitignore` covers the binary and the `secrets/` folder; both must never
  appear in `git status` output.

## CI

`.github/workflows/ci.yml` runs build + vet + test on ubuntu and windows for
pushes and pull requests. Keep it green; there is no separate release
pipeline yet.
