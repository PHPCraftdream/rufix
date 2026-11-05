package redact

import "testing"

func TestStrictTLDMidLabelRejected(t *testing.T) {
	rules := []RuleData{{
		Name: "tld", Match: `(?i)\b((?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+)xq\b`,
		Replace: "${1}wide", RestoreMatch: `(?i)\b((?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+)wide\b`,
		RestoreReplace: "${1}xq", AllowlistSeed: true, StrictTLD: true,
	}}
	st := NewWithRules(nil, rules)

	out, n := st.Redact("https://api.xq/v1 and API.XQ.UP end")
	if n != 1 || out != "https://api.wide/v1 and API.XQ.UP end" {
		t.Errorf("strict tld: n=%d out=%q", n, out)
	}
	if !st.HostPlaceholder("curl https://api.wide/v1") {
		t.Errorf("masked tld must seed the allowlist")
	}
	back, rn := st.Restore("curl https://api.wide/v1 and keep X.WIDE.UP")
	if rn != 1 || back != "curl https://api.xq/v1 and keep X.WIDE.UP" {
		t.Errorf("restore: rn=%d out=%q", rn, back)
	}
}

func TestStrictTLDBoundaries(t *testing.T) {
	rules := []RuleData{{
		Name: "tld", Match: `(?i)\b((?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+)xq\b`,
		Replace: "${1}wide", RestoreMatch: `(?i)\b((?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+)wide\b`,
		RestoreReplace: "${1}xq", StrictTLD: true,
	}}
	st := NewWithRules(nil, rules)

	// TLD at the very end of the string must still match.
	out, n := st.Redact("open https://api.xq")
	if n != 1 || out != "open https://api.wide" {
		t.Errorf("end of string: n=%d out=%q", n, out)
	}
	// "." at the end of a sentence is not a domain continuation.
	out2, n2 := st.Redact("see api.xq. now")
	if n2 != 1 || out2 != "see api.wide. now" {
		t.Errorf("sentence dot: n=%d out=%q", n2, out2)
	}
	// Restore mirrors both boundaries.
	back, rn := st.Restore("api.wide at end and api.wide. next")
	if rn != 2 || back != "api.xq at end and api.xq. next" {
		t.Errorf("restore boundaries: rn=%d out=%q", rn, back)
	}
}
