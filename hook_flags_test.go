package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestHookRejectsInvalidFlags(t *testing.T) {
	for _, args := range [][]string{{"--unknown"}, {"--env-files=invalid"}, {"extra"}} {
		var out, errOut bytes.Buffer
		code := runHook(args, strings.NewReader(`{}`), &out, &errOut)
		if code != 2 || out.Len() != 0 {
			t.Errorf("args=%q code=%d output bytes=%d", args, code, out.Len())
		}
	}
}

func TestCheckIgnoresEnvFilesByDefault(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "values.env")
	if err := os.WriteFile(path, []byte("TOKEN=rufix_test_code_secret_number_007\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("RUFIX_ENV_FILE", path)
	t.Setenv("RUFIX_SECRETS_DIR", dir)
	for _, enabled := range []bool{false, true} {
		args := []string{"--path", filepath.Join(dir, "settings.json")}
		if enabled {
			args = append(args, "--env-files")
		}
		var out bytes.Buffer
		if err := runCheck(args, &out); err != nil {
			t.Fatal(err)
		}
		if strings.Contains(out.String(), "compiled + env files") != enabled {
			t.Errorf("enabled=%v source mismatch", enabled)
		}
		if strings.Contains(out.String(), "rufix_test_code_secret_number_007") {
			t.Error("diagnostics leaked an external value")
		}
	}
}

func TestInstallPersistsEnvFilesFlag(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	var out bytes.Buffer
	if err := runSettings("install", []string{"--env-files", "--path", path}, &out); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Count(string(data), "--env-files") != 2 {
		t.Error("both installed hook commands must enable env files")
	}
}
