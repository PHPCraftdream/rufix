package main

import (
	"bytes"
	"os/exec"
	"testing"
)

func TestPrivateGeneratedProgramsAreIgnored(t *testing.T) {
	const path = "internal/compiledregexp/filters_generated.go"
	if err := exec.Command("git", "check-ignore", "--no-index", path).Run(); err != nil {
		t.Fatal("private generated programs must be gitignored")
	}
	tracked, err := exec.Command("git", "ls-files", "--", path).Output()
	if err != nil {
		t.Fatal(err)
	}
	if len(bytes.TrimSpace(tracked)) != 0 {
		t.Fatal("private generated programs must never be tracked")
	}
}
