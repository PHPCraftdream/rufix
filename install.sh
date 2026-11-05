#!/usr/bin/env sh
# rufix setup: build, install the binary globally ($GOPATH/bin), wire hooks.
#
# Usage:
#   ./install.sh              install: build + go install . + rufix install (global settings)
#   ./install.sh --project    same, but hooks into ./.claude/settings.json
#   ./install.sh --revert     uninstall hooks (same scope) and remove the binary
set -e
cd "$(dirname "$0")"

PROJECT=""
REVERT=0
for arg in "$@"; do
  case "$arg" in
    --revert) REVERT=1 ;;
    --project) PROJECT="--project" ;;
    *) echo "rufix setup: unknown flag $arg (supported: --project, --revert)" >&2; exit 1 ;;
  esac
done

if [ "$REVERT" = "1" ]; then
  if command -v rufix >/dev/null 2>&1; then
    rufix uninstall $PROJECT
  else
    echo "rufix binary not found on PATH; skipping hook uninstall"
  fi
  go clean -i .
  echo "rufix removed."
  exit 0
fi

go build ./...
go install .
if command -v rufix >/dev/null 2>&1; then
  rufix install $PROJECT
  rufix check $PROJECT
else
  echo "rufix was built into \$(go env GOPATH)/bin but is not on PATH; add it and run: rufix install" >&2
  exit 1
fi
