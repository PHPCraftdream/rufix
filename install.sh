#!/usr/bin/env sh
# rufix setup for ONE repository: run it from that repository's folder.
# It builds the release binary with Zig and runs `rufix install` there, which
# copies the binary to .claude/rufix/ and writes the hooks, the shell wrapper
# and the mod into .claude/. Nothing is installed outside the folder: no PATH
# entry, nothing in ~/.claude.
#
# Usage (from the repository to protect):
#   /path/to/rufix/install.sh                 set up this folder
#   /path/to/rufix/install.sh --env-files     hooks also load external env files
#   /path/to/rufix/install.sh --revert        take everything out of this folder
#   /path/to/rufix/install.sh --clean-global  one-off: remove what older versions
#                                             put outside repositories (hooks in
#                                             ~/.claude/settings.json, the binaries,
#                                             the PATH line)
#
# Private values come from secrets/values.zig (in the rufix folder) when it exists.
set -e
TARGET="$(pwd)"
SRC="$(cd "$(dirname "$0")" && pwd)"

ENVFILES=""
MODE="install"
for arg in "$@"; do
  case "$arg" in
    --revert) MODE="revert" ;;
    --clean-global) MODE="clean-global" ;;
    --env-files) ENVFILES="--env-files" ;;
    *) echo "rufix setup: unknown flag $arg (supported: --env-files, --revert, --clean-global)" >&2; exit 1 ;;
  esac
done

EXE=""
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) EXE=".exe" ;; esac
LOCAL="$TARGET/.claude/rufix"

if [ "$MODE" = "revert" ]; then
  if [ -x "$LOCAL/rufix$EXE" ]; then
    "$LOCAL/rufix$EXE" uninstall
  else
    echo "rufix is not installed in $TARGET"
  fi
  # A binary that was running could not delete itself (Windows): it is gone now.
  rm -f "$LOCAL/rufix$EXE" "$LOCAL/rufix-shell$EXE" "$LOCAL/.gitignore"
  rmdir "$LOCAL" 2>/dev/null || true
  echo "rufix removed from $TARGET."
  exit 0
fi

(cd "$SRC" && zig build -Doptimize=ReleaseSmall)
BUILT="$SRC/zig-out/bin/rufix$EXE"

if [ "$MODE" = "clean-global" ]; then
  # What older versions installed: hooks in ~/.claude/settings.json, the
  # binaries in $RUFIX_BIN_DIR (default ~/.local/bin) and a PATH line.
  BIN="${RUFIX_BIN_DIR:-$HOME/.local/bin}"
  MARK="# rufix: binary on the PATH"
  "$BUILT" uninstall --global
  rm -f "$BIN/rufix$EXE" "$BIN/rufix-shell$EXE" "$BIN/rufix$EXE.new"
  for rc in "$HOME/.profile" "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [ -f "$rc" ] && grep -qF "$MARK" "$rc"; then
      # grep exits 1 when our line was the only one: the empty file is right.
      { grep -vF "$MARK" "$rc" || true; } > "$rc.rufix-tmp"
      mv "$rc.rufix-tmp" "$rc"
      echo "rufix setup: removed the PATH line from $rc"
    fi
  done
  echo "rufix setup: repositories set up by an older version still call $BIN/rufix:"
  echo "rufix setup: run the installer again in each of them."
  exit 0
fi

cd "$TARGET"
"$BUILT" install $ENVFILES
"$LOCAL/rufix$EXE" check $ENVFILES
