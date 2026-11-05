package secretvalues

import (
	"bytes"
	"crypto/sha1"
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"testing"
)

// gitBlobHash returns the git blob hash of the file as committed/staged,
// to compare against the working copy.
func gitBlobHash(t *testing.T, path string) string {
	t.Helper()
	out, err := exec.Command("git", "rev-parse", ":"+path).Output()
	if err != nil {
		t.Skipf("git unavailable or path not staged: %v", err)
	}
	return string(bytes.TrimSpace(out))
}

func workingBlobHash(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	// git blob hash: sha1("blob <len>\0<content>")
	h := sha1.New()
	fmt.Fprintf(h, "blob %d\x00", len(data))
	h.Write(data)
	return hex.EncodeToString(h.Sum(nil))
}

// TestSkeletonIsEmpty guards the committed skeleton: if the working copy
// differs from the staged one (local values present), skip — the check only
// applies to the clean skeleton (CI, fresh clones).
func TestSkeletonIsEmpty(t *testing.T) {
	const path = "internal/secretvalues/values.go" // for git, from the repo root
	staged := gitBlobHash(t, path)
	working := workingBlobHash(t, "values.go") // cwd of the test is the package dir
	if staged != working {
		t.Skip("working copy carries local values; skeleton check applies only to the staged file")
	}
	for key, value := range Vars() {
		if value != "" {
			t.Errorf("committed skeleton must have empty %q, got %q", key, value)
		}
	}
	for _, rule := range Rules() {
		if rule.Match != "" {
			t.Errorf("committed skeleton must ship no rules, found %q", rule.Name)
		}
	}
}
