// Package envfile parses KEY=VALUE secret files and resolves where they live.
package envfile

import (
	"os"
	"path/filepath"
	"strings"
)

// Parse reads KEY=VALUE lines. Supported: blank lines, "#" comments, an
// optional "export " prefix, single/double quotes, inline "# ..." trailing
// comments on unquoted values. The first occurrence of a key wins.
func Parse(data string) map[string]string {
	vars := make(map[string]string)
	for _, line := range strings.Split(data, "\n") {
		line = strings.TrimSpace(strings.TrimSuffix(line, "\r"))
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		line = strings.TrimPrefix(line, "export ")
		key, value, found := strings.Cut(line, "=")
		if !found {
			continue
		}
		key = strings.TrimSpace(key)
		value = unquote(stripInlineComment(strings.TrimSpace(value)))
		if key == "" {
			continue
		}
		if _, dup := vars[key]; !dup {
			vars[key] = value
		}
	}
	return vars
}

func stripInlineComment(value string) string {
	if strings.HasPrefix(value, `"`) || strings.HasPrefix(value, "'") {
		return value
	}
	if i := strings.Index(value, " #"); i >= 0 {
		return strings.TrimRight(value[:i], " \t")
	}
	return value
}

func unquote(value string) string {
	for _, q := range []string{`"`, `'`} {
		if len(value) >= 2 && strings.HasPrefix(value, q) && strings.HasSuffix(value, q) {
			return value[1 : len(value)-1]
		}
	}
	return value
}

// Load reads path as a single env file or, if it is a directory, as every
// *.env file inside it (including dotfiles like .atlassian.env), merged with
// earlier-wins semantics.
func Load(path string) (map[string]string, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	if !info.IsDir() {
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		return Parse(string(data)), nil
	}
	return LoadDir(path)
}

// LoadDir reads every *.env file in dir (sorted by name) and merges them;
// earlier files win on duplicate keys. A missing dir yields an empty map.
func LoadDir(dir string) (map[string]string, error) {
	vars := make(map[string]string)
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return vars, nil
		}
		return nil, err
	}
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".env") {
			continue
		}
		data, err := os.ReadFile(filepath.Join(dir, entry.Name()))
		if err != nil {
			return nil, err
		}
		for key, value := range Parse(string(data)) {
			if _, dup := vars[key]; !dup {
				vars[key] = value
			}
		}
	}
	return vars, nil
}

// Env is the subset of environment lookup used by Resolve (injectable for tests).
type Env func(key string) string

// Stat reports whether a path exists (injectable for tests).
type Stat func(path string) bool

// Resolve finds the secrets source in priority order:
// $RUFIX_ENV_FILE (single file) → $RUFIX_SECRETS_DIR (dir) →
// ".atlassian.env" walking up from startDir → exeDir/secrets →
// homeDir/.config/rufix/secrets. Returns a dir path and whether it exists.
func Resolve(startDir, exeDir, homeDir string, env Env, stat Stat) string {
	if p := env("RUFIX_ENV_FILE"); p != "" {
		if stat(p) {
			return p
		}
		if d := filepath.Dir(p); stat(d) {
			return d
		}
	}
	if d := env("RUFIX_SECRETS_DIR"); d != "" && stat(d) {
		return d
	}
	dir := startDir
	for {
		if stat(filepath.Join(dir, ".atlassian.env")) {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	if exeDir != "" && stat(filepath.Join(exeDir, "secrets")) {
		return filepath.Join(exeDir, "secrets")
	}
	fallback := filepath.Join(homeDir, ".config", "rufix", "secrets")
	if stat(fallback) {
		return fallback
	}
	return ""
}
