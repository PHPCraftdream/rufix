package redact

import (
	"reflect"
	"regexp"
	"strings"
	"testing"

	"rufix/internal/compiledregexp"
)

func TestCompiledRulesPreserveRedactionAndRestore(t *testing.T) {
	rules := append([]RuleData{}, testRules...)
	rules = append(rules, RuleData{
		Match: `(?i)\b((?:[a-z0-9-]+\.)+)internal\.example\b`, Replace: "${1}masked",
		RestoreMatch: `(?i)\b((?:[a-z0-9-]+\.)+)masked\b`, RestoreReplace: "${1}internal.example",
		AllowlistSeed: true, StrictTLD: true,
	})
	programs := make(map[string]*compiledregexp.Regexp)
	for _, rule := range rules {
		for _, pattern := range []string{rule.Match, rule.RestoreMatch} {
			if pattern == "" {
				continue
			}
			re, err := compiledregexp.Compile(pattern)
			if err != nil {
				t.Fatal(err)
			}
			programs[pattern] = re
		}
	}
	vars := map[string]string{"TOKEN": token1, "URL": "https://jira.internal.example"}
	ready, err := NewWithCompiledRules(vars, rules, func(pattern string) (*compiledregexp.Regexp, bool) {
		re, ok := programs[pattern]
		return re, ok
	})
	if err != nil {
		t.Fatal(err)
	}
	legacy := NewWithRules(vars, rules)
	for _, text := range []string{
		"plain", "Bearer " + token1, "token ATATT3abcdefgHIJKLMNOPQRSTUVWX",
		"see https://api.internal.example/x and API.INTERNAL.EXAMPLE.UP",
		"curl https://jira.internal.example -H 'Bearer " + token1 + "'",
		"TOKEN=leakedvalue", "[S:abcd1234] https://api.masked/x",
	} {
		got, n := ready.Redact(text)
		want, wantN := legacy.Redact(text)
		if got != want || n != wantN || ready.HostPlaceholder(got) != legacy.HostPlaceholder(want) || ready.HasDomainMask(got) != legacy.HasDomainMask(want) {
			t.Fatal("precompiled forward path differs from existing semantics")
		}
		back, bn := ready.Restore(got)
		wantBack, wantBN := legacy.Restore(want)
		if back != wantBack || bn != wantBN {
			t.Fatal("precompiled reverse path differs from existing semantics")
		}
		domains, dn := ready.RestoreDomains(got)
		wantDomains, wantDN := legacy.RestoreDomains(want)
		if domains != wantDomains || dn != wantDN {
			t.Fatal("domain-only restore differs from existing semantics")
		}
	}
}

func TestMissingAndStaleProgramsFailClosed(t *testing.T) {
	a, err := compiledregexp.Compile("a")
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		rules  []RuleData
		lookup func(string) (*compiledregexp.Regexp, bool)
	}{
		{[]RuleData{{Match: "a"}}, nil},
		{[]RuleData{{Match: "a"}}, func(string) (*compiledregexp.Regexp, bool) { return nil, true }},
		{[]RuleData{{Match: "b"}}, func(string) (*compiledregexp.Regexp, bool) { return a, true }},
		{[]RuleData{{Match: "a", RestoreMatch: "b"}}, func(s string) (*compiledregexp.Regexp, bool) { return a, s == "a" }},
	} {
		st, err := NewWithCompiledRules(nil, tc.rules, tc.lookup)
		if err == nil || st != nil || !strings.Contains(err.Error(), "go generate") {
			t.Fatal("missing or stale programs must fail without runtime fallback")
		}
	}
	if _, err := NewWithCompiledRules(nil, nil, nil); err != nil {
		t.Fatal("empty skeleton must not require any generated filters")
	}
}

func TestPlaceholderScannerMatchesRegexp(t *testing.T) {
	re := regexp.MustCompile(`\[S:[0-9a-f]{8}\]`)
	for _, text := range []string{
		"", "[S:", "[S:abcd1234]", "[S:ABCD1234]", "[S:abcdefg0]", "[S:1234567]", "[S:123456789]",
		"[S:[S:abcd1234]", "[S:abcd1234][S:01234567]", "é\xff[S:abcd1234] trailing", "[s:abcd1234]",
	} {
		var got []string
		for token, tail := nextPlaceholder(text); token != ""; token, tail = nextPlaceholder(tail) {
			got = append(got, token)
		}
		if !reflect.DeepEqual(got, re.FindAllString(text, -1)) {
			t.Fatalf("placeholder scanner mismatch for %q", text)
		}
	}
}
