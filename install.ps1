# rufix setup: build the release binary with Zig, install it, register the hooks.
#
# Usage:
#   .\install.ps1                  build + install the binary + hooks in ~/.claude/settings.json
#   .\install.ps1 -Project         same, but hooks into .\.claude\settings.json
#   .\install.ps1 -EnvFiles        hooks also load external env files (rufix hook --env-files)
#   .\install.ps1 -Project -Shell  also wrap this repository's shell (output of failing commands)
#   .\install.ps1 -Revert          uninstall hooks (same scope) and remove the binaries
#
# The binary goes to $env:RUFIX_BIN_DIR (default %LOCALAPPDATA%\rufix\bin).
# Private values come from secrets\values.zig when it exists.
param(
  [switch]$Project,
  [switch]$EnvFiles,
  [switch]$Shell,
  [switch]$Revert
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$bin = if ($env:RUFIX_BIN_DIR) { $env:RUFIX_BIN_DIR } else { Join-Path $env:LOCALAPPDATA "rufix\bin" }
$target = Join-Path $bin "rufix.exe"

$flags = @()
if ($Project) { $flags += "--project" }

if ($Revert) {
  if (Test-Path $target) {
    & $target uninstall @flags
  } else {
    Write-Host "rufix binary not found at $target; skipping hook uninstall"
  }
  Remove-Item -Force -ErrorAction SilentlyContinue $target, (Join-Path $bin "rufix-shell.exe")
  Write-Host "rufix removed."
  exit 0
}

if ($EnvFiles) { $flags += "--env-files" }

zig build -Doptimize=ReleaseSmall
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
New-Item -ItemType Directory -Force -Path $bin | Out-Null
# A running hook keeps rufix.exe open: move it aside instead of overwriting.
if (Test-Path $target) { Move-Item -Force $target "$target.old" }
Copy-Item "zig-out\bin\rufix.exe" $target
Remove-Item -Force -ErrorAction SilentlyContinue "$target.old"

$installFlags = $flags
if ($Shell) { $installFlags += "--shell" }
& $target install @installFlags
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $target check @flags
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
