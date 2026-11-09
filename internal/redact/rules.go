package redact

import (
	"fmt"
	"regexp"
	"regexp/syntax"
	"sync"

	"rufix/internal/compiledregexp"
)

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
	// StrictTLD matches the TLD only at the end of a domain: a match followed
	// by "." + domain char (a middle label like XCom.UP) is rejected. Without
	// it the matched name may be a middle label, since RE2 has no lookahead.
	StrictTLD bool
}

type matcher interface {
	MatchString(string) bool
	FindAllStringIndex(string, int) [][]int
	FindAllStringSubmatchIndex(string, int) [][]int
	ReplaceAllString(string, string) string
	ExpandString([]byte, string, string, []int) []byte
}

type lazyRegexp struct {
	get func() matcher
}

type compiledRule struct {
	data      RuleData
	re        *lazyRegexp
	restoreRe *lazyRegexp
}

func compileRules(rules []RuleData) []compiledRule {
	cache := make(map[string]*lazyRegexp)
	prepare := func(pattern string) *lazyRegexp {
		if re, ok := cache[pattern]; ok {
			return re
		}
		// Проверяем оба направления сразу, компилируем только используемое.
		if _, err := syntax.Parse(pattern, syntax.Perl); err != nil {
			panic(err)
		}
		re := &lazyRegexp{get: sync.OnceValue(func() matcher {
			return regexp.MustCompile(pattern)
		})}
		cache[pattern] = re
		return re
	}
	compiled := make([]compiledRule, 0, len(rules))
	for _, r := range rules {
		cr := compiledRule{data: r, re: prepare(r.Match)}
		if r.RestoreMatch != "" {
			cr.restoreRe = prepare(r.RestoreMatch)
		}
		compiled = append(compiled, cr)
	}
	return compiled
}

func loadCompiledRules(rules []RuleData, lookup func(string) (*compiledregexp.Regexp, bool)) ([]compiledRule, error) {
	cache := make(map[string]*lazyRegexp)
	prepare := func(pattern string) (*lazyRegexp, bool) {
		if re, ok := cache[pattern]; ok {
			return re, true
		}
		if lookup == nil {
			return nil, false
		}
		re, ok := lookup(pattern)
		if !ok || re == nil || re.String() != pattern {
			return nil, false
		}
		ready := &lazyRegexp{get: func() matcher { return re }}
		cache[pattern] = ready
		return ready, true
	}
	compiled := make([]compiledRule, 0, len(rules))
	for i, rule := range rules {
		forward, ok := prepare(rule.Match)
		if !ok {
			return nil, fmt.Errorf("compiled forward regex missing or stale for filter %d; run go generate ./internal/secretvalues", i)
		}
		cr := compiledRule{data: rule, re: forward}
		if rule.RestoreMatch != "" {
			reverse, ok := prepare(rule.RestoreMatch)
			if !ok {
				return nil, fmt.Errorf("compiled reverse regex missing or stale for filter %d; run go generate ./internal/secretvalues", i)
			}
			cr.restoreRe = reverse
		}
		compiled = append(compiled, cr)
	}
	return compiled, nil
}
