// Package install merges rufix hook entries into a Claude Code settings.json,
// preserving every existing setting and hook.
package install

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Options locates the settings file and the rufix executable.
type Options struct {
	Path     string // settings.json path
	ExeDir   string // dir of the rufix executable; empty → executable is on PATH
	EnvFiles bool
}

const marker = "rufix" // uninstall/idempotency marker inside the hook command

// Entry describes one hook event entry this tool manages.
type Entry struct {
	Event   string // "PostToolUse" / "PreToolUse"
	Matcher string // regex over tool name; "" matches all
	Timeout int    // seconds
}

func defaultEntries() []Entry {
	return []Entry{
		{Event: "PostToolUse", Matcher: "", Timeout: 30},
		{Event: "PreToolUse", Matcher: "Bash", Timeout: 10},
	}
}

func command(opts Options) string {
	cmd := "rufix hook"
	if opts.ExeDir != "" {
		cmd = fmt.Sprintf("%q hook", filepath.ToSlash(filepath.Join(opts.ExeDir, "rufix")))
	}
	if opts.EnvFiles {
		cmd += " --env-files"
	}
	return cmd
}

// Install fully reinstalls rufix hook entries: every existing rufix entry is
// removed and re-added fresh (current executable path, timeouts), so an
// install after a rebuild always yields a clean, up-to-date state. Existing
// foreign hooks are preserved.
func Install(opts Options) (string, error) {
	settings, err := load(opts.Path)
	if err != nil {
		return "", err
	}
	hooks := ensureMap(settings, "hooks")
	replaced := 0
	for _, e := range defaultEntries() {
		list := ensureList(hooks, e.Event)
		kept, removed := withoutRufixEntries(list)
		replaced += removed
		entry := map[string]any{
			"matcher": e.Matcher,
			"hooks": []map[string]any{{
				"type":      "command",
				"command":   command(opts),
				"timeout":   e.Timeout,
				"onFailure": "block",
			}},
		}
		hooks[e.Event] = append(kept, entry)
	}
	if err := save(opts.Path, settings); err != nil {
		return "", err
	}
	if replaced > 0 {
		return fmt.Sprintf("reinstalled %d hook entr(y/ies) in %s", replaced, opts.Path), nil
	}
	return fmt.Sprintf("installed %d hook entr(y/ies) in %s", len(defaultEntries()), opts.Path), nil
}

// withoutRufixEntries splits a matcher-entry list into foreign entries and
// the count of rufix entries removed from it.
func withoutRufixEntries(list []any) ([]any, int) {
	kept := make([]any, 0, len(list))
	removed := 0
	for _, item := range list {
		if rufixEntry(item) {
			removed++
			continue
		}
		kept = append(kept, item)
	}
	return kept, removed
}

// Uninstall removes every rufix hook entry and returns a summary.
func Uninstall(opts Options) (string, error) {
	settings, err := load(opts.Path)
	if err != nil {
		return "", err
	}
	hooks, ok := settings["hooks"].(map[string]any)
	if !ok {
		return "no hooks section", nil
	}
	removed := 0
	for event, v := range hooks {
		list, ok := v.([]any)
		if !ok {
			continue
		}
		kept := make([]any, 0, len(list))
		for _, item := range list {
			if rufixEntry(item) {
				removed++
				continue
			}
			kept = append(kept, item)
		}
		if len(kept) == 0 {
			delete(hooks, event)
		} else {
			hooks[event] = kept
		}
	}
	if len(hooks) == 0 {
		delete(settings, "hooks")
	}
	if removed == 0 {
		return "no rufix entries found", nil
	}
	if err := save(opts.Path, settings); err != nil {
		return "", err
	}
	return fmt.Sprintf("removed %d hook entr(y/ies) from %s", removed, opts.Path), nil
}

// Status reports whether rufix hook entries are present.
func Status(opts Options) (string, error) {
	settings, err := load(opts.Path)
	if err != nil {
		return "", err
	}
	hooks, ok := settings["hooks"].(map[string]any)
	if !ok {
		return "not installed (no hooks section)", nil
	}
	var events []string
	for _, e := range defaultEntries() {
		if list, ok := hooks[e.Event].([]any); ok && hasRufixEntry(list) {
			events = append(events, e.Event)
		}
	}
	if len(events) == 0 {
		return "not installed", nil
	}
	return "installed: " + strings.Join(events, ", "), nil
}

func hasRufixEntry(list []any) bool {
	for _, item := range list {
		if rufixEntry(item) {
			return true
		}
	}
	return false
}

func rufixEntry(item any) bool {
	entry, ok := item.(map[string]any)
	if !ok {
		return false
	}
	inner, ok := entry["hooks"].([]any)
	if !ok {
		return false
	}
	for _, h := range inner {
		if hm, ok := h.(map[string]any); ok {
			if cmd, ok := hm["command"].(string); ok && strings.Contains(strings.ToLower(cmd), marker) {
				return true
			}
		}
	}
	return false
}

func ensureMap(m map[string]any, key string) map[string]any {
	if v, ok := m[key].(map[string]any); ok {
		return v
	}
	fresh := map[string]any{}
	m[key] = fresh
	return fresh
}

func ensureList(m map[string]any, key string) []any {
	if v, ok := m[key].([]any); ok {
		return v
	}
	return []any{}
}

func load(path string) (map[string]any, error) {
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return map[string]any{}, nil
	}
	if err != nil {
		return nil, err
	}
	var settings map[string]any
	dec := json.NewDecoder(strings.NewReader(string(data)))
	dec.UseNumber()
	if err := dec.Decode(&settings); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	if settings == nil {
		settings = map[string]any{}
	}
	return settings, nil
}

func save(path string, settings map[string]any) error {
	b, err := json.MarshalIndent(settings, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp := path + ".rufix-tmp"
	if err := os.WriteFile(tmp, append(b, '\n'), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
