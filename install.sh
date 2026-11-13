#!/usr/bin/env sh
# rufix setup: build the release binary with Zig, install it, register the hooks.
#
# Usage:
#   ./install.sh               build + install the binary + hooks in ~/.claude/settings.json
#   ./install.sh --project     same, but hooks into ./.claude/settings.json
#   ./install.sh --env-files   hooks also load external env files (rufix hook --env-files)
#   ./install.sh --project --shell
#                              also wrap this repository's shell (output of failing commands)
#   ./install.sh --revert      uninstall hooks (same scope) and remove the binaries
#
# The binary goes to $RUFIX_BIN_DIR (default ~/.local/bin). Private values
# come from secrets/values.zig when it exists.
set -e
cd "$(dirname "$0")"

PROJECT=""
ENVFILES=""
SHELLWRAP=""
REVERT=0
for arg in "$@"; do
  case "$arg" in
    --revert) REVERT=1 ;;
    --project) PROJECT="--project" ;;
    --env-files) ENVFILES="--env-files" ;;
    --shell) SHELLWRAP="--shell" ;;
    *) echo "rufix setup: unknown flag $arg (supported: --project, --env-files, --shell, --revert)" >&2; exit 1 ;;
  esac
done

BIN="${RUFIX_BIN_DIR:-$HOME/.local/bin}"
EXE=""
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) EXE=".exe" ;; esac
TARGET="$BIN/rufix$EXE"

if [ "$REVERT" = "1" ]; then
  if [ -x "$TARGET" ]; then
    "$TARGET" uninstall $PROJECT
  else
    echo "rufix binary not found at $TARGET; skipping hook uninstall"
  fi
  rm -f "$TARGET" "$BIN/rufix-shell$EXE"
  echo "rufix removed."
  exit 0
fi

zig build -Doptimize=ReleaseSmall
mkdir -p "$BIN"
# Replace atomically: a hook may be running the old binary right now.
cp "zig-out/bin/rufix$EXE" "$TARGET.new"
mv -f "$TARGET.new" "$TARGET"
"$TARGET" install $PROJECT $ENVFILES $SHELLWRAP
"$TARGET" check $PROJECT $ENVFILES
