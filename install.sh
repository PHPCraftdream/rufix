#!/usr/bin/env sh
# rufix setup, once per machine: build the release binary with Zig and put it,
# with its rufix-shell twin, into a folder on the PATH. A repository is then
# set up by `rufix install`, run in that repository; this script touches no
# repository and nothing in ~/.claude.
#
# Usage (from anywhere):
#   /path/to/rufix/install.sh              build, install, add to the PATH
#   /path/to/rufix/install.sh --uninstall  remove the binaries and the PATH line,
#                                          and the hooks older versions put into
#                                          ~/.claude/settings.json
#
# The binary goes to $RUFIX_BIN_DIR (default ~/.local/bin), which is added to
# the PATH through ~/.profile, ~/.bashrc and ~/.zshrc (the ones that exist,
# ~/.profile always). Private values come from secrets/values.zig (in the rufix
# folder) when it exists; run this again after editing it.
set -e
SRC="$(cd "$(dirname "$0")" && pwd)"

MODE="install"
for arg in "$@"; do
  case "$arg" in
    --uninstall) MODE="uninstall" ;;
    *) echo "rufix setup: unknown flag $arg (supported: --uninstall)" >&2; exit 1 ;;
  esac
done

BIN="${RUFIX_BIN_DIR:-$HOME/.local/bin}"
EXE=""
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) EXE=".exe" ;; esac
TARGET="$BIN/rufix$EXE"
TWIN="$BIN/rufix-shell$EXE"
MARK="# rufix: binary on the PATH"

profiles() {
  echo "$HOME/.profile"
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do [ -f "$rc" ] && echo "$rc"; done
}

if [ "$MODE" = "uninstall" ]; then
  if [ -x "$TARGET" ]; then
    # Hooks of older versions, which applied to every repository.
    "$TARGET" uninstall --global
  fi
  rm -f "$TARGET" "$TWIN" "$TARGET.new" "$TARGET.old" "$TWIN.new" "$TWIN.old"
  for rc in $(profiles); do
    if [ -f "$rc" ] && grep -qF "$MARK" "$rc"; then
      # grep exits 1 when our line was the only one: the empty file is right.
      { grep -vF "$MARK" "$rc" || true; } > "$rc.rufix-tmp"
      mv "$rc.rufix-tmp" "$rc"
      echo "rufix setup: removed the PATH line from $rc"
    fi
  done
  echo "rufix removed from $BIN."
  echo "rufix setup: a repository where rufix is still installed now calls a missing binary,"
  echo "rufix setup: which blocks its tool calls: take it out there with \`rufix uninstall\` first."
  exit 0
fi

(cd "$SRC" && zig build -Doptimize=ReleaseSmall)
BUILT="$SRC/zig-out/bin/rufix$EXE"
mkdir -p "$BIN"

# Replaces atomically: a hook may be running the old binary right now. Where
# that blocks the rename (Windows), the old file is moved aside first.
place() {
  cp "$1" "$2.new"
  if ! mv -f "$2.new" "$2" 2>/dev/null; then
    mv -f "$2" "$2.old"
    mv -f "$2.new" "$2"
    rm -f "$2.old" 2>/dev/null || true
  fi
}
place "$BUILT" "$TARGET"
place "$BUILT" "$TWIN"

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

"$TARGET" check
echo "rufix setup: installed in $BIN"
echo "rufix setup: set up a repository: cd <repository> && rufix install"
case ":$PATH:" in
  *":$PATH_BIN:"*) ;;
  *) echo "rufix setup: open a new shell (or run: export PATH=\"$PATH_BIN:\$PATH\") to use rufix" ;;
esac
# Another copy earlier on the PATH would answer to `rufix` instead.
for other in $(PATH="$PATH_BIN:$PATH" which -a "rufix$EXE" rufix 2>/dev/null | sort -u); do
  [ "$other" = "$PATH_BIN/rufix$EXE" ] || [ "$other" = "$PATH_BIN/rufix" ] || \
    echo "rufix setup: warning: another rufix is on the PATH: $other - remove it, or it may answer to rufix" >&2
done
