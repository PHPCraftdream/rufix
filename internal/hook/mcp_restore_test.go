package hook

import (
	"strings"
	"testing"

	"rufix/internal/redact"
)

func mcpRules() []redact.RuleData {
	return []redact.RuleData{{
		Name: "d", Match: `(?i)\b((?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+)old\.tld\b`,
		Replace: "${1}masked", RestoreMatch: `(?i)\b((?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+)masked\b`,
		RestoreReplace: "${1}old.tld", AllowlistSeed: true,
	}}
}

func TestMCPRestoresDomainMaskInComment(t *testing.T) {
	var out, errb strings.Builder
	code := Run(Config{
		Stdin:  strings.NewReader(`{"hook_event_name":"PreToolUse","tool_name":"mcp__atlassian__jira_add_comment","tool_input":{"issueKey":"P-1","comment":"see https://api.masked/page#anchor"}}`),
		Stdout: &out,
		Stderr: &errb,
		Env:    func(string) string { return "" },
		Stat:   func(string) bool { return false },
		Rules:  mcpRules(),
	})
	if code != 0 || !strings.Contains(out.String(), "api.old.tld/page") || strings.Contains(out.String(), "masked") {
		t.Errorf("MCP domain restore: code=%d out=%q err=%q", code, out.String(), errb.String())
	}
}

func TestMCPRestoresDomainButLeavesExactPlaceholders(t *testing.T) {
	st := redact.NewWithRules(map[string]string{"TOKEN": "rufix_test_code_secret_number_001"}, mcpRules())
	masked, _ := st.Redact("token rufix_test_code_secret_number_001 link https://api.old.tld/x")
	in := `{"hook_event_name":"PreToolUse","tool_name":"mcp__atlassian__jira_add_comment","tool_input":{"comment":"` + masked + `"}}`
	var out, errb strings.Builder
	code := Run(Config{
		Stdin:  strings.NewReader(in),
		Stdout: &out,
		Stderr: &errb,
		Env:    func(string) string { return "" },
		Stat:   func(string) bool { return false },
		Rules:  mcpRules(),
	})
	if code != 0 || strings.Contains(out.String(), testToken) || !strings.Contains(out.String(), "api.old.tld/x") || !strings.Contains(out.String(), "[S:") {
		t.Errorf("domain restored, [S:hash] must stay: code=%d out=%q", code, out.String())
	}
}

func TestMCPWithoutMasksSilent(t *testing.T) {
	var out, errb strings.Builder
	code := Run(Config{
		Stdin:  strings.NewReader(`{"hook_event_name":"PreToolUse","tool_name":"mcp__atlassian__jira_add_comment","tool_input":{"comment":"plain text no masks"}}`),
		Stdout: &out,
		Stderr: &errb,
		Env:    func(string) string { return "" },
		Stat:   func(string) bool { return false },
		Rules:  mcpRules(),
	})
	if code != 0 || out.String() != "" {
		t.Errorf("silent: code=%d out=%q", code, out.String())
	}
}

// Edge: masks inside nested arrays (lists of comments/attachments) must be
// restored as well as plain string fields.
func TestMCPRestoresInsideNestedArrays(t *testing.T) {
	var out, errb strings.Builder
	code := Run(Config{
		Stdin:  strings.NewReader(`{"hook_event_name":"PreToolUse","tool_name":"mcp__atlassian__jira_add_comment","tool_input":{"comments":["plain","see https://api.masked/x"],"meta":{"tags":["https://git.masked/r"]}}}`),
		Stdout: &out,
		Stderr: &errb,
		Env:    func(string) string { return "" },
		Stat:   func(string) bool { return false },
		Rules:  mcpRules(),
	})
	if code != 0 || strings.Count(out.String(), "old.tld") != 2 || strings.Contains(out.String(), "masked") || strings.Contains(out.String(), "old.tld") == false || strings.Contains(out.String(), "masked") {
		t.Errorf("nested arrays: code=%d out=%q", code, out.String())
	}
}

// Edge: tool_input.command that is not a string must be ignored silently.
func TestPreToolUseNonStringCommandSilent(t *testing.T) {
	var out, errb strings.Builder
	code := Run(Config{
		Stdin:  strings.NewReader(`{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":{"evil":"object"}}}`),
		Stdout: &out,
		Stderr: &errb,
		Env:    func(string) string { return "" },
		Stat:   func(string) bool { return false },
		Rules:  mcpRules(),
	})
	if code != 0 || out.String() != "" {
		t.Errorf("non-string command: code=%d out=%q", code, out.String())
	}
}

// Edge: stdin without hook_event_name must be silently ignored.
func TestUnknownEventSilent(t *testing.T) {
	var out, errb strings.Builder
	code := Run(Config{
		Stdin:  strings.NewReader(`{"tool_name":"Bash","tool_input":{"command":"x"}}`),
		Stdout: &out,
		Stderr: &errb,
		Env:    func(string) string { return "" },
		Stat:   func(string) bool { return false },
		Rules:  mcpRules(),
	})
	if code != 0 || out.String() != "" {
		t.Errorf("no event: code=%d out=%q", code, out.String())
	}
}

// Edge: empty stdin is a malformed hook call — fail-closed.
func TestEmptyStdinBlocking(t *testing.T) {
	var out, errb strings.Builder
	code := Run(Config{Stdin: strings.NewReader(""), Stdout: &out, Stderr: &errb,
		Env: func(string) string { return "" }, Stat: func(string) bool { return false }})
	if code != 2 {
		t.Errorf("empty stdin: code=%d", code)
	}
}

// Edge: an invalid user regex in values.go panics the hook process — the Go
// runtime exits with 2, so Claude Code blocks the call (fail-closed).
func TestInvalidRegexPanics(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Errorf("invalid regex must panic (runtime exit 2 = fail-closed)")
		}
	}()
	Run(Config{
		Stdin:  strings.NewReader(`{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stdout":"x"}}`),
		Stdout: &strings.Builder{},
		Stderr: &strings.Builder{},
		Env:    func(string) string { return "" },
		Stat:   func(string) bool { return false },
		Rules:  []redact.RuleData{{Name: "bad", Match: "("}},
	})
}
