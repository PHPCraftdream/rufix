package hook

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"rufix/internal/redact"
)

func TestEnvFilesRequireOptIn(t *testing.T) {
	path := filepath.Join(t.TempDir(), "values.env")
	const external = "rufix_test_code_secret_number_005"
	if err := os.WriteFile(path, []byte("TOKEN="+external+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, enabled := range []bool{false, true} {
		t.Run(map[bool]string{false: "disabled", true: "enabled"}[enabled], func(t *testing.T) {
			var out, errOut strings.Builder
			lookups := 0
			code := Run(Config{
				Stdin:  strings.NewReader(`{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stdout":"` + external + ` ` + testToken + `"}}`),
				Stdout: &out, Stderr: &errOut, LoadEnv: enabled,
				Env: func(key string) string {
					lookups++
					if key == "RUFIX_ENV_FILE" {
						return path
					}
					return ""
				},
				Stat: func(p string) bool {
					lookups++
					_, err := os.Stat(p)
					return err == nil
				},
				Vars: map[string]string{"COMPILED_TOKEN": testToken}, Rules: []redact.RuleData{},
			})
			if code != 0 || strings.Contains(out.String(), testToken) {
				t.Fatalf("compiled replacement: code=%d", code)
			}
			if strings.Contains(out.String(), external) == enabled {
				t.Error("external replacement does not match opt-in")
			}
			if (lookups > 0) != enabled {
				t.Errorf("external lookups=%d enabled=%v", lookups, enabled)
			}
		})
	}
}

func TestEnvFilesCompiledValuesWin(t *testing.T) {
	path := filepath.Join(t.TempDir(), "values.env")
	const external = "rufix_test_code_secret_number_006"
	if err := os.WriteFile(path, []byte("TOKEN="+external+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	st, err := loadStore("", Config{
		LoadEnv: true, Env: func(string) string { return path },
		Stat: func(string) bool { return true }, Stderr: io.Discard,
		Vars: map[string]string{"TOKEN": testToken}, Rules: []redact.RuleData{},
	})
	if err != nil {
		t.Fatal(err)
	}
	got, n := st.Redact(testToken + " " + external)
	if n != 1 || strings.Contains(got, testToken) || !strings.Contains(got, external) {
		t.Error("compiled values must override external values")
	}
}

func TestEnvFileReadErrorBlocks(t *testing.T) {
	path := filepath.Join(t.TempDir(), "missing.env")
	var out strings.Builder
	code := Run(Config{
		Stdin:  strings.NewReader(`{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":"x"}`),
		Stdout: &out, Stderr: io.Discard, LoadEnv: true,
		Env: func(string) string { return path }, Stat: func(string) bool { return true },
		Vars: map[string]string{}, Rules: []redact.RuleData{},
	})
	if code != 2 || out.Len() != 0 {
		t.Errorf("code=%d output bytes=%d", code, out.Len())
	}
}

type openInput struct {
	data  string
	reads int
}

func (r *openInput) Read(p []byte) (int, error) {
	r.reads++
	if r.data == "" {
		return 0, errors.New("stdin is still open")
	}
	n := copy(p, r.data)
	r.data = r.data[n:]
	return n, nil
}

func TestStdinReadErrorBlocks(t *testing.T) {
	var out strings.Builder
	code := Run(Config{Stdin: &openInput{}, Stdout: &out, Stderr: io.Discard})
	if code != 2 || out.Len() != 0 {
		t.Errorf("code=%d output bytes=%d", code, out.Len())
	}
}

func TestMissingOptionalEnvFilesUseCompiledValues(t *testing.T) {
	var errOut strings.Builder
	st, err := loadStore("", Config{
		LoadEnv: true, Env: func(string) string { return "" },
		Stat: func(string) bool { return false }, Stderr: &errOut,
		Vars: testVars, Rules: []redact.RuleData{},
	})
	if err != nil {
		t.Fatal(err)
	}
	if got, n := st.Redact(testToken); n != 1 || strings.Contains(got, testToken) {
		t.Error("compiled values must remain active without optional files")
	}
	if !strings.Contains(errOut.String(), "secrets file not found") {
		t.Error("missing optional files must produce a warning")
	}
}

func TestHookDoesNotWaitForEOF(t *testing.T) {
	in := &openInput{data: `{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stdout":"` + testToken + `"}}`}
	var out strings.Builder
	code := Run(Config{
		Stdin: in, Stdout: &out, Stderr: io.Discard,
		Vars: testVars, Rules: []redact.RuleData{},
	})
	if code != 0 || in.reads != 1 || !strings.Contains(out.String(), "[S:") {
		t.Errorf("code=%d reads=%d output bytes=%d", code, in.reads, out.Len())
	}
}

func TestNestedJSONShapePreserved(t *testing.T) {
	in := `{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"items":[null,false,12345678901234567890,{"text":"` + testToken + `"}],"empty":[],"object":{},"nil":null}}`
	out, _, code := runHook(t, in, true)
	var got struct {
		HookSpecificOutput struct {
			UpdatedToolOutput json.RawMessage `json:"updatedToolOutput"`
		} `json:"hookSpecificOutput"`
	}
	if code != 0 || json.Unmarshal([]byte(out), &got) != nil {
		t.Fatal("invalid hook output")
	}
	want := `{"empty":[],"items":[null,false,12345678901234567890,{"text":"[S:` + hashOf(testToken) + `]"}],"nil":null,"object":{}}`
	if string(got.HookSpecificOutput.UpdatedToolOutput) != want {
		t.Error("nested JSON structure or number changed")
	}
}
