# rufix

[![CI](https://github.com/PHPCraftdream/rufix/actions/workflows/ci.yml/badge.svg)](https://github.com/PHPCraftdream/rufix/actions/workflows/ci.yml)
[![License: MIT OR Apache-2.0](https://img.shields.io/badge/License-MIT_OR_Apache--2.0-blue.svg)](#license)
[![Go](https://img.shields.io/github/go-mod/go-version/PHPCraftdream/rufix?logo=go&logoColor=white)](https://go.dev)
[![Go Report Card](https://goreportcard.com/badge/github.com/PHPCraftdream/rufix)](https://goreportcard.com/report/github.com/PHPCraftdream/rufix)

Keep secrets and internal hosts out of the model context in Claude Code.

`rufix` is a single Go binary that acts as a pair of
[Claude Code hooks](https://code.claude.com/docs/en/hooks): it redacts tool
output before it reaches the model, and restores placeholders in Bash
commands that legitimately target your internal hosts. The hook installer is
built into the binary — setup is two commands.

## Why

When Claude Code reads files, runs commands or calls MCP servers, the raw
output — with your Jira/Confluence/GitLab tokens and internal hostnames — is
sent verbatim to the model provider. rufix closes that channel at the hook
layer:

- known values (compiled into the binary; env files are opt-in) become
  **reversible** `[S:hash8]` placeholders;
- token-shaped strings that match hardcoded format rules but are not known
  values become **irreversible** `[REDACTED:<rule>]`;
- the tool output shape is preserved exactly, so the hook replacement is
  always accepted;
- any internal error blocks the tool call — fail-closed.

```
in:   Bearer rufix_test_code_secret_number_001 at https://jira.internal.example/x
out:  Bearer [S:173410ad] at [S:95132e89]/x

in:   token ATATT3abcdefgHIJKLMNOPQRSTUVWX
out:  token [REDACTED:atlassian-pat]
```

## How it works

| Hook | Matcher | Action |
|---|---|---|
| `PostToolUse` | all tools | deep string walk over the tool response → `updatedToolOutput` / `updatedMCPToolOutput` |
| `PreToolUse` | `Bash` | if the command contains a placeholder whose value is a protected host, restore all placeholders in it (`updatedInput`) |
| `PreToolUse` | `mcp__*` | domain-only restore in tool arguments (`updatedInput`): masked names (`*.intra`) become real inside comments/links; credential `[S:hash]` placeholders are never restored into MCP arguments — no secret travels to the target server |

Placeholders the model prints back are inert: a Bash command is restored
only when it references something the allowlist honours — a protected-host
placeholder or a masked `AllowlistSeed` pattern (e.g. `*.intra`) — so a
secret cannot be smuggled to a foreign host.

### Verifying restore end-to-end

Restore happens inside the tool call, so its effect is visible in what the
command actually executed — not in `rufix hook` stdout (which is itself
redacted on display). Byte-level check:

```bash
echo api.project.intra > /tmp/rt.txt   # a command referencing a masked host
od -c /tmp/rt.txt                      # a p i . p r o j e c t . c o m — restore ran
```

If the file contains the real name, PreToolUse restored the mask before
execution. Inspect results with `od`/hex dumps: plain stdout is redacted by
the hook, which makes manual verification misleading.

## Install & setup

One command does everything (build → global binary → hooks → verification):

```bash
./install.sh              # sh: git-bash, Linux, macOS
.\install.ps1             # Windows PowerShell
install.cmd               # Windows cmd.exe — runs install.ps1, remaps --flags to -Switches
```

Flags:

```
--project / -Project      hooks into ./.claude/settings.json instead of the global one
--revert  / -Revert       uninstall hooks (same scope) and remove the binary
```

Manual equivalent:

```bash
# 1. Generate private regex programs, then build the dev binary
go generate ./internal/secretvalues
go build

# 2. Install the binary globally: $GOPATH/bin/rufix(.exe) — usually ~/go/bin
go install .

# 3. Install hooks into Claude Code settings.json
rufix install            # global:  ~/.claude/settings.json
rufix install --project  # project: ./.claude/settings.json

# Verify (stats + fake-pattern demo; never prints real values)
rufix check
```

Hook commands reference the absolute path of the executable that ran
`install`, and every install **fully reinstalls** the rufix hook entries:
stale entries from previous installs are removed and re-added fresh after
the rebuild, while foreign hooks are preserved. Run step 3 from the
installed binary (step 2), not from a temp `go run` build.

```bash
# Uninstall (hooks first, then the binary)
./install.sh --revert     # or: .\install.ps1 -Revert, or: install.cmd --revert

# Manual equivalent:
rufix uninstall            # hooks, global settings
rufix uninstall --project  # hooks, project settings
go clean -i .              # the binary ($GOPATH/bin/rufix.exe)
```

## Replacement data

**Default — the compiled Go file only** `internal/secretvalues/values.go`:
a `Vars()` map and `Rules()` filters. The committed
version is a stub with empty values; the file is pinned with
`git update-index --skip-worktree`, so local values never get committed:

```bash
git add internal/secretvalues/values.go                        # already done
git update-index --skip-worktree internal/secretvalues/values.go
git ls-files -v internal/secretvalues/                         # S = pinned
```

Fill `Vars()` and `Rules()` locally, then run
`go generate ./internal/secretvalues && go build && go install .` — exact
values and ready-to-run regex programs are compiled into your private binary. **Never distribute the executable** —
strings of a binary built with filled values contain the secrets.

External files are **disabled by default**, even when `RUFIX_ENV_FILE` or
`RUFIX_SECRETS_DIR` is set. The default hook does not search for or read them.
Enable them explicitly:

```bash
rufix install --env-files             # persist the flag in both hook commands
rufix install --project --env-files   # same, project settings
rufix check --env-files               # diagnose the optional external source
rufix hook --env-files                # direct hook invocation; JSON on stdin
```

With `--env-files`, fallbacks are `$RUFIX_ENV_FILE` (file) →
`$RUFIX_SECRETS_DIR` (dir) → `.atlassian.env` walking up from the hook's
`cwd` → `<exe dir>/secrets` → `~/.config/rufix/secrets`. A directory is
scanned for `*.env` files (dotfiles included), merged earlier-wins. Compiled
values override external files. Reinstall without `--env-files` to disable
the external source again. Existing env-file users must opt in when upgrading.

Recognised variables: names with `TOKEN` / `SECRET` / `PASSWORD` / `PASSWD` /
`PAT` / `KEY` / `CREDENTIAL(S)` segments (values ≥ 6 chars) and URL-valued
variables (full URL, bare host and portless host are all protected).
Usernames, languages and paths are left untouched.

## Filters (data, not code)

The engine ships **zero rules and zero values** — by default nothing is
replaced. Every filter, mask and value lives in the skip-worktree
`internal/secretvalues/values.go` (`Rules()` / `Vars()`) — never in committed
sources. An engine change required by a new filter is a P0 blocker. A
commented example ships inside the skeleton; a typical local set:

| Rule | Action |
|---|---|
| `com-to-intra` | every `*.com` domain masked as `*.intra`, restored back in allowlisted Bash commands |
| `atlassian-pat` | `ATATT…` Atlassian API tokens |
| `gitlab-pat` | `glpat-…` GitLab personal access tokens |
| `jwt` | `eyJ…` three-segment JWTs |
| `bearer` / `basic` | `Authorization` header values |
| `kv-json` | `"password": "…"`-style JSON fields |
| `query-param` | `?token=…` / `&api_key=…` URL parameters |
| `env-kv` | `TOKEN=…` / `SECRET=…` env-style lines |

A filter can carry a reverse rule (`RestoreMatch`/`RestoreReplace`) — that is
how `*.intra` goes back to `*.com` — and `AllowlistSeed: true` to make its
masked patterns restoreable in Bash commands. Known exact values are always
replaced before the rules run, so your own tokens inside a `Bearer` header
stay reversible. The `env-kv` rule skips already-redacted placeholders (Go
RE2 has no lookahead, so the value charset simply excludes `[`).

## Hook execution

Each invocation is a separate process; there is no background service.
`go generate ./internal/secretvalues` compiles both regex directions into
Go literals before building. Setup scripts and CI run this step automatically;
plain `go build` does not run Go generators. The hook loads the generated
programs without parsing or compiling regex, including on its first call.
Missing or stale programs block the hook instead of falling back to runtime
compilation. Identical expressions share one ready-to-run program.

The matcher is a pinned copy of Go 1.26.0 `regexp`, under the Go authors'
BSD license; its matching semantics and execution algorithms are unchanged.
See [internal/compiledregexp/README.md](internal/compiledregexp/README.md).
`filters_generated.go` is gitignored because it can contain private patterns.
The committed engine still ships no filters or values; fixture programs are
generated into a separate test-only file.

Exact substitutions count matches while replacing. Regex substitutions reuse
one full-string match search; seed and StrictTLD rules retain their existing
per-match replacement semantics. JSON is decoded directly from stdin without
waiting for EOF after the request, and its containers are updated in place.
Numbers and the tool output shape are preserved.

## CLI reference

```
rufix hook [--env-files]                process hook stdin JSON
rufix install [--project] [--env-files]  install hook entries
rufix uninstall [--project]            remove rufix hook entries only
rufix status [--project]               show install state
rufix check [--project] [--env-files]   replacement stats + fake-pattern demo
rufix version
```

## Fail-closed behaviour

- Internal error in hook mode → exit code 2 → Claude Code blocks the call.
- Hook entries carry `onFailure: "block"` (covers hook timeouts).
- Compiled-only mode needs no external files and emits no missing-file warning.
- With `--env-files`, a missing external source falls back to compiled values
  and rules with a warning. A file read error blocks the hook.

## What rufix does NOT protect

- **User prompts, CLAUDE.md, conversation history** — they reach the model
  before any hook. Filter those in the LLM gateway/proxy (request-body
  filtering), not here.
- **Local telemetry** (OTel spans) captures original output before hooks run.
- **The local session transcript** on disk is not part of this protection.

rufix protects the model boundary, not your disk.

## Development

```bash
go generate ./internal/secretvalues && go build ./... && go vet ./... && go test ./...
```

See [AGENTS.md](AGENTS.md) for architecture notes, invariants and
conventions. CI (`.github/workflows/ci.yml`) runs build, vet and tests on
Ubuntu and Windows. Commits follow Conventional Commits with an emoji prefix
(`✨ feat: …`, `🐛 fix: …`, `📝 docs: …`).

Only test fixtures are committed: long harmless phrases like
`rufix_test_code_secret_number_001` and `*.internal.example` hosts. The
`secrets/` folder is gitignored; `internal/secretvalues/values.go` is pinned
with skip-worktree.

## Security & privacy

See [SECURITY.md](SECURITY.md) for reporting vulnerabilities. rufix never
sends data anywhere: it is a local filter between Claude Code and your model
gateway.

## License

Dual-licensed under either of:

- [MIT](LICENSE-MIT)
- [Apache-2.0](LICENSE-APACHE)

at your option.

The bundled Go `regexp` matcher retains the Go authors' BSD license; see
[internal/compiledregexp/LICENSE](internal/compiledregexp/LICENSE).

CI checks dependency licenses against an explicit allowlist and verifies the
bundled source notices. See [the license policy](docs/licensing.md) for the
checks, review obligations, and automation limits.
