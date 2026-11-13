#!/usr/bin/env sh
# rufix setup: build the release binary with Zig, install it on the PATH,
# register the hooks.
#
# Usage:
#   ./install.sh               build + install the binary + hooks in ~/.claude/settings.json
#   ./install.sh --project     same, but hooks into ./.claude/settings.json
#   ./install.sh --env-files   hooks also load external env files (rufix hook --env-files)
#   ./install.sh --project --shell
#                              also wrap this repository's shell (output of failing commands)
#   ./install.sh --project --mod
#                              also add the mod masking prompts and failed tool output
#   ./install.sh --revert      uninstall hooks (same scope), the binaries and the PATH line
#
# The binary goes to $RUFIX_BIN_DIR (default ~/.local/bin), which is added to
# the PATH through ~/.profile, ~/.bashrc and ~/.zshrc (the ones that exist,
# ~/.profile always). Private values come from secrets/values.zig when it exists.
set -e
cd "$(dirname "$0")"

PROJECT=""
ENVFILES=""
SHELLWRAP=""
MOD=""
REVERT=0
for arg in "$@"; do
  case "$arg" in
    --revert) REVERT=1 ;;
    --project) PROJECT="--project" ;;
    --env-files) ENVFILES="--env-files" ;;
    --shell) SHELLWRAP="--shell" ;;
    --mod) MOD="--mod" ;;
    *) echo "rufix setup: unknown flag $arg (supported: --project, --env-files, --shell, --mod, --revert)" >&2; exit 1 ;;
  esac
done

BIN="${RUFIX_BIN_DIR:-$HOME/.local/bin}"
EXE=""
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) EXE=".exe" ;; esac
TARGET="$BIN/rufix$EXE"
MARK="# rufix: binary on the PATH"

profiles() {
  echo "$HOME/.profile"
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do [ -f "$rc" ] && echo "$rc"; done
}

if [ "$REVERT" = "1" ]; then
  if [ -x "$TARGET" ]; then
    "$TARGET" uninstall $PROJECT
  else
    echo "rufix binary not found at $TARGET; skipping hook uninstall"
  fi
  rm -f "$TARGET" "$BIN/rufix-shell$EXE"
  for rc in $(profiles); do
    if [ -f "$rc" ] && grep -qF "$MARK" "$rc"; then
      # grep exits 1 when our line was the only one: the empty file is right.
      { grep -vF "$MARK" "$rc" || true; } > "$rc.rufix-tmp"
      mv "$rc.rufix-tmp" "$rc"
    fi
  done
  echo "rufix removed."
  exit 0
fi

zig build -Doptimize=ReleaseSmall
mkdir -p "$BIN"
# Replace atomically: a hook may be running the old binary right now.
cp "zig-out/bin/rufix$EXE" "$TARGET.new"
mv -f "$TARGET.new" "$TARGET"

# Make `rufix` available in new shells: one marked line per profile, once.
# Git Bash needs the POSIX form: the colon of C:\ would split the PATH.
PATH_BIN="$BIN"
if command -v cygpath >/dev/null 2>&1; then PATH_BIN="$(cygpath -u "$BIN")"; fi
for rc in $(profiles); do
  if ! { [ -f "$rc" ] && grep -qF "$MARK" "$rc"; }; then
    printf 'export PATH="%s:$PATH" %s\n' "$PATH_BIN" "$MARK" >> "$rc"
    echo "rufix setup: added $PATH_BIN to the PATH in $rc"
  fi
done

"$TARGET" install $PROJECT $ENVFILES $SHELLWRAP $MOD
"$TARGET" check $PROJECT $ENVFILES
case ":$PATH:" in
  *":$PATH_BIN:"*) ;;
  *) echo "rufix setup: open a new shell (or run: export PATH=\"$PATH_BIN:\$PATH\") to use rufix here" ;;
esac
# Another copy earlier on the PATH would answer to `rufix` instead.
for other in $(PATH="$PATH_BIN:$PATH" which -a "rufix$EXE" rufix 2>/dev/null | sort -u); do
  [ "$other" = "$PATH_BIN/rufix$EXE" ] || [ "$other" = "$PATH_BIN/rufix" ] || \
    echo "rufix setup: warning: another rufix is on the PATH: $other - remove it, or it may answer to rufix" >&2
done
