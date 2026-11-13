# Security policy

## Supported versions

The latest commit on `main` is the only supported version.

## Reporting a vulnerability

Do not open a public issue for security reports. Contact the maintainers
privately (open a discussion or reach the repo owner directly) with a
description and, if possible, a minimal reproduction.

## Security model notes

- rufix is a local filter between Claude Code and the model. It never makes
  network requests and has no third-party dependencies.
- Values compiled from `secrets/values.zig` live inside your private binary —
  never distribute executables built with filled values.
- rufix protects the model boundary, not your disk: the local session
  transcript and local telemetry (OTel) see original tool output. User
  prompts and CLAUDE.md content are out of scope (filter at the proxy layer).
- Failed tool calls bypass the hooks: PostToolUse fires only on success, and
  `PostToolUseFailure` cannot rewrite the error text. The shell prefix
  (`rufix install --project --shell`) closes this for Bash in the repositories
  where it is installed; MCP error results and `@` file mentions stay
  uncovered. See "What rufix does NOT protect" in the README.
- The committed `src/values.zig` must stay empty; private data belongs in
  `secrets/values.zig`, which git ignores.
