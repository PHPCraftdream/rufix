# Security policy

## Supported versions

The latest commit on `main` is the only supported version.

## Reporting a vulnerability

Do not open a public issue for security reports. Contact the maintainers
privately (open a discussion or reach the repo owner directly) with a
description and, if possible, a minimal reproduction.

## Security model notes

- rufix is a local filter between Claude Code and the model gateway. It
  never makes network requests itself and uses only the Go standard library.
- Values compiled into `internal/secretvalues/values.go` live inside your
  private binary — never distribute executables built with filled values.
- rufix protects the model boundary, not your disk: the local session
  transcript and local telemetry (OTel) see original tool output. User
  prompts and CLAUDE.md content are out of scope (filter at the proxy layer).
- The committed skeleton of `values.go` must stay empty; `TestStubIsEmpty`
  enforces this, and the file is pinned with `git update-index
  --skip-worktree`.
