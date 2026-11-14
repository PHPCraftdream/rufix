#!/usr/bin/env bash
# Smoke test of the installers on a scratch machine and repository: the global
# install (twice, once while a copy of rufix runs), `rufix install` in a
# repository (twice), status, git not seeing the mod, the refusal in a
# subfolder, `rufix uninstall`, and the global uninstall (with, off Windows,
# the hooks an older version left in ~/.claude).
# CI runs it on every platform; locally: bash .github/smoke.sh
set -eu

src="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
exe=""
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) exe=".exe" ;; esac

fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }
need() { [ -e "$1" ] || fail "missing: $1"; }
absent() { [ ! -e "$1" ] || fail "still there: $1"; }

# Off Windows the fake home would also move zig's cache: keep the real one.
if [ -z "$exe" ]; then
  export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$(zig env | grep -o '"global_cache_dir": *"[^"]*"' | sed 's/.*: *"//; s/"$//')}"
fi
home="$scratch/home"
bin="$scratch/bin"
mkdir -p "$home/.claude" "$scratch/elsewhere"
export HOME="$home"
export RUFIX_BIN_DIR="$bin"
printf '%s\n' 'export FOREIGN=1' > "$home/.profile"

pathlines() { grep -c "rufix: binary on the PATH" "$home/.profile" || true; }

echo "== an unknown flag is refused before anything is built"
if sh "$src/install.sh" --bogus >/dev/null 2>&1; then fail "install.sh accepted --bogus"; fi
absent "$bin"

echo "== install on the machine, twice, from a folder that is no repository"
for _ in 1 2; do
  (cd "$scratch/elsewhere" && sh "$src/install.sh")
  need "$bin/rufix$exe"
  need "$bin/rufix-shell$exe"
done
[ "$(pathlines)" = "1" ] || fail "expected one PATH line, found $(pathlines)"
grep -q 'FOREIGN=1' "$home/.profile" || fail "a foreign profile line was lost"
absent "$scratch/elsewhere/.claude"

echo "== install again while a copy of rufix is running"
# A hook may be running when the binary is replaced, and Windows cannot
# overwrite a running executable: the installer has to move it aside.
coproc HOLD { exec "$bin/rufix$exe" redact >/dev/null 2>&1; }
holder="$HOLD_PID"
(cd "$scratch/elsewhere" && sh "$src/install.sh")
eval "exec ${HOLD[1]}>&-"
eval "exec ${HOLD[0]}<&-"
wait "$holder" 2>/dev/null || true
"$bin/rufix$exe" version | grep -q "^rufix " || fail "the reinstalled binary does not run"
[ "$(pathlines)" = "1" ] || fail "expected one PATH line, found $(pathlines)"

repo="$scratch/repo"
mkdir -p "$repo/pkg"
git -C "$repo" init -q

installed() {
  (cd "$repo" && "$bin/rufix$exe" install)
  need "$repo/.claude/settings.local.json"
  need "$repo/.claude/skills/rufix/hooks/register.ts"
  need "$repo/.claude/skills/rufix/.gitignore"
  absent "$repo/.claude/rufix"
  status="$(cd "$repo" && "$bin/rufix$exe" status)"
  echo "$status"
  # A duplicated or stale entry would read "stale: ..." instead.
  echo "$status" | grep -q "installed: PostToolUse, PreToolUse" || fail "hooks are not installed cleanly"
  echo "$status" | grep -q "rufix shell: on" || fail "the shell wrapper is not on"
  echo "$status" | grep -q "rufix mod: on" || fail "the mod is not on"
}

echo "== set up the repository, then again"
installed
installed

echo "== git must not see the mod"
seen="$(git -C "$repo" status --porcelain --untracked-files=all)"
if echo "$seen" | grep -q "skills/rufix"; then fail "git sees the mod: $seen"; fi

echo "== a subfolder of the repository is refused"
if (cd "$repo/pkg" && "$bin/rufix$exe" install) >/dev/null 2>&1; then fail "install in a subfolder succeeded"; fi
absent "$repo/pkg/.claude"

echo "== take rufix out of the repository"
(cd "$repo" && "$bin/rufix$exe" uninstall)
absent "$repo/.claude/skills/rufix"
if [ -f "$repo/.claude/settings.local.json" ] && grep -qi rufix "$repo/.claude/settings.local.json"; then
  fail "settings.local.json still mentions rufix"
fi
need "$bin/rufix$exe"

if [ -z "$exe" ]; then
  echo "== --uninstall stops, removing nothing, when ~/.claude/settings.json is broken"
  printf '{' > "$home/.claude/settings.json"
  if sh "$src/install.sh" --uninstall >/dev/null 2>&1; then fail "--uninstall went on past a broken settings.json"; fi
  need "$bin/rufix"
  need "$bin/rufix-shell"
  [ "$(pathlines)" = "1" ] || fail "the PATH line was removed although the uninstall stopped"
  # What an older version left: hooks in ~/.claude/settings.json.
  cat > "$home/.claude/settings.json" <<'JSON'
{"model":"opus","hooks":{"PostToolUse":[{"matcher":"","hooks":[{"type":"command","command":"\"/old/bin/rufix\" hook"}]}]}}
JSON
fi

echo "== take rufix off the machine"
(cd "$scratch/elsewhere" && sh "$src/install.sh" --uninstall)
absent "$bin/rufix$exe"
absent "$bin/rufix-shell$exe"
absent "$bin/rufix$exe.old"
[ "$(pathlines)" = "0" ] || fail "the PATH line is still in .profile"
grep -q 'FOREIGN=1' "$home/.profile" || fail "a foreign profile line was lost"
if [ -z "$exe" ]; then
  grep -q opus "$home/.claude/settings.json" || fail "foreign settings were lost"
  if grep -q rufix "$home/.claude/settings.json"; then fail "the old hooks are still in settings.json"; fi
fi

echo "SMOKE OK"
