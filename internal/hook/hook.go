// Package hook implements the Claude Code hook contract: redact tool output
// on PostToolUse, restore placeholders in Bash commands on PreToolUse.
package hook

import (
	"encoding/json"
	"fmt"
	"io"
	"strings"

	"rufix/internal/compiledregexp"
	"rufix/internal/envfile"
	"rufix/internal/redact"
	"rufix/internal/secretvalues"
)

// Config carries the injectable environment for Run.
type Config struct {
	Stdin   io.Reader
	Stdout  io.Writer
	Stderr  io.Writer
	Env     func(string) string
	Stat    func(string) bool
	ExeDir  string
	HomeDir string
	LoadEnv bool
	Vars    map[string]string // nil — встроенная карта; заданная карта заменяет её в тестах.
	// nil — готовые программы локальных правил; тесты могут передать свой набор.
	Rules []redact.RuleData
}

type request struct {
	HookEventName string `json:"hook_event_name"`
	ToolName      string `json:"tool_name"`
	ToolInput     any    `json:"tool_input"`
	ToolResponse  any    `json:"tool_response"`
	Cwd           string `json:"cwd"`
}

// Run processes one hook invocation. Returns the process exit code:
// 0 on success (with or without output), 2 on a blocking error — the caller
// (main) exits with it so Claude Code blocks the tool call, fail-closed.
func Run(cfg Config) int {
	var req request
	dec := json.NewDecoder(cfg.Stdin)
	dec.UseNumber()
	if err := dec.Decode(&req); err != nil {
		return blocking(cfg, "parse hook JSON: %v", err)
	}
	store, err := loadStore(req.Cwd, cfg)
	if err != nil {
		return blocking(cfg, "%v", err)
	}
	switch req.HookEventName {
	case "PostToolUse":
		return postToolUse(cfg, req, store)
	case "PreToolUse":
		return preToolUse(cfg, req, store)
	default:
		return 0
	}
}

func loadStore(cwd string, cfg Config) (*redact.Store, error) {
	vars := map[string]string{}
	if cfg.LoadEnv {
		if path := envfile.Resolve(cwd, cfg.ExeDir, cfg.HomeDir, cfg.Env, cfg.Stat); path != "" {
			loaded, err := envfile.Load(path)
			if err != nil {
				return nil, fmt.Errorf("load secrets %s: %w", path, err)
			}
			vars = loaded
		} else {
			fmt.Fprintln(cfg.Stderr, "rufix: secrets file not found; using compiled values with format rules")
		}
	}
	if cfg.Vars == nil {
		secretvalues.Overlay(vars)
	} else {
		for key, value := range cfg.Vars {
			if value != "" {
				vars[key] = value
			}
		}
	}
	if cfg.Rules != nil {
		return redact.NewWithRules(vars, cfg.Rules), nil
	}
	return redact.NewWithCompiledRules(vars, secretvalues.Rules(), compiledregexp.Lookup)
}

func postToolUse(cfg Config, req request, store *redact.Store) int {
	n := 0
	redacted := mapStrings(req.ToolResponse, store.Redact, &n)
	if n == 0 {
		return 0
	}
	field := "updatedToolOutput"
	if strings.HasPrefix(req.ToolName, "mcp__") {
		field = "updatedMCPToolOutput"
	}
	specific := map[string]any{
		"hookEventName": "PostToolUse",
		field:           redacted,
	}
	if err := writeJSON(cfg.Stdout, map[string]any{"hookSpecificOutput": specific}); err != nil {
		return blocking(cfg, "marshal output: %v", err)
	}
	fmt.Fprintf(cfg.Stderr, "rufix: redacted %d occurrence(s) in %s\n", n, req.ToolName)
	return 0
}

// preToolUse restores masks in outbound tool arguments. Bash gets the full
// restore (domain masks + exact placeholders). MCP tools get the domain-only
// restore: their arguments travel to the target server, so a domain mask in
// a comment/link is resolved, but a credential [S:hash] placeholder never is.
func preToolUse(cfg Config, req request, store *redact.Store) int {
	domainOnly := false
	switch {
	case req.ToolName == "Bash":
		command, ok := stringField(req.ToolInput, "command")
		if !ok || !store.HostPlaceholder(command) {
			return 0
		}
	case strings.HasPrefix(req.ToolName, "mcp__"):
		domainOnly = true
	default:
		return 0
	}
	n := 0
	var restored any
	if domainOnly {
		if !mapStringsBool(req.ToolInput, store.HasDomainMask) {
			return 0
		}
		restored = mapStrings(req.ToolInput, store.RestoreDomains, &n)
	} else {
		restored = mapStrings(req.ToolInput, store.Restore, &n)
	}
	if n == 0 {
		return 0
	}
	if err := writeJSON(cfg.Stdout, map[string]any{"hookSpecificOutput": map[string]any{
		"hookEventName": "PreToolUse",
		"updatedInput":  restored,
	}}); err != nil {
		return blocking(cfg, "marshal output: %v", err)
	}
	verb := "restored"
	if domainOnly {
		verb = "restored domain masks in"
	}
	fmt.Fprintf(cfg.Stderr, "rufix: %s %d placeholder(s) in %s\n", verb, n, req.ToolName)
	return 0
}

func stringField(v any, key string) (string, bool) {
	m, ok := v.(map[string]any)
	if !ok {
		return "", false
	}
	s, ok := m[key].(string)
	return s, ok
}

// Декодированный JSON принадлежит вызову: меняем строки без копирования контейнеров.
func mapStrings(v any, f func(string) (string, int), n *int) any {
	switch x := v.(type) {
	case map[string]any:
		for k, vv := range x {
			x[k] = mapStrings(vv, f, n)
		}
		return x
	case []any:
		for i, vv := range x {
			x[i] = mapStrings(vv, f, n)
		}
		return x
	case string:
		s, c := f(x)
		*n += c
		return s
	default:
		return v
	}
}

// mapStringsBool reports whether f matches at least one string in v.
func mapStringsBool(v any, f func(string) bool) bool {
	switch x := v.(type) {
	case map[string]any:
		for _, vv := range x {
			if mapStringsBool(vv, f) {
				return true
			}
		}
		return false
	case []any:
		for _, vv := range x {
			if mapStringsBool(vv, f) {
				return true
			}
		}
		return false
	case string:
		return f(x)
	default:
		return false
	}
}

func writeJSON(w io.Writer, v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	_, err = w.Write(append(b, '\n'))
	return err
}

func blocking(cfg Config, format string, args ...any) int {
	fmt.Fprintf(cfg.Stderr, "rufix: blocking error: "+format+"\n", args...)
	return 2
}
