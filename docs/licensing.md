# License policy

rufix's own code is dual-licensed under **MIT OR Apache-2.0** (`LICENSE-MIT`,
`LICENSE-APACHE`).

## Dependencies

rufix has no third-party dependencies. It is built with Zig 0.16 and links
only the platform C runtime (UCRT and KERNEL32/SHELL32 on Windows, glibc on
Linux). The Zig standard library is MIT-licensed and is compiled into the
binary; its notice travels with the Zig toolchain.

The regex compiler, Pike VM, JSON reader and URL parser are original code.
They reproduce the observable behaviour of Go's `regexp` and `net/url` (as
recorded in the conformance fixtures) without copying Go source.

## Adding a dependency

A new dependency needs an explicit reason in the task, a license from the
allowlist below and its notice kept intact:

- MIT
- Apache-2.0
- BSD-2-Clause
- BSD-3-Clause
- ISC
- 0BSD

An unlisted license requires explicit review, not an exception.
