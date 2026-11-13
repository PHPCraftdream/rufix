# Conformance fixtures

Language-neutral behaviour contract for rufix. `zig build test` runs every
case (tests/); a rewrite in any language passes when it reproduces every
expectation. The expectations were recorded from the original Go
implementation and are now maintained by hand: change one only together
with the behaviour change it records.

Each kind lives in its own folder, split into files of at most 500 lines
(`engine/01.json`, `engine/02.json`, …); a harness reads them in name order.

All data here is fake: `rufix_test_*` phrases, `*.internal.example` hosts,
made-up domains. The fixtures never use the private rules or values.

Each file has the shape:

```json
{"version": 1, "spec": "<this document>", "cases": [ ... ]}
```

Case names are unique within a file. `note` is free text for humans.

## Shared inputs

`vars` — exact values, `{"NAME": "value"}`. A value is protected when the
name contains a credential part (`TOKEN`, `SECRET`, `PASSWORD`, `PASSWD`,
`PAT`, `KEY`, `CREDENTIAL`, `CREDENTIALS`, split on `_`/`-`, any case) and
the value has at least 6 bytes; or when the value parses as a URL with a
host (Go `net/url` rules) — then the URL, its host with port (IPv6 in
brackets) and its host without port and brackets are protected, and a
userinfo password of at least 6 bytes is protected as a credential. Values shorter than 4 bytes, empty values and values containing
`\n` are ignored. Each protected value becomes `[S:` + the first 8 hex
digits of SHA-256 of the value + `]`. Variables are processed in byte order
of their names; values replace longest first, equal lengths in byte order
of the value. A value counts as a protected host only when it came from a
URL and contains `.` and no whitespace; a value that is also a credential
is never a host.

`rules` — ordered filters:

| Field | Meaning |
|---|---|
| `name` | identifier |
| `match`, `replace` | forward regex and template, applied on redact |
| `restore_match`, `restore_replace` | optional reverse regex and template |
| `allowlist_seed` | masks of this rule count as protected-host evidence |
| `strict_tld` | reject a match followed by `.` and a domain character (`[A-Za-z0-9_-]`) |
| `preserve_case` | carry the match's letter case into the replacement |

Regexes use RE2 syntax (Go `regexp`): no lookaround, no backreferences,
`\b` is an ASCII word boundary, `(?i)` uses Unicode simple case folding. Templates use `${n}`; an unmatched group expands to an empty
string. A port must use an RE2-compatible engine or prove equivalence for
the patterns it ships.

`preserve_case`: compare match and replacement byte by byte, ignoring ASCII
case, from the start and from the end; the shared prefix and suffix are
copied from the match. In the remaining middle: if the match's middle has
ASCII letters and all are upper case, the replacement's middle becomes
upper case; otherwise byte `i` of the replacement's middle takes the case
of byte `i` of the match's middle when that byte is an ASCII letter, and
keeps the template's case beyond the match's length. Non-ASCII bytes are
never changed.

## engine/

One store per case, built from `vars` and `rules`; `steps` run in order on
that store (forward replacements of `allowlist_seed` rules are remembered
for later `host_placeholder` steps in the same case).

| `op` | Behaviour | Expect |
|---|---|---|
| `redact` | exact values (longest first), then rules in order | `output`, `count` |
| `restore` | reverse rules in reverse order, then exact placeholders | `output`, `count` |
| `restore_domains` | reverse rules only; `[S:…]` untouched | `output`, `count` |
| `host_placeholder` | an `[S:…]` of a protected host (see `vars`), a reverse-rule match of an `allowlist_seed` rule, or a remembered forward replacement | `result` |
| `has_domain_mask` | a reverse-rule match of an `allowlist_seed` rule | `result` |

`count` is the number of replacements made.

## hook/

Runs the hook once. `input` is written to stdin byte for byte (use it as the
raw JSON text, so number literals stay as written); `stdin_raw` replaces it
for malformed input. The store uses only the case's `vars` and `rules`.

Behaviour the cases pin: PostToolUse masks string values; for `mcp__*`
tools it masks object keys too and blocks (exit 2) when two keys would
collide; built-in tool keys are never changed. PreToolUse ignores a
`tool_input` that is not an object. The request is one JSON value read
from stdin; bytes after it are ignored; a value that is not an object or
`null`, a field of the wrong type and a UTF-8 BOM all block.

- `exit` — process exit code. Only 0 and 2 are valid; on 2 stdout is empty.
- `stdout` — the JSON the hook prints, or `null` for no output. Compare as
  JSON values: object key order is free, but numbers compare by their
  literal text (`1.50` is not `1.5`). Stderr is not part of the contract.

## install/

Each case starts from a settings file holding `initial` (`null`: no file),
then runs `steps` on it. `options.exe_dir` is the directory of the rufix
binary (`exe_dir` joined with `rufix`, slash-separated and Go-quoted, gives
the hook command); `options.env_files` appends ` --env-files`.

`initial_raw` replaces `initial` with exact file bytes (empty or invalid
JSON). A rufix entry is a hook whose command is exactly what Install
writes: an executable named `rufix` or `rufix.exe` (any case, optionally
Go-quoted), then `hook`, optionally `--env-files`; every other hook is
foreign and survives. A `hooks` value that is not an object, or an event
value that is not a list, makes install fail without touching the file.

- `error` — the action must fail; `summary` is then `null`.
- `summary` — the action's one-line result; `{path}` stands for the
  settings path.
- `settings` — the file content after the step, compared as JSON values
  with literal numbers; `null`: the file does not exist.
- `settings_raw` — exact file bytes when they are not valid JSON
  (`settings` is then `null`).

## regex/

Pins the regex dialect. Per case: `pattern`, `inputs`, `valid` (whether
Go's `regexp` compiles it) and `matches` — for each input, every match as
Go's `FindAllStringSubmatchIndex` reports it (byte offsets, -1 = unset
group). `may_reject` marks valid patterns a small port may refuse to compile
(Unicode classes); it must then reject, never match less.

## cli/

The binary run as a process, built with the empty skeleton values. Per case:
`args`, `stdin`, `env`, `files` (written under a fresh temporary root
first), then `exit`, `stdout` (JSON compared as a document when it is JSON),
`stderr` (exact, only recorded for exit 0), `stderr_nonempty` and
`settings` (resulting files by relative path). `{tmp}` stands for the
temporary root, slash-separated; the binary is at `{tmp}/bin/rufix(.exe)`,
the working directory is `{tmp}/work`, `HOME`/`USERPROFILE` is `{tmp}/home`.
