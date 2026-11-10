# rufix: генерация regex, сборка, глобальная установка и подключение хуков.
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

$previousCGOEnabled = $env:CGO_ENABLED
try {
  $env:CGO_ENABLED = "0"
  go generate ./internal/secretvalues
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  go install -trimpath -ldflags "-s -w -buildid=" .
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
  $env:CGO_ENABLED = $previousCGOEnabled
}
if (Get-Command rufix -ErrorAction SilentlyContinue) {
  rufix install @flags
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  rufix check @flags
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} else {
  Write-Error "rufix was built into $(go env GOPATH)\bin but is not on PATH; add it and run: rufix install"
}
