// rufix keeps secrets and internal hosts out of the model context:
// PostToolUse redacts tool output, PreToolUse restores placeholders in
// Bash commands that target the protected hosts. The hook installer is
// built in: `rufix install` edits Claude Code settings.json.
package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"rufix/internal/envfile"
	"rufix/internal/hook"
	"rufix/internal/install"
	"rufix/internal/redact"
	"rufix/internal/secretvalues"
)

const version = "rufix 0.1.0"

const usage = `rufix — keep secrets out of the model context

Usage:
  rufix hook                 run as a Claude Code hook (dispatches on stdin JSON)
  rufix install [--project]  add hooks to ~/.claude/settings.json (default) or
                             ./.claude/settings.json with --project
  rufix uninstall [--project]
  rufix status  [--project]
  rufix check   [--project]  secrets stats + fake-pattern demo (never prints real values)
  rufix version

Install order: build (go build), install the binary globally (go install .),
then run ` + "`rufix install`" + ` from the installed binary so settings.json
references the global path. Full uninstall: ` + "`rufix uninstall [--project]`" + `
(hooks) then ` + "`go clean -i .`" + ` from this directory (binary).

Secrets source: the compiled values.go first, then $RUFIX_ENV_FILE or
$RUFIX_SECRETS_DIR, then .atlassian.env walking up from the hook cwd, then
<exe dir>/secrets, then ~/.config/rufix/secrets. Only test fixtures are
committed; real replacements live in the skip-worktree file and secrets/.
`

func main() {
	args := os.Args[1:]
	if len(args) == 0 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(1)
	}
	switch args[0] {
	case "hook":
		os.Exit(runHook())
	case "install", "uninstall", "status":
		if err := runSettings(args[0], args[1:], os.Stdout); err != nil {
			fatal(err)
		}
	case "check":
		if err := runCheck(args[1:], os.Stdout); err != nil {
			fatal(err)
		}
	case "version", "--version", "-v":
		fmt.Println(version)
	default:
		fmt.Fprint(os.Stderr, usage)
		os.Exit(1)
	}
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "rufix:", err)
	os.Exit(1)
}

func runHook() int {
	home, _ := os.UserHomeDir()
	return hook.Run(hook.Config{
		Stdin:   os.Stdin,
		Stdout:  os.Stdout,
		Stderr:  os.Stderr,
		Env:     os.Getenv,
		Stat:    statExists,
		ExeDir:  exeDir(),
		HomeDir: home,
	})
}

func runSettings(action string, args []string, out io.Writer) error {
	opts := install.Options{Path: settingsPath(args), ExeDir: exeDir()}
	actionFn, ok := map[string]func(install.Options) (string, error){
		"install":   install.Install,
		"uninstall": install.Uninstall,
		"status":    install.Status,
	}[action]
	if !ok {
		return fmt.Errorf("unknown action %q", action)
	}
	summary, err := actionFn(opts)
	if err != nil {
		return err
	}
	fmt.Fprintf(out, "rufix %s: %s\n", action, summary)
	if action == "install" {
		fmt.Fprintln(out, "rufix note: [S:xxxxxxxx] in tool output is a redacted value; it resolves automatically when a Bash command targets a protected host.")
	}
	return nil
}

func runCheck(args []string, out io.Writer) error {
	path := settingsPath(args)
	status, err := install.Status(install.Options{Path: path, ExeDir: exeDir()})
	if err != nil {
		return fmt.Errorf("check settings: %w", err)
	}
	fmt.Fprintf(out, "settings: %s (%s)\n", path, status)

	cwd, _ := os.Getwd()
	home, _ := os.UserHomeDir()
	secrets := envfile.Resolve(cwd, exeDir(), home, os.Getenv, statExists)
	if secrets == "" {
		fmt.Fprintln(out, "secrets: NOT FOUND — hooks run with format rules only")
		return nil
	}
	vars, err := envfile.Load(secrets)
	if err != nil {
		return fmt.Errorf("check secrets: %w", err)
	}
	secretvalues.Overlay(vars)
	st := redact.NewWithRules(vars, secretvalues.Rules())
	exact, hosts, rules := st.Stats()
	fmt.Fprintf(out, "secrets: %s (variables: %d, protected values: %d, protected hosts: %d, format rules: %d, compiled values: %d)\n",
		secrets, len(vars), exact, hosts, rules, secretvalues.NonEmpty())

	demo := "Bearer DEMOdemoDEMOdemo12 ATATT3DEMOtokenDEMOtoken12345 query ?token=DEMOdemoDEMOdemo1234"
	redacted, n := st.Redact(demo)
	fmt.Fprintf(out, "demo: %d replacements on fake patterns:\n  in:  %s\n  out: %s\n", n, demo, redacted)
	return nil
}

func settingsPath(args []string) string {
	fs := flag.NewFlagSet("settings", flag.ContinueOnError)
	project := fs.Bool("project", false, "use ./.claude/settings.json instead of ~/.claude/settings.json")
	path := fs.String("path", "", "explicit settings.json path")
	_ = fs.Parse(args)
	if *path != "" {
		return *path
	}
	if *project {
		cwd, _ := os.Getwd()
		return filepath.Join(cwd, ".claude", "settings.json")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".claude", "settings.json")
}

func exeDir() string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	return filepath.Dir(exe)
}

func statExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
