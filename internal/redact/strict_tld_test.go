package redact

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"testing"
)

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

// Regression guards for the MCP domain-only restore path: RestoreDomains
// resolves reverse-rule masks but never touches exact [S:hash] placeholders;
// HasDomainMask triggers on masks only, never on placeholders.
func TestRestoreDomainsNeverTouchesExactPlaceholders(t *testing.T) {
	st := NewWithRules(map[string]string{"TOKEN": "rufix_test_code_secret_number_001"}, []RuleData{{
		Name: "d", Match: `(?i)\b((?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+)xq\b`,
		Replace: "${1}wide", RestoreMatch: `(?i)\b((?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+)wide\b`,
		RestoreReplace: "${1}xq", AllowlistSeed: true,
	}})
	masked, _ := st.Redact("link https://api.xq/x token rufix_test_code_secret_number_001")
	if !strings.Contains(masked, "[S:") || !strings.Contains(masked, "api.wide") {
		t.Fatalf("setup: %q", masked)
	}
	out, n := st.RestoreDomains(masked)
	if n != 1 || !strings.Contains(out, "api.xq/x") || !strings.Contains(out, "[S:") {
		t.Errorf("RestoreDomains: n=%d out=%q", n, out)
	}
	if st.HasDomainMask("[S:" + hash8ForTest("x") + "] placeholder") {
		t.Errorf("HasDomainMask must not trigger on placeholders")
	}
	if !st.HasDomainMask("https://api.wide/x") {
		t.Errorf("HasDomainMask must trigger on a mask")
	}
	// Full Restore still resolves both directions.
	full, fn := st.Restore(masked)
	if fn != 2 || !strings.Contains(full, "api.xq/x") || strings.Contains(full, "[S:") {
		t.Errorf("Restore: fn=%d out=%q", fn, full)
	}
}

func hash8ForTest(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])[:8]
}

// Edge: two masks in a row — "xq.xq": the first is a middle label (skipped),
// the trailing one is replaced; indices from the original string stay valid.
func TestStrictTLDTwoAdjacentMasks(t *testing.T) {
	rules := []RuleData{{
		Name: "tld", Match: `(?i)\b((?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+)xq\b`,
		Replace: "${1}wide", StrictTLD: true,
	}}
	st := NewWithRules(nil, rules)
	out, n := st.Redact("link https://api.xq/x and xq.xq end")
	if n != 2 || out != "link https://api.wide/x and xq.wide end" {
		t.Errorf("adjacent: n=%d out=%q", n, out)
	}
}
