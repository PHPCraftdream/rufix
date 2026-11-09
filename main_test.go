package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"rufix/internal/redact"
	"rufix/internal/secretvalues"
)

func TestSettingsPathFlags(t *testing.T) {
	cwd, _ := os.Getwd()
	home, _ := os.UserHomeDir()
	cases := []struct {
		name     string
		args     []string
		path     string
		envFiles bool
	}{
		{"path", []string{"--path", filepath.Join(cwd, "x.json")}, filepath.Join(cwd, "x.json"), false},
		{"project", []string{"--project"}, filepath.Join(cwd, ".claude", "settings.json"), false},
		{"default", nil, filepath.Join(home, ".claude", "settings.json"), false},
		{"env files", []string{"--env-files", "--project"}, filepath.Join(cwd, ".claude", "settings.json"), true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := parseSettings(tc.args)
			if err != nil || got.Path != tc.path || got.EnvFiles != tc.envFiles {
				t.Errorf("settings: path=%q envFiles=%v err=%v", got.Path, got.EnvFiles, err)
			}
		})
	}
}

func TestInstallStatusUninstallViaCLI(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	var out bytes.Buffer

	if err := runSettings("install", []string{"--path", path}, &out); err != nil {
		t.Fatalf("install: %v", err)
	}
	if !strings.Contains(out.String(), "rufix install: installed") || !strings.Contains(out.String(), "resolves automatically") {
		t.Errorf("install output: %q", out.String())
	}
	data, err := os.ReadFile(path)
	if err != nil || !strings.Contains(string(data), "rufix") || !strings.Contains(string(data), "hook") {
		t.Fatalf("settings not written: %v: %s", err, data)
	}

	out.Reset()
	if err := runSettings("status", []string{"--path", path}, &out); err != nil {
		t.Fatalf("status: %v", err)
	}
	if !strings.Contains(out.String(), "installed: PostToolUse, PreToolUse") {
		t.Errorf("status output: %q", out.String())
	}

	out.Reset()
	if err := runSettings("install", []string{"--path", path}, &out); err != nil {
		t.Fatalf("reinstall: %v", err)
	}
	if !strings.Contains(out.String(), "reinstalled 2") {
		t.Errorf("reinstall output: %q", out.String())
	}
	data2, _ := os.ReadFile(path)
	var parsed2 struct {
		Hooks map[string][]json.RawMessage `json:"hooks"`
	}
	if err := json.Unmarshal(data2, &parsed2); err != nil {
		t.Fatal(err)
	}
	if len(parsed2.Hooks["PostToolUse"]) != 1 || len(parsed2.Hooks["PreToolUse"]) != 1 {
		t.Errorf("reinstall must keep exactly one entry per event: %s", data2)
	}

	out.Reset()
	if err := runSettings("uninstall", []string{"--path", path}, &out); err != nil {
		t.Fatalf("uninstall: %v", err)
	}
	if !strings.Contains(out.String(), "removed") {
		t.Errorf("uninstall output: %q", out.String())
	}
	data, _ = os.ReadFile(path)
	if strings.Contains(string(data), "rufix") {
		t.Errorf("settings must not mention rufix after uninstall: %s", data)
	}

	out.Reset()
	if err := runSettings("uninstall", []string{"--path", path}, &out); err != nil {
		t.Fatalf("uninstall again: %v", err)
	}
	if !strings.Contains(out.String(), "no rufix entries") && !strings.Contains(out.String(), "no hooks section") {
		t.Errorf("second uninstall output: %q", out.String())
	}
}

func TestCheckCommandOutput(t *testing.T) {
	envPath := filepath.Join(t.TempDir(), "secrets.env")
	content := "JIRA_TOKEN=rufix_test_code_secret_number_001\nJIRA_URL=https://jira.internal.example\n"
	if err := os.WriteFile(envPath, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("RUFIX_ENV_FILE", envPath)

	settings := filepath.Join(t.TempDir(), "settings.json")
	var out bytes.Buffer
	if err := runCheck([]string{"--path", settings, "--env-files"}, &out); err != nil {
		t.Fatalf("check: %v", err)
	}
	vars := map[string]string{"JIRA_TOKEN": "rufix_test_code_secret_number_001", "JIRA_URL": "https://jira.internal.example"}
	secretvalues.Overlay(vars)
	exact, _, _ := redact.NewWithRules(vars, secretvalues.Rules()).Stats()
	got := out.String()
	if !strings.Contains(got, "not installed") || !strings.Contains(got, fmt.Sprintf("protected values: %d,", exact)) || !strings.Contains(got, "compiled + env files") {
		t.Errorf("check output: %q", got)
	}
	if strings.Contains(got, "rufix_test_code_secret_number_001") {
		t.Errorf("check must never print real values: %q", got)
	}
	if !strings.Contains(got, "demo:") {
		t.Errorf("check must show the demo line (replacement count follows the local filter set): %q", got)
	}
}

func TestCheckCompiledValuesWithoutEnvFiles(t *testing.T) {
	t.Setenv("RUFIX_ENV_FILE", "")
	t.Setenv("RUFIX_SECRETS_DIR", "")
	t.Chdir(t.TempDir()) // walk-up must not see an unrelated .atlassian.env
	var out bytes.Buffer
	if err := runCheck([]string{"--project"}, &out); err != nil {
		t.Fatalf("check: %v", err)
	}
	if !strings.Contains(out.String(), "secrets: compiled (") || !strings.Contains(out.String(), "demo:") || strings.Contains(out.String(), "not found;") {
		t.Errorf("check output: %q", out.String())
	}
}

// TestInstallShSyntax guards install.sh against syntax errors without running it.
func TestInstallShSyntax(t *testing.T) {
	sh, err := exec.LookPath("sh")
	if err != nil {
		t.Skip("sh not available")
	}
	cmd := exec.Command(sh, "-n", "install.sh")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Errorf("install.sh syntax: %v: %s", err, out)
	}
}

// TestInstallPs1Syntax guards install.ps1 against syntax errors (Windows only).
func TestInstallPs1Syntax(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("powershell only on windows")
	}
	script := `[void][scriptblock]::Create((Get-Content -Raw 'install.ps1'))`
	cmd := exec.Command("powershell", "-NoProfile", "-NonInteractive", "-Command", script)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Errorf("install.ps1 syntax: %v: %s", err, out)
	}
}
