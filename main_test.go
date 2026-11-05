package main

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestSettingsPathFlags(t *testing.T) {
	if got := settingsPath([]string{"--path", "/tmp/x.json"}); got != "/tmp/x.json" {
		t.Errorf("--path: %q", got)
	}
	cwd, _ := os.Getwd()
	want := filepath.Join(cwd, ".claude", "settings.json")
	if got := settingsPath([]string{"--project"}); got != want {
		t.Errorf("--project: %q", got)
	}
	home, _ := os.UserHomeDir()
	if got := settingsPath(nil); got != filepath.Join(home, ".claude", "settings.json") {
		t.Errorf("default: %q", got)
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
	if err := runCheck([]string{"--path", settings}, &out); err != nil {
		t.Fatalf("check: %v", err)
	}
	got := out.String()
	if !strings.Contains(got, "not installed") || !strings.Contains(got, "protected values: 3") || !strings.Contains(got, "compiled values: 0") {
		t.Errorf("check output: %q", got)
	}
	if strings.Contains(got, "rufix_test_code_secret_number_001") {
		t.Errorf("check must never print real values: %q", got)
	}
	if !strings.Contains(got, "demo:") {
		t.Errorf("check must show the demo line (replacement count follows the local filter set): %q", got)
	}
}

func TestCheckMissingSecrets(t *testing.T) {
	t.Setenv("RUFIX_ENV_FILE", "")
	t.Setenv("RUFIX_SECRETS_DIR", "")
	t.Chdir(t.TempDir()) // walk-up must not see an unrelated .atlassian.env
	var out bytes.Buffer
	if err := runCheck([]string{"--project"}, &out); err != nil {
		t.Fatalf("check: %v", err)
	}
	if !strings.Contains(out.String(), "NOT FOUND") {
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
