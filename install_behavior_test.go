package main

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"runtime"
	"testing"
	"time"
)

func TestWindowsInstallerBehavior(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("requires Windows PowerShell")
	}
	installer, err := os.ReadFile("install.ps1")
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name, initial, failure string
		project                bool
		code                   int
		calls                  int
	}{
		{"unset environment", "", "", false, 0, 4},
		{"enabled environment", "1", "", false, 0, 4},
		{"disabled environment", "0", "", false, 0, 4},
		{"project scope", "1", "", true, 0, 4},
		{"generation failure", "1", "generate", false, 17, 1},
		{"generation failure with unset environment", "", "generate", false, 17, 1},
		{"build failure", "1", "build", false, 18, 2},
		{"hook install failure", "1", "hooks", false, 19, 3},
		{"check failure", "1", "check", false, 20, 4},
		{"generation exception", "1", "throw", false, 99, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			for name, data := range map[string][]byte{
				"install.ps1": installer,
				"runner.ps1":  []byte(installerBehaviorRunner),
			} {
				if err := os.WriteFile(filepath.Join(dir, name), data, 0o600); err != nil {
					t.Fatal(err)
				}
			}
			t.Setenv("RUFIX_TEST_INITIAL_CGO", tc.initial)
			t.Setenv("RUFIX_TEST_FAILURE", tc.failure)
			project := "0"
			if tc.project {
				project = "1"
			}
			t.Setenv("RUFIX_TEST_PROJECT", project)
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, "powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", filepath.Join(dir, "runner.ps1"))
			output, err := cmd.CombinedOutput()
			if err != nil {
				t.Fatalf("isolated installer runner: %v: %s", err, output)
			}
			var result struct {
				Code  int
				CGO   string
				Calls []struct {
					Tool string
					Args []string
					CGO  string
					Cwd  string
				}
			}
			if err := json.Unmarshal(output, &result); err != nil {
				t.Fatalf("runner output: %v: %s", err, output)
			}
			if result.Code != tc.code || result.CGO != tc.initial || len(result.Calls) != tc.calls {
				t.Fatalf("unexpected result: %+v", result)
			}
			flags := []string{}
			if tc.project {
				flags = append(flags, "--project")
			}
			wantArgs := [][]string{
				{"generate", "./internal/secretvalues"},
				{"install", "-trimpath", "-ldflags", "-s -w -buildid=", "."},
				append([]string{"install"}, flags...),
				append([]string{"check"}, flags...),
			}
			for i, call := range result.Calls {
				tool, cgo := "go", "0"
				if i >= 2 {
					tool, cgo = "rufix", tc.initial
				}
				if call.Tool != tool || call.CGO != cgo || !reflect.DeepEqual(call.Args, wantArgs[i]) || !sameInstallerDirectory(call.Cwd, dir) {
					t.Fatalf("unexpected call %d: %+v", i, call)
				}
			}
		})
	}
}

func sameInstallerDirectory(a, b string) bool {
	aInfo, aErr := os.Stat(a)
	bInfo, bErr := os.Stat(b)
	return aErr == nil && bErr == nil && os.SameFile(aInfo, bInfo)
}

const installerBehaviorRunner = `
$ErrorActionPreference = 'Stop'
$global:calls = [System.Collections.Generic.List[object]]::new()
$env:CGO_ENABLED = $env:RUFIX_TEST_INITIAL_CGO
$initialLocation = Get-Location
function global:go {
  $global:calls.Add([pscustomobject]@{Tool='go'; Args=@($args); CGO=[string]$env:CGO_ENABLED; Cwd=(Get-Location).Path})
  $global:LASTEXITCODE = 0
  if ($args[0] -eq 'generate') {
    if ($env:RUFIX_TEST_FAILURE -eq 'throw') { throw 'synthetic generator error' }
    if ($env:RUFIX_TEST_FAILURE -eq 'generate') { $global:LASTEXITCODE = 17 }
  } elseif ($args[0] -eq 'install' -and $env:RUFIX_TEST_FAILURE -eq 'build') {
    $global:LASTEXITCODE = 18
  }
}
function global:rufix {
  $global:calls.Add([pscustomobject]@{Tool='rufix'; Args=@($args); CGO=[string]$env:CGO_ENABLED; Cwd=(Get-Location).Path})
  $global:LASTEXITCODE = 0
  if ($args[0] -eq 'install' -and $env:RUFIX_TEST_FAILURE -eq 'hooks') { $global:LASTEXITCODE = 19 }
  if ($args[0] -eq 'check' -and $env:RUFIX_TEST_FAILURE -eq 'check') { $global:LASTEXITCODE = 20 }
}
$code = 0
try {
  $global:LASTEXITCODE = 0
  if ($env:RUFIX_TEST_PROJECT -eq '1') {
    & (Join-Path $PSScriptRoot 'install.ps1') -Project
  } else {
    & (Join-Path $PSScriptRoot 'install.ps1')
  }
  $code = $LASTEXITCODE
} catch {
  $code = 99
} finally {
  Set-Location $initialLocation
}
[pscustomobject]@{Code=$code; CGO=[string]$env:CGO_ENABLED; Calls=@($global:calls.ToArray())} | ConvertTo-Json -Depth 8 -Compress
`
