package redact

import (
	"strings"
	"testing"
)

// testRules mirror the classic format filter set as explicit data — the
// engine ships no rules, stores are built with NewWithRules.
var testRules = []RuleData{
	{Name: "atlassian-pat", Match: `ATATT[A-Za-z0-9_\-=]{18,}`, Replace: "[REDACTED:atlassian-pat]"},
	{Name: "gitlab-pat", Match: `glpat-[A-Za-z0-9_\-]{20,}`, Replace: "[REDACTED:gitlab-pat]"},
	{Name: "jwt", Match: `eyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}`, Replace: "[REDACTED:jwt]"},
	{Name: "bearer", Match: `(?i)(bearer\s+)[A-Za-z0-9_\-.+/=]{16,}`, Replace: "${1}[REDACTED:token]"},
	{Name: "kv-json", Match: `(?i)("(?:password|secret)"\s*:\s*")[^"]{8,}`, Replace: "${1}[REDACTED]"},
	{Name: "query-param", Match: `(?i)([?&](?:token|apikey)=)[A-Za-z0-9_\-.+/=%]{8,}`, Replace: "${1}[REDACTED]"},
	{Name: "env-kv", Match: `(?im)^([A-Za-z0-9_]*(?:TOKEN|SECRET)[A-Za-z0-9_]*\s*=\s*)[^[\s].*$`, Replace: "${1}[REDACTED]"},
}

func testStore() *Store {
	return NewWithRules(map[string]string{
		"JIRA_TOKEN":       "rufix_test_code_secret_number_001",
		"CONFLUENCE_TOKEN": "rufix_test_code_secret_number_002",
		"JIRA_URL":         "https://jira.internal.example",
		"GITLAB_URL":       "https://git.internal.example:8443",
		"GITLAB_TOKEN":     "rufix_test_code_secret_number_003",
		"DEFAULT_LANGUAGE": "ru",
		"CONFLUENCE_EMAIL": "someone@example",
	}, testRules)
}

const (
	token1 = "rufix_test_code_secret_number_001"
	token3 = "rufix_test_code_secret_number_003"
)

func TestRedactExactValuesAreReversible(t *testing.T) {
	st := testStore()
	in := "curl https://jira.internal.example/rest -H \"Authorization: Bearer " + token1 + "\""
	out, n := st.Redact(in)
	if n != 2 || strings.Contains(out, token1) || strings.Contains(out, "jira.internal.example") {
		t.Errorf("Redact: n=%d out=%q", n, out)
	}
	back, n := st.Restore(out)
	if back != in || n != 2 {
		t.Errorf("Restore round-trip: n=%d out=%q", n, back)
	}
}

func TestRedactBearerWithUnknownTokenIsIrreversible(t *testing.T) {
	st := testStore()
	out, _ := st.Redact("Authorization: Bearer AAAAAAAABBBBBBBBCCCC")
	if !strings.Contains(out, "[REDACTED:token]") || strings.Contains(out, "BBBBBBBB") {
		t.Errorf("out=%q", out)
	}
	// The known token inside the header must stay reversible (exact rule first).
	out2, _ := st.Redact("Authorization: Bearer " + token3)
	if !strings.HasPrefix(out2, "Authorization: Bearer [S:") {
		t.Errorf("known token should be a placeholder, got %q", out2)
	}
}

func TestRedactFormatRules(t *testing.T) {
	st := testStore()
	cases := []struct{ in, want string }{
		{"token ATATT3abcdefgHIJKLMNOPQRSTUVWX", "[REDACTED:atlassian-pat]"},
		{"glpat-AbC1234567890abcdefghijklmnop", "[REDACTED:gitlab-pat]"},
		{"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.SflKxwRJSMeKKF2QT4", "[REDACTED:jwt]"},
		{"{\"password\": \"hunter2secret\"}", "{\"password\": \"[REDACTED]\"}"},		{"https://x.example/api?token=supersecretvalue", "https://x.example/api?token=[REDACTED]"},
		{"JIRA_TOKEN=leakedvalue", "JIRA_TOKEN=[REDACTED]"},
	}
	for _, c := range cases {
		out, n := st.Redact(c.in)
		if n == 0 || !strings.Contains(out, c.want) {
			t.Errorf("Redact(%q) = %q, n=%d, want substring %q", c.in, out, n, c.want)
		}
	}
}

func TestPortHostCoverage(t *testing.T) {
	st := testStore()
	out, n := st.Redact("clone https://git.internal.example:8443/group/repo.git or git.internal.example raw")
	if n != 2 || strings.Contains(out, "git.internal.example") {
		t.Errorf("out=%q n=%d", out, n)
	}
}

func TestHostPlaceholderVsTokenPlaceholder(t *testing.T) {
	st := testStore()
	hostOut, _ := st.Redact("see https://jira.internal.example/x")
	tokOut, _ := st.Redact("token is " + token1)
	if !st.HostPlaceholder(hostOut) {
		t.Errorf("host placeholder must seed the allowlist: %q", hostOut)
	}
	if st.HostPlaceholder(tokOut) {
		t.Errorf("token placeholder must not seed the allowlist: %q", tokOut)
	}
	if !st.HasPlaceholders(tokOut) || !st.HasPlaceholders(hostOut) {
		t.Errorf("HasPlaceholders failed")
	}
}

func TestNonCredentialKeysAreNotProtected(t *testing.T) {
	st := testStore()
	out, n := st.Redact("language ru for someone@example")
	if n != 0 || out != "language ru for someone@example" {
		t.Errorf("non-secrets must stay untouched: n=%d out=%q", n, out)
	}
}

func TestPlaceholderStability(t *testing.T) {
	a := placeholder(token1)
	b := placeholder(token1)
	if a != b || len(a) != len("[S:")+8+len("]") {
		t.Errorf("placeholder %q vs %q", a, b)
	}
	if placeholder("other rufix_test_code_secret_number_004") == a {
		t.Errorf("distinct values must hash distinctly")
	}
}
