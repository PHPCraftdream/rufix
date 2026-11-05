// Package secretvalues holds the real secret values and replacement filters.
// The engine and this committed skeleton ship ZERO rules and ZERO values:
// by default nothing is replaced. Fill both in your local working copy of
// this file — it is pinned with git skip-worktree, so local edits never get
// committed. Values are compiled into the binary: never distribute the
// built executable.
package secretvalues

import (
	"sync"

	"rufix/internal/redact"
)

// Vars returns the exact secret values keyed by any variable name. Names
// with TOKEN/SECRET/PASSWORD/PASSWD/PAT/KEY/CREDENTIAL segments protect the
// whole value (≥ 6 chars); URL-valued variables protect the full URL, bare
// host and portless host. Empty values are skipped.
func Vars() map[string]string {
	return map[string]string{}
}

// Rules returns the replacement filters (nil = nothing is replaced).
// A rule carries a forward regex + replacement and optionally a reverse
// rule ("and back") and AllowlistSeed to make masked patterns restoreable
// in Bash commands. Example — mask every *.com domain as *.intra:
//
//	return []redact.RuleData{{
//		Name:           "com-to-intra",
//		Match:          `(?i)\b((?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+)com\b`,
//		Replace:        "${1}intra",
//		RestoreMatch:   `(?i)\.intra\b`,
//		RestoreReplace: ".com",
//		AllowlistSeed:  true,
//	}}
func Rules() []redact.RuleData {
	return nil
}

// Overlay copies non-empty Vars() values into vars, overriding same-named
// entries (the local file is the primary source, env files are fallbacks).
func Overlay(vars map[string]string) {
	for key, value := range Vars() {
		if value != "" {
			vars[key] = value
		}
	}
}

// NonEmpty counts filled values (diagnostics only, no values revealed).
func NonEmpty() int {
	n := 0
	for _, value := range Vars() {
		if value != "" {
			n++
		}
	}
	return n
}

var store = sync.OnceValue(func() *redact.Store {
	vars := make(map[string]string)
	Overlay(vars)
	return redact.NewWithRules(vars, Rules())
})

// Replace swaps real values for placeholders (outbound): known values become
// reversible [S:hash8], rule-detected strings become [REDACTED:<rule>] or
// structural masks.
func Replace(s string) (string, int) {
	return store().Redact(s)
}

// Restore puts the real values back in place of placeholders (inbound).
func Restore(s string) (string, int) {
	return store().Restore(s)
}
