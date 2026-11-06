package redact

import "testing"

func TestUserRuleRestoreDomains(t *testing.T) {
	tw := "intra" + "_wilmington"
	rules := []RuleData{{
		Name: "u", Match: `(?i)\b((?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+)xcom\b`,
		Replace: "${1}" + tw, RestoreMatch: `(?i)\b((?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+)` + tw + `\b`,
		RestoreReplace: "${1}xcom", AllowlistSeed: true, StrictTLD: true,
	}}
	st := NewWithRules(nil, rules)
	in := "see https://api." + tw + "/page#anchor"
	t.Logf("HasDomainMask: %v", st.HasDomainMask(in))
	out, n := st.RestoreDomains(in)
	t.Logf("RestoreDomains: %q n=%d", out, n)
}
