# rufix setup: build, install the binary globally ($GOPATH\bin), wire hooks.
#
# Usage:
#   .\install.ps1              install: build + go install . + rufix install (global settings)
#   .\install.ps1 -Project     same, but hooks into .\.claude\settings.json
#   .\install.ps1 -Revert      uninstall hooks (same scope) and remove the binary
param(
  [switch]$Project,
  [switch]$Revert
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$flags = @()
if ($Project) { $flags += "--project" }

if ($Revert) {
  if (Get-Command rufix -ErrorAction SilentlyContinue) {
    rufix uninstall @flags
  } else {
    Write-Host "rufix binary not found on PATH; skipping hook uninstall"
  }
  go clean -i .
  Write-Host "rufix removed."
  exit 0
}

go build ./...
go install .
if (Get-Command rufix -ErrorAction SilentlyContinue) {
  rufix install @flags
  rufix check @flags
} else {
  Write-Error "rufix was built into $(go env GOPATH)\bin but is not on PATH; add it and run: rufix install"
}
