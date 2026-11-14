#!/usr/bin/env bash
# Smoke test of the installers in a scratch repository: install (twice),
# status, the refusal in a subfolder, git ignoring the binary and the mod,
# revert, and (off Windows) the clean-up of an older global install.
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

repo="$scratch/repo"
mkdir -p "$repo/pkg"
git -C "$repo" init -q

installed() {
  (cd "$repo" && sh "$src/install.sh")
  need "$repo/.claude/rufix/rufix$exe"
  need "$repo/.claude/rufix/rufix-shell$exe"
  need "$repo/.claude/rufix/.gitignore"
  need "$repo/.claude/settings.local.json"
  need "$repo/.claude/skills/rufix/hooks/register.ts"
  status="$(cd "$repo" && ".claude/rufix/rufix$exe" status)"
  echo "$status"
  # A duplicated or stale entry would read "stale: ..." instead.
  echo "$status" | grep -q "installed: PostToolUse, PreToolUse" || fail "hooks are not installed cleanly"
  echo "$status" | grep -q "rufix shell: on" || fail "the shell wrapper is not on"
  echo "$status" | grep -q "rufix mod: on" || fail "the mod is not on"
}

echo "== install, then install again"
installed
installed

echo "== git must not see the binary or the mod"
seen="$(git -C "$repo" status --porcelain --untracked-files=all)"
if echo "$seen" | grep -q "\.claude/rufix"; then fail "git sees the binary: $seen"; fi
if echo "$seen" | grep -q "skills/rufix"; then fail "git sees the mod: $seen"; fi

echo "== a subfolder of the repository is refused"
if (cd "$repo/pkg" && sh "$src/install.sh") >/dev/null 2>&1; then fail "install in a subfolder succeeded"; fi
absent "$repo/pkg/.claude"

echo "== revert"
(cd "$repo" && sh "$src/install.sh" --revert)
absent "$repo/.claude/rufix"
absent "$repo/.claude/skills/rufix"
if [ -f "$repo/.claude/settings.local.json" ] && grep -qi rufix "$repo/.claude/settings.local.json"; then
  fail "settings.local.json still mentions rufix"
fi

if [ -z "$exe" ]; then
  echo "== clean-up of an older global install"
  # The fake home would also move zig's cache: keep the real one.
  export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$(zig env | grep -o '"global_cache_dir": *"[^"]*"' | sed 's/.*: *"//; s/"$//')}"
  home="$scratch/home"
  mkdir -p "$home/.claude" "$home/.local/bin"
  cat > "$home/.claude/settings.json" <<'JSON'
{"model":"opus","hooks":{"PostToolUse":[{"matcher":"","hooks":[{"type":"command","command":"\"/old/bin/rufix\" hook"}]}]}}
JSON
  : > "$home/.local/bin/rufix"
  : > "$home/.local/bin/rufix-shell"
  printf '%s\n' 'export FOREIGN=1' 'export PATH="/old/bin:$PATH" # rufix: binary on the PATH' > "$home/.profile"
  HOME="$home" sh "$src/install.sh" --clean-global
  absent "$home/.local/bin/rufix"
  absent "$home/.local/bin/rufix-shell"
  grep -q opus "$home/.claude/settings.json" || fail "foreign settings were lost"
  if grep -q rufix "$home/.claude/settings.json"; then fail "the old hooks are still in settings.json"; fi
  grep -q 'FOREIGN=1' "$home/.profile" || fail "a foreign profile line was lost"
  if grep -q "rufix: binary" "$home/.profile"; then fail "the PATH line is still in .profile"; fi
fi

echo "SMOKE OK"
