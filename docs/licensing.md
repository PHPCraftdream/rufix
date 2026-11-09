# License policy and CI checks

rufix's own code is dual-licensed under **MIT OR Apache-2.0**. Bundled and
linked third-party code retains its original license and notices; the root
license choice does not relicense that code.

## Dependency allowlist

The `licenses` CI job uses `github.com/google/go-licenses/v2@v2.0.1` to inspect
all Go packages, including test-only imports. It checks both Linux and Windows
dependency graphs on an Ubuntu runner. The scanner is a pinned CI-only tool;
it is not a runtime dependency and does not change the application's `go.mod`.

The single machine-enforced allowlist is `LICENSE_ALLOWLIST` in
`.github/workflows/ci.yml`:

- MIT
- Apache-2.0
- BSD-2-Clause
- BSD-3-Clause
- ISC
- 0BSD

A missing, unknown, or unlisted dependency license fails the job. Multiple
recognized licenses must all be allowed; this is deliberately conservative,
not a general evaluator of arbitrary SPDX expressions or licensing exceptions.
An unlisted license requires explicit review and a policy change, not an
ignore flag. No package exclusions are configured.

This allowlist is a project policy for permissively licensed components,
not an automated legal opinion about every possible combination or use.

## Copied source and notices

Module dependency scanning alone is not sufficient for copied source.
`legal_test.go` adds the following checks, run by both the normal Go test suite
and the dedicated license job:

- The root MIT and Apache license texts and the bundled Go BSD license must
  remain tracked and match their reviewed SHA-256 digests.
- The four copied Go matcher files must retain their original copyright
  statements and their pointers to the BSD license file.
- New tracked license/notice documents and unregistered foreign copyright
  or SPDX license identifiers in Go source fail until explicitly reviewed and
  registered. Conflicting new identifiers in registered copied files also fail.
- Line endings are normalized so Windows CRLF checkouts do not fail.

The copied matcher comes from Go 1.26.0 under BSD-3-Clause; provenance is
recorded in `internal/compiledregexp/README.md`. The inventory of reviewed
license documents and source notices lives in `legal_test.go`. The verifier
has negative controls for missing or changed licenses, removed notices,
unregistered copied source, unregistered license documents, and untracked
required licenses.

Inventory checks use Git's tracked file list, so generated private regex
programs and local build artifacts are excluded. The verifier deliberately
does not read the skip-worktree `internal/secretvalues/values.go` working copy.

## Review obligations and limits

When adding a dependency or copying code:

1. Verify its actual source and license, including notices and exceptions.
2. Keep the original license and required copyright statements.
3. Review changes to the allowlist, recorded license digests, and copied-source
   inventory as licensing decisions, not routine hash refreshes.
4. Include required third-party notices with any redistributed source or
   binary. The check does not create distribution bundles or satisfy their
   packaging obligations by itself.

Automated checks cannot infer the provenance of code whose notices were
stripped, prove that an author had the rights to license code, or identify all
non-Go/native/system dependencies. New copied code still requires human
review. License detection is heuristic; uncertain classifications require
review rather than automatic approval.

License texts are checked byte-for-byte after CRLF-to-LF normalization.
Intentional wording changes therefore fail until their new text is reviewed.
No legal obligations are waived by a green check.
