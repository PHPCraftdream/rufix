package redact

import "regexp"

// RuleData is one replacement filter. Rules are DATA: the engine ships zero
// rules and never will — every filter, mask or value lives in the
// skip-worktree internal/secretvalues/values.go (its Rules() method).
// Editing the engine for yet another filter is a P0 blocker.
type RuleData struct {
	Name           string // identifier echoed in [REDACTED:<name>]
	Match          string // forward regex applied to tool output
	Replace        string // forward replacement template (${1}, …)
	RestoreMatch   string // optional reverse regex ("and back"), applied by Restore
	RestoreReplace string
	AllowlistSeed  bool // forward replacements seed the Bash restore allowlist
}

type compiledRule struct {
	data      RuleData
	re        *regexp.Regexp
	restoreRe *regexp.Regexp
}

func compileRules(rules []RuleData) []compiledRule {
	compiled := make([]compiledRule, 0, len(rules))
	for _, r := range rules {
		cr := compiledRule{data: r, re: regexp.MustCompile(r.Match)}
		if r.RestoreMatch != "" {
			cr.restoreRe = regexp.MustCompile(r.RestoreMatch)
		}
		compiled = append(compiled, cr)
	}
	return compiled
}
