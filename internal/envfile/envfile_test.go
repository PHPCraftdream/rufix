package envfile

import (
	"os"
	"path/filepath"
	"testing"
)

func TestParse(t *testing.T) {
	vars := Parse("" +
		"# comment\r\n" +
		"CONFLUENCE_URL=https://host.example  # trailing comment\r\n" +
		"export JIRA_TOKEN=\"abc def\"\n" +
		"CONFLUENCE_TOKEN='sin gle'\n" +
		"\n" +
		"URL_WITH_HASH=https://x.example/a#frag\n" +
		"EMPTY=\n" +
		"no equals sign\n" +
		"=novalue\n")
	if vars["CONFLUENCE_URL"] != "https://host.example" {
		t.Errorf("CONFLUENCE_URL = %q", vars["CONFLUENCE_URL"])
	}
	if vars["JIRA_TOKEN"] != "abc def" || vars["CONFLUENCE_TOKEN"] != "sin gle" {
		t.Errorf("quoted values: %q %q", vars["JIRA_TOKEN"], vars["CONFLUENCE_TOKEN"])
	}
	if vars["URL_WITH_HASH"] != "https://x.example/a#frag" {
		t.Errorf("hash inside quoted-free URL must survive: %q", vars["URL_WITH_HASH"])
	}
	if v, ok := vars["EMPTY"]; !ok || v != "" {
		t.Errorf("EMPTY = %q, ok = %v", v, ok)
	}
}

func TestParseFirstKeyWins(t *testing.T) {
	vars := Parse("A=1\nA=2")
	if vars["A"] != "1" {
		t.Errorf("A = %q", vars["A"])
	}
}

func TestLoadDirMergesSortedFiles(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "b.env"), []byte("K=fromB\nSHARED=second\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, ".atlassian.env"), []byte("SHARED=first\nDOT=yes\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	vars, err := Load(dir)
	if err != nil {
		t.Fatal(err)
	}
	// ".atlassian.env" sorts before "b.env", so its values win.
	if vars["SHARED"] != "first" || vars["DOT"] != "yes" || vars["K"] != "fromB" {
		t.Errorf("merged = %v", vars)
	}
}

func TestLoadSingleFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "one.env")
	if err := os.WriteFile(path, []byte("X=1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	vars, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if vars["X"] != "1" {
		t.Errorf("X = %q", vars["X"])
	}
}

func TestResolveOrder(t *testing.T) {
	envFile := filepath.FromSlash("/root/env-file")
	aifront := filepath.FromSlash("/root/aifront")
	start := filepath.Join(aifront, "sub")
	exe := filepath.FromSlash("/exe")
	home := filepath.FromSlash("/home")
	stat := func(p string) bool {
		switch p {
		case envFile, filepath.Join(aifront, ".atlassian.env"), filepath.Join(exe, "secrets"),
			filepath.Join(home, ".config", "rufix", "secrets"):
			return true
		}
		return false
	}
	env := func(k string) string {
		if k == "RUFIX_ENV_FILE" {
			return envFile
		}
		return ""
	}
	if got := Resolve(start, exe, home, env, stat); got != envFile {
		t.Errorf("env var wins: %q", got)
	}
	if got := Resolve(start, exe, home, func(string) string { return "" }, stat); got != aifront {
		t.Errorf("walk-up .atlassian.env: %q", got)
	}
	if got := Resolve(filepath.FromSlash("/elsewhere"), exe, home, func(string) string { return "" }, stat); got != filepath.Join(exe, "secrets") {
		t.Errorf("exe-dir secrets: %q", got)
	}
	if got := Resolve(filepath.FromSlash("/elsewhere"), filepath.FromSlash("/other"), home, func(string) string { return "" }, stat); got != filepath.Join(home, ".config", "rufix", "secrets") {
		t.Errorf("home fallback: %q", got)
	}
	if got := Resolve(filepath.FromSlash("/elsewhere"), filepath.FromSlash("/other"), filepath.FromSlash("/nohome"), func(string) string { return "" }, func(string) bool { return false }); got != "" {
		t.Errorf("missing everywhere: %q", got)
	}
}
