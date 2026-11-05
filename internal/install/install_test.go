package install

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func settingsPath(t *testing.T, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "settings.json")
	if content != "" {
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return path
}

func opts(path string) Options { return Options{Path: path, ExeDir: "/tools"} }

func TestInstallIntoFreshFile(t *testing.T) {
	path := settingsPath(t, "")
	summary, err := Install(opts(path))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(summary, "installed") {
		t.Errorf("summary=%q", summary)
	}
	data, _ := os.ReadFile(path)
	var parsed struct {
		Hooks map[string][]struct {
			Matcher string `json:"matcher"`
			Hooks   []struct {
				Type      string `json:"type"`
				Command   string `json:"command"`
				Timeout   int    `json:"timeout"`
				OnFailure string `json:"onFailure"`
			} `json:"hooks"`
		} `json:"hooks"`
	}
	if err := json.Unmarshal(data, &parsed); err != nil {
		t.Fatalf("invalid settings: %v", err)
	}
	post := parsed.Hooks["PostToolUse"]
	if len(post) != 1 || post[0].Matcher != "" || len(post[0].Hooks) != 1 {
		t.Fatalf("PostToolUse = %+v", post)
	}
	h := post[0].Hooks[0]
	if h.Command != `"/tools/rufix" hook` || h.OnFailure != "block" || h.Timeout != 30 {
		t.Errorf("hook = %+v", h)
	}
	pre := parsed.Hooks["PreToolUse"]
	if len(pre) != 1 || pre[0].Matcher != "Bash" || pre[0].Hooks[0].Timeout != 10 {
		t.Errorf("PreToolUse = %+v", pre)
	}
}

func TestInstallPreservesExistingHooks(t *testing.T) {
	existing := `{
	  "model": "opus",
	  "hooks": {
	    "PostToolUse": [
	      {"matcher": "", "hooks": [{"type": "command", "command": "node \"C:/x/cah-stamp.js\""}]}
	    ]
	  }
	}`
	path := settingsPath(t, existing)
	if _, err := Install(opts(path)); err != nil {
		t.Fatal(err)
	}
	// Reinstall: foreign hooks survive, the fresh rufix entry replaces the old one.
	if _, err := Install(opts(path)); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(path)
	var parsed map[string]any
	if err := json.Unmarshal(data, &parsed); err != nil {
		t.Fatal(err)
	}
	if parsed["model"] != "opus" {
		t.Errorf("model lost: %v", parsed["model"])
	}
	hooks := parsed["hooks"].(map[string]any)
	post := hooks["PostToolUse"].([]any)
	if len(post) != 2 {
		t.Errorf("foreign hook must survive reinstall: %v", post)
	}
	first, _ := post[0].(map[string]any)
	inner, _ := first["hooks"].([]any)
	h0, _ := inner[0].(map[string]any)
	if cmd, _ := h0["command"].(string); !strings.Contains(cmd, "cah-stamp") {
		t.Errorf("foreign hook must be the first untouched entry: %+v", h0)
	}
}

func TestInstallReinstallsStaleEntries(t *testing.T) {
	stale := `{"hooks":{"PostToolUse":[{"matcher":"","hooks":[{"type":"command","command":"\"C:/old/place/rufix\" hook","timeout":5}]}],"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"\"C:/old/place/rufix\" hook","timeout":5}]}]}}`
	path := settingsPath(t, stale)
	summary, err := Install(opts(path))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(summary, "reinstalled 2") {
		t.Errorf("summary=%q", summary)
	}
	data, _ := os.ReadFile(path)
	var parsed struct {
		Hooks map[string][]struct {
			Matcher string `json:"matcher"`
			Hooks   []struct {
				Command string `json:"command"`
				Timeout int    `json:"timeout"`
			} `json:"hooks"`
		} `json:"hooks"`
	}
	if err := json.Unmarshal(data, &parsed); err != nil {
		t.Fatal(err)
	}
	if got := parsed.Hooks["PostToolUse"]; len(got) != 1 || got[0].Hooks[0].Command != `"/tools/rufix" hook` || got[0].Hooks[0].Timeout != 30 {
		t.Errorf("stale entry must be replaced with the fresh one: %+v", got)
	}
	if got := parsed.Hooks["PreToolUse"]; len(got) != 1 || got[0].Hooks[0].Timeout != 10 {
		t.Errorf("PreToolUse = %+v", got)
	}
}

func TestInstallReinstallKeepsSingleEntry(t *testing.T) {
	path := settingsPath(t, "")
	if _, err := Install(opts(path)); err != nil {
		t.Fatal(err)
	}
	summary, err := Install(opts(path))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(summary, "reinstalled 2") {
		t.Errorf("summary=%q", summary)
	}
	data, _ := os.ReadFile(path)
	var parsed map[string]any
	if err := json.Unmarshal(data, &parsed); err != nil {
		t.Fatal(err)
	}
	post := parsed["hooks"].(map[string]any)["PostToolUse"].([]any)
	if len(post) != 1 {
		t.Errorf("duplicate entry: %v", post)
	}
}

func TestUninstallRemovesOnlyRufixEntries(t *testing.T) {
	existing := `{"hooks":{"PostToolUse":[{"matcher":"","hooks":[{"type":"command","command":"node stamp.js"}]},{"matcher":"","hooks":[{"type":"command","command":"\"/tools/rufix\" hook"}]}]}}`
	path := settingsPath(t, existing)
	summary, err := Uninstall(opts(path))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(summary, "removed") {
		t.Errorf("summary=%q", summary)
	}
	data, _ := os.ReadFile(path)
	var parsed map[string]any
	if err := json.Unmarshal(data, &parsed); err != nil {
		t.Fatal(err)
	}
	post := parsed["hooks"].(map[string]any)["PostToolUse"].([]any)
	if len(post) != 1 {
		t.Errorf("only the rufix entry must go: %v", post)
	}
}

func TestUninstallWithoutEntries(t *testing.T) {
	path := settingsPath(t, `{"hooks":{}}`)
	summary, err := Uninstall(opts(path))
	if err != nil || !strings.Contains(summary, "no rufix entries") {
		t.Errorf("summary=%q err=%v", summary, err)
	}
}

func TestStatus(t *testing.T) {
	path := settingsPath(t, "")
	status, err := Status(opts(path))
	if err != nil || !strings.Contains(status, "not installed") {
		t.Errorf("status=%q err=%v", status, err)
	}
	if _, err := Install(opts(path)); err != nil {
		t.Fatal(err)
	}
	status, err = Status(opts(path))
	if err != nil || !strings.Contains(status, "PostToolUse") || !strings.Contains(status, "PreToolUse") {
		t.Errorf("status=%q err=%v", status, err)
	}
}
