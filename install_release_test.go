package main

import (
	"os"
	"strings"
	"testing"
)

func TestWindowsInstallerReleaseBuild(t *testing.T) {
	data, err := os.ReadFile("install.ps1")
	if err != nil {
		t.Fatal(err)
	}
	script := string(data)
	steps := []string{
		`$previousCGOEnabled = $env:CGO_ENABLED`,
		`try {`,
		`$env:CGO_ENABLED = "0"`,
		`go generate ./internal/secretvalues`,
		`if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }`,
		`go install -trimpath -ldflags "-s -w -buildid=" .`,
		`if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }`,
		`} finally {`,
		`$env:CGO_ENABLED = $previousCGOEnabled`,
		`rufix install @flags`,
	}
	remaining := script
	for _, step := range steps {
		index := strings.Index(remaining, step)
		if index < 0 {
			t.Fatalf("missing or out-of-order installer step: %s", step)
		}
		remaining = remaining[index+len(step):]
	}
	if strings.Count(script, "go install -trimpath") != 1 {
		t.Fatal("expected exactly one release build/install command")
	}
	for _, forbidden := range []string{"go build ", "upx", "-gcflags", "-race", "-asan", "-msan"} {
		if strings.Contains(strings.ToLower(script), forbidden) {
			t.Fatalf("unexpected installer build option or command: %s", forbidden)
		}
	}
	wrapper, err := os.ReadFile("install.cmd")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(wrapper), `-File "%~dp0install.ps1"`) {
		t.Fatal("cmd wrapper must delegate to the PowerShell installer")
	}
}
