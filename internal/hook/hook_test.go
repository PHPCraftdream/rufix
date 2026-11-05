package hook

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"rufix/internal/redact"
)

const (
	testToken = "rufix_test_code_secret_number_001"
	testHost  = "https://jira.internal.example"
)

var testVars = map[string]string{
	"JIRA_TOKEN": testToken,
	"JIRA_URL":   testHost,
}

func runHook(t *testing.T, stdin string, withSecrets bool) (string, string, int) {
	t.Helper()
	env := func(string) string { return "" }
	if withSecrets {
		path := filepath.Join(t.TempDir(), "secrets.env")
		content := "JIRA_TOKEN=" + testToken + "\nJIRA_URL=" + testHost + "\n"
		if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
		env = func(key string) string {
			if key == "RUFIX_ENV_FILE" {
				return path
			}
			return ""
		}
	}
	var out, errb bytes.Buffer
	code := Run(Config{
		Stdin:   strings.NewReader(stdin),
		Stdout:  &out,
		Stderr:  &errb,
		Env:     env,
		Stat:    statExists,
		ExeDir:  "",
		HomeDir: "",
		// Deterministic rule set: tests never depend on the local values.go.
		Rules: []redact.RuleData{
			{Name: "atlassian-pat", Match: `ATATT[A-Za-z0-9_\-=]{18,}`, Replace: "[REDACTED:atlassian-pat]"},
		},
	})
	return out.String(), errb.String(), code
}

func statExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func TestPostToolUseRedactsBashShapeExactly(t *testing.T) {
	in := `{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"cat x"},"tool_response":{"stdout":"Bearer ` + testToken + `","stderr":"ok","interrupted":false,"isImage":false}}`
	out, stderr, code := runHook(t, in, true)
	if code != 0 {
		t.Fatalf("code=%d stderr=%s", code, stderr)
	}
	var resp struct {
		HookSpecificOutput struct {
			HookEventName      string `json:"hookEventName"`
			UpdatedToolOutput  *struct {
				Stdout      string `json:"stdout"`
				Stderr      string `json:"stderr"`
				Interrupted bool   `json:"interrupted"`
				IsImage     bool   `json:"isImage"`
			} `json:"updatedToolOutput"`
		} `json:"hookSpecificOutput"`
	}
	if err := json.Unmarshal([]byte(out), &resp); err != nil {
		t.Fatalf("bad output %q: %v", out, err)
	}
	got := resp.HookSpecificOutput.UpdatedToolOutput
	if got == nil || got.Stdout != "Bearer [S:"+hashOf(testToken)+"]" || got.Stderr != "ok" || got.Interrupted || got.IsImage {
		t.Errorf("shape mismatch: %+v", resp.HookSpecificOutput)
	}
}

func TestPostToolUseMCPUseUpdatedMCPField(t *testing.T) {
	in := `{"hook_event_name":"PostToolUse","tool_name":"mcp__atlassian__jira_get_issue","tool_response":{"text":"see ` + testHost + `/browse/P-1"}}`
	out, _, code := runHook(t, in, true)
	if code != 0 {
		t.Fatalf("code=%d", code)
	}
	if !strings.Contains(out, "updatedMCPToolOutput") || strings.Contains(out, testHost) {
		t.Errorf("out=%q", out)
	}
}

func TestPostToolUseNoChangeNoOutput(t *testing.T) {
	in := `{"hook_event_name":"PostToolUse","tool_name":"Read","tool_response":{"content":"nothing secret here"}}`
	out, _, code := runHook(t, in, true)
	if code != 0 || out != "" {
		t.Errorf("code=%d out=%q", code, out)
	}
}

func TestPostToolUsePreservesNumbers(t *testing.T) {
	in := `{"hook_event_name":"PostToolUse","tool_name":"Read","tool_response":{"n":12345678901234567890,"s":"host ` + testHost + `"}}`
	out, _, _ := runHook(t, in, true)
	if !strings.Contains(out, "12345678901234567890") {
		t.Errorf("number must round-trip exactly: %q", out)
	}
}

func TestPreToolUseRestoresAllowlistedCommand(t *testing.T) {
	st := redact.NewWithRules(testVars, nil)
	cmd := `curl ` + testHost + `/rest -H "Authorization: Bearer ` + testToken + `"`
	redactedCmd, _ := st.Redact(cmd)
	inBytes, _ := json.Marshal(map[string]any{
		"hook_event_name": "PreToolUse",
		"tool_name":       "Bash",
		"tool_input":      map[string]any{"command": redactedCmd},
	})
	out, stderr, code := runHook(t, string(inBytes), true)
	if code != 0 {
		t.Fatalf("code=%d", code)
	}
	if !strings.Contains(out, "updatedInput") || !strings.Contains(out, testHost) || strings.Contains(out, "[S:") {
		t.Errorf("out=%q stderr=%q", out, stderr)
	}
}

func TestPreToolUseSkipsNonAllowlisted(t *testing.T) {
	st := redact.NewWithRules(testVars, nil)
	redactedCmd, _ := st.Redact("echo " + testToken + " > notes.txt")
	inBytes, _ := json.Marshal(map[string]any{
		"hook_event_name": "PreToolUse",
		"tool_name":       "Bash",
		"tool_input":      map[string]any{"command": redactedCmd},
	})
	out, _, code := runHook(t, string(inBytes), true)
	if code != 0 || out != "" {
		t.Errorf("token-only command must stay redacted: code=%d out=%q", code, out)
	}
}

func TestPreToolUseIgnoresOtherTools(t *testing.T) {
	inBytes, _ := json.Marshal(map[string]any{
		"hook_event_name": "PreToolUse",
		"tool_name":       "Write",
		"tool_input":      map[string]any{"file_path": "/x", "content": "[S:abcd1234]"},
	})
	out, _, code := runHook(t, string(inBytes), true)
	if code != 0 || out != "" {
		t.Errorf("code=%d out=%q", code, out)
	}
}

func TestDegradedModeRulesOnly(t *testing.T) {
	in := `{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stdout":"token ATATT3abcdefgHIJKLMNOPQRSTUVWX"}}`
	out, stderr, code := runHook(t, in, false)
	if code != 0 {
		t.Fatalf("code=%d", code)
	}
	if !strings.Contains(out, "[REDACTED:atlassian-pat]") || !strings.Contains(stderr, "compiled values") {
		t.Errorf("out=%q stderr=%q", out, stderr)
	}
}

func TestBlockingErrorOnBadJSON(t *testing.T) {
	_, stderr, code := runHook(t, "{not json", true)
	if code != 2 || !strings.Contains(stderr, "blocking") {
		t.Errorf("code=%d stderr=%q", code, stderr)
	}
}

// hashOf mirrors redact.placeholder hashing without exposing internals.
func hashOf(value string) string {
	st := redact.NewWithRules(map[string]string{"TOKEN": value}, nil)
	out, _ := st.Redact(value)
	return strings.TrimSuffix(strings.TrimPrefix(out, "[S:"), "]")
}
