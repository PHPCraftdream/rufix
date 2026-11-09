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

	"rufix/internal/compiledregexp"
	"rufix/internal/envfile"
	"rufix/internal/hook"
	"rufix/internal/install"
	"rufix/internal/redact"
	"rufix/internal/secretvalues"
)

const version = "rufix 0.1.0"

const usage = `rufix — keep secrets out of the model context

Usage:
  rufix hook [--env-files]   run as a Claude Code hook (dispatches on stdin JSON)
  rufix install [--project] [--env-files]
                            add hooks to ~/.claude/settings.json (default) or
                            ./.claude/settings.json with --project
  rufix uninstall [--project]
  rufix status  [--project]
  rufix check   [--project] [--env-files]
                            secrets stats + fake-pattern demo (never prints real values)
  rufix version

Install order: generate (go generate ./internal/secretvalues), build (go build),
install the binary globally (go install .),
then run ` + "`rufix install`" + ` from the installed binary so settings.json
references the global path. Full uninstall: ` + "`rufix uninstall [--project]`" + `
(hooks) then ` + "`go clean -i .`" + ` from this directory (binary).

Replacements use compiled values.go only by default. --env-files enables
$RUFIX_ENV_FILE, $RUFIX_SECRETS_DIR, .atlassian.env walking up from the hook
cwd, <exe dir>/secrets, then ~/.config/rufix/secrets as fallbacks.
Compiled values override external files. Never distribute a private binary.
`

func main() {
	args := os.Args[1:]
	if len(args) == 0 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(1)
	}
	switch args[0] {
	case "hook":
		os.Exit(runHook(args[1:], os.Stdin, os.Stdout, os.Stderr))
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

func runHook(args []string, in io.Reader, out, errOut io.Writer) int {
	fs := flag.NewFlagSet("hook", flag.ContinueOnError)
	fs.SetOutput(errOut)
	envFiles := fs.Bool("env-files", false, "load external env files")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() != 0 {
		fmt.Fprintln(errOut, "rufix: unexpected hook arguments")
		return 2
	}
	cfg := hook.Config{Stdin: in, Stdout: out, Stderr: errOut, LoadEnv: *envFiles}
	if *envFiles {
		cfg.Env = os.Getenv
		cfg.Stat = statExists
		cfg.ExeDir = exeDir()
		cfg.HomeDir, _ = os.UserHomeDir()
	}
	return hook.Run(cfg)
}

func runSettings(action string, args []string, out io.Writer) error {
	opts, err := parseSettings(args)
	if err != nil {
		return err
	}
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
	opts, err := parseSettings(args)
	if err != nil {
		return err
	}
	status, err := install.Status(opts)
	if err != nil {
		return fmt.Errorf("check settings: %w", err)
	}
	fmt.Fprintf(out, "settings: %s (%s)\n", opts.Path, status)

	vars := make(map[string]string)
	source := "compiled"
	if opts.EnvFiles {
		cwd, _ := os.Getwd()
		home, _ := os.UserHomeDir()
		secrets := envfile.Resolve(cwd, opts.ExeDir, home, os.Getenv, statExists)
		if secrets == "" {
			fmt.Fprintln(out, "env files: not found; using compiled values with format rules")
		} else {
			loaded, err := envfile.Load(secrets)
			if err != nil {
				return fmt.Errorf("check secrets: %w", err)
			}
			vars = loaded
			source = "compiled + env files"
		}
	}
	secretvalues.Overlay(vars)
	st, err := redact.NewWithCompiledRules(vars, secretvalues.Rules(), compiledregexp.Lookup)
	if err != nil {
		return err
	}
	exact, hosts, rules := st.Stats()
	fmt.Fprintf(out, "secrets: %s (variables: %d, protected values: %d, protected hosts: %d, format rules: %d, compiled values: %d)\n",
		source, len(vars), exact, hosts, rules, secretvalues.NonEmpty())

	demo := "Bearer DEMOdemoDEMOdemo12 ATATT3DEMOtokenDEMOtoken12345 query ?token=DEMOdemoDEMOdemo1234"
	redacted, n := st.Redact(demo)
	fmt.Fprintf(out, "demo: %d replacements on fake patterns:\n  in:  %s\n  out: %s\n", n, demo, redacted)
	return nil
}

func parseSettings(args []string) (install.Options, error) {
	fs := flag.NewFlagSet("settings", flag.ContinueOnError)
	project := fs.Bool("project", false, "use ./.claude/settings.json instead of ~/.claude/settings.json")
	path := fs.String("path", "", "explicit settings.json path")
	envFiles := fs.Bool("env-files", false, "load external env files")
	if err := fs.Parse(args); err != nil {
		return install.Options{}, err
	}
	if fs.NArg() != 0 {
		return install.Options{}, fmt.Errorf("unexpected settings arguments")
	}
	if *path == "" {
		if *project {
			cwd, _ := os.Getwd()
			*path = filepath.Join(cwd, ".claude", "settings.json")
		} else {
			home, _ := os.UserHomeDir()
			*path = filepath.Join(home, ".claude", "settings.json")
		}
	}
	return install.Options{Path: *path, ExeDir: exeDir(), EnvFiles: *envFiles}, nil
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
