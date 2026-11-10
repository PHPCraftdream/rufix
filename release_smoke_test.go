package main

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestReleaseBinarySmoke(t *testing.T) {
	name := os.Getenv("RUFIX_RELEASE_BINARY")
	if name == "" {
		t.Skip("release binary is supplied by CI")
	}
	binary, err := filepath.Abs(name)
	if err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(binary)
	if err != nil {
		t.Fatal(err)
	}
	const sizeBudget = 4 * 1024 * 1024
	if info.Size() <= 0 || info.Size() > sizeBudget {
		t.Fatalf("release size %d bytes exceeds budget %d or is empty", info.Size(), sizeBudget)
	}
	t.Logf("release binary: %d bytes; budget: %d bytes", info.Size(), sizeBudget)
	for _, tc := range []struct {
		name  string
		args  []string
		input string
		code  int
		out   string
	}{
		{"version", []string{"version"}, "", 0, version + "\n"},
		{"neutral hook JSON", []string{"hook"}, `{"hook_event_name":"PostToolUse","tool_name":"Read","tool_response":{"text":"neutral fixture","nested":[true,null,12345678901234567890]}}`, 0, ""},
		{"invalid hook JSON", []string{"hook"}, "{", 2, ""},
		{"invalid hook flags", []string{"hook", "--unknown"}, "{}", 2, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, binary, tc.args...)
			cmd.Stdin = strings.NewReader(tc.input)
			var stdout, stderr bytes.Buffer
			cmd.Stdout, cmd.Stderr = &stdout, &stderr
			start := time.Now()
			err := cmd.Run()
			elapsed := time.Since(start)
			code := 0
			if err != nil {
				if exit, ok := err.(*exec.ExitError); ok {
					code = exit.ExitCode()
				} else {
					t.Fatalf("launch release binary: %v", err)
				}
			}
			if code != tc.code || stdout.String() != tc.out || (stderr.Len() != 0) != (tc.code != 0) {
				t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
			}
			t.Logf("process wall time (startup + command + I/O, not a benchmark): %s", elapsed)
		})
	}
}
