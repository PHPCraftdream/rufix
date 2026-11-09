# Compiled regexp programs

`regexp.go`, `exec.go`, `onepass.go`, and `backtrack.go` are copied from
[Go **1.26.0**, `src/regexp`](https://github.com/golang/go/tree/go1.26.0/src/regexp),
with only the package name changed to
`compiledregexp`. Matching, capture, replacement, one-pass, bit-state,
and NFA execution retain the upstream implementation. See `LICENSE` for
the Go authors' BSD license. The root project's dual license does not
replace this license.

Upstream Git blob hashes before the package rename:

| File | Git blob |
|---|---|
| regexp.go | 66c73693995a423d7dc8d105bc0a3b0c6de752ed |
| exec.go | 3fc4b684febd6034230df4a4c00a082961c7d0c9 |
| onepass.go | 96e360661b9aa9407c879d008e6e3ad61ddd68ad |
| backtrack.go | 7c37c66a80c787e0ed1ea4ccc886eecb9df05d2d |

Local additions are isolated in `program.go`: lookup of generated programs
and serialization into Go literals. All matcher metadata, including the
one-pass program and machine-pool selection, is serialized during generation.
The generated source does not call a parser or compiler at runtime.

Run `go generate ./internal/secretvalues` before building. The generator
reads the local `secretvalues.Rules()`, compiles both directions, and writes
`filters_generated.go`. This file is **gitignored** because rules can contain
private hosts and patterns. It must never be committed or published. Its
contents also end up in the private binary; do not distribute that binary.
The generated fixture file is test-only and contains harmless patterns.

The hook requires a generated program for each configured expression.
Missing or stale programs fail closed; there is no runtime compilation fallback
on the production hook path. Changes to exact values alone do not require
regex regeneration, but the setup scripts always regenerate before building.

The generator is trusted build tooling. Review upstream changes and update
this pinned copy deliberately when changing the Go toolchain. Conformance
tests compare the generated matcher against the toolchain's standard
`regexp`, including captures, UTF-8, empty matches, and replacements.
