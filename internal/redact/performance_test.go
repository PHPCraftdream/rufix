package redact

import (
	"regexp"
	"strings"
	"testing"
)

func TestReplaceExactMatchesStandardLibrary(t *testing.T) {
	cases := []struct{ input, old, replacement string }{
		{"plain text", "absent", "x"},
		{"aaaaa", "aa", "longer"},
		{"abc abc abc", "abc", "abcabc"},
		{"a b a", "a", ""},
		{"ééé", "é", "$1"},
	}
	for _, tc := range cases {
		got, n := replaceExact(tc.input, tc.old, tc.replacement)
		if got != strings.ReplaceAll(tc.input, tc.old, tc.replacement) || n != strings.Count(tc.input, tc.old) {
			t.Errorf("replaceExact(%q, %q, %q) = %q, %d", tc.input, tc.old, tc.replacement, got, n)
		}
	}
}

func TestReplaceRulePreservesSemantics(t *testing.T) {
	cases := []struct{ pattern, template, input string }{
		{`(?i)(bearer\s+)([a-z]+)`, "${1}[REDACTED]", "Bearer abc and bearer def"},
		{`(?m)^(?P<key>[a-z]+)=(.*)$`, "${key}=$$${2}", "one=first\ntwo=second"},
		{`(a)?b`, "${1}:${missing}:$0", "b ab"},
		{`\Ba\B`, "x", "aaa"},
		{`a*`, "x", "aaa b aa"},
		{`^|$`, "x", "é"},
		{``, "x", "éé"},
		{`x`, "$$$1${missing}", "x x"},
		{`absent`, "x", "plain text"},
	}
	for _, tc := range cases {
		for _, strict := range []bool{false, true} {
			for _, seeded := range []bool{false, true} {
				re := regexp.MustCompile(tc.pattern)
				wantSeeds := map[string]string{}
				gotSeeds := map[string]string{}
				var seed func(string, string)
				if seeded {
					seed = func(repl, matched string) { gotSeeds[repl] = matched }
				}
				got, n := replaceRule(tc.input, re, tc.template, strict, seed)
				locs := re.FindAllStringIndex(tc.input, -1)
				wantN := len(locs)
				want := re.ReplaceAllString(tc.input, tc.template)
				if strict || seeded {
					var b strings.Builder
					last := 0
					wantN = 0
					for _, loc := range locs {
						if strict && isMidLabelTail(tc.input, loc[1]) {
							continue
						}
						matched := tc.input[loc[0]:loc[1]]
						repl := re.ReplaceAllString(matched, tc.template)
						b.WriteString(tc.input[last:loc[0]])
						b.WriteString(repl)
						last = loc[1]
						wantN++
						if seeded {
							wantSeeds[repl] = matched
						}
					}
					b.WriteString(tc.input[last:])
					want = b.String()
				}
				if got != want || n != wantN {
					t.Errorf("pattern=%q strict=%v seeded=%v: got %q/%d want %q/%d", tc.pattern, strict, seeded, got, n, want, wantN)
				}
				if len(gotSeeds) != len(wantSeeds) {
					t.Fatal("seed count changed")
				}
				for key, value := range wantSeeds {
					if gotSeeds[key] != value {
						t.Error("seed value changed")
					}
				}
			}
		}
	}
}

func TestRuleRegexesSharedAndLazy(t *testing.T) {
	rules := compileRules([]RuleData{
		{Match: "a", RestoreMatch: "b"},
		{Match: "a", RestoreMatch: "a"},
	})
	if rules[0].re != rules[1].re || rules[0].re != rules[1].restoreRe {
		t.Fatal("identical patterns must share compilation")
	}
	if rules[0].re.get() != rules[1].re.get() {
		t.Error("compiled regex must be reused")
	}
	st := NewWithRules(nil, []RuleData{{Match: "a", Replace: "x", RestoreMatch: "b", RestoreReplace: "a"}})
	st.rules[0].restoreRe.get = func() matcher { panic("unused reverse regex compiled") }
	if got, n := st.Redact("a"); got != "x" || n != 1 {
		t.Error("forward replacement failed")
	}
	st = NewWithRules(nil, []RuleData{{Match: "a", Replace: "x", RestoreMatch: "b", RestoreReplace: "a"}})
	st.rules[0].re.get = func() matcher { panic("unused forward regex compiled") }
	if got, n := st.RestoreDomains("b"); got != "a" || n != 1 {
		t.Error("reverse replacement failed")
	}
}

func TestInvalidUnusedRegexStillPanics(t *testing.T) {
	for _, rule := range []RuleData{{Match: "("}, {Match: "a", RestoreMatch: "("}} {
		t.Run(rule.Match+rule.RestoreMatch, func(t *testing.T) {
			defer func() {
				if recover() == nil {
					t.Error("invalid rule must fail before processing content")
				}
			}()
			NewWithRules(nil, []RuleData{rule})
		})
	}
}

func TestOrderedReplacementsPreserved(t *testing.T) {
	const long = "rufix_test_code_secret_number_001_suffix"
	const short = "rufix_test_code_secret_number_001"
	st := NewWithRules(map[string]string{"LONG_TOKEN": long, "SHORT_TOKEN": short}, []RuleData{
		{Match: "first", Replace: "second"},
		{Match: "second", Replace: "third"},
	})
	got, n := st.Redact(long + " " + short + " first")
	want := placeholder(long) + " " + placeholder(short) + " third"
	if got != want || n != 4 {
		t.Error("exact-before-rules, longest-first or rule order changed")
	}
}
