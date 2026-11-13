# rufix setup: build the release binary with Zig, install it on the PATH,
# register the hooks.
#
# Usage:
#   .\install.ps1                  build + install the binary + hooks in ~/.claude/settings.json
#   .\install.ps1 -Project         same, but hooks into .\.claude\settings.json
#   .\install.ps1 -EnvFiles        hooks also load external env files (rufix hook --env-files)
#   .\install.ps1 -Project -Shell  also wrap this repository's shell (output of failing commands)
#   .\install.ps1 -Project -Mod    also add the mod masking prompts and failed tool output
#   .\install.ps1 -Revert          uninstall hooks (same scope), the binaries and the PATH entry
#
# The binary goes to $env:RUFIX_BIN_DIR (default %LOCALAPPDATA%\rufix\bin),
# which is added to the user's PATH. Private values come from
# secrets\values.zig when it exists.
param(
  [switch]$Project,
  [switch]$EnvFiles,
  [switch]$Shell,
  [switch]$Mod,
  [switch]$Revert
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$bin = if ($env:RUFIX_BIN_DIR) { $env:RUFIX_BIN_DIR } else { Join-Path $env:LOCALAPPDATA "rufix\bin" }
$target = Join-Path $bin "rufix.exe"

# The user's PATH is read and written raw (REG_EXPAND_SZ): going through
# [Environment] would expand entries such as %USERPROFILE%\bin for good.
function Get-RawUserPath {
  $key = Get-Item -Path "HKCU:\Environment"
  return [string]$key.GetValue("Path", "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
}

function Set-RawUserPath([string]$value) {
  Set-ItemProperty -Path "HKCU:\Environment" -Name "Path" -Value $value -Type ExpandString
  # Setting any variable through [Environment] broadcasts the change, so new
  # terminals see the new PATH without a sign-out.
  [Environment]::SetEnvironmentVariable("RUFIX_PATH_REFRESH", "1", "User")
  [Environment]::SetEnvironmentVariable("RUFIX_PATH_REFRESH", $null, "User")
}

# The entries of the user's PATH other than $bin.
function Get-UserPathWithout([string]$dir) {
  return @((Get-RawUserPath).Split(";") | Where-Object { $_ -and ($_.TrimEnd("\") -ne $dir.TrimEnd("\")) })
}

$flags = @()
if ($Project) { $flags += "--project" }

if ($Revert) {
  if (Test-Path $target) {
    & $target uninstall @flags
  } else {
    Write-Host "rufix binary not found at $target; skipping hook uninstall"
  }
  Remove-Item -Force -ErrorAction SilentlyContinue $target, (Join-Path $bin "rufix-shell.exe")
  $others = Get-UserPathWithout $bin
  if ($others.Count -ne @((Get-RawUserPath).Split(";") | Where-Object { $_ }).Count) {
    Set-RawUserPath ($others -join ";")
  }
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

# Make `rufix` available in new terminals: first in the user's PATH, so an
# older copy elsewhere (say a Go build in go\bin) does not answer instead.
$others = @(Get-UserPathWithout $bin)
$entries = @((Get-RawUserPath).Split(";") | Where-Object { $_ })
if ($entries.Count -eq 0 -or $entries[0].TrimEnd("\") -ne $bin.TrimEnd("\")) {
  Set-RawUserPath ((@($bin) + $others) -join ";")
  Write-Host "rufix setup: $bin is first in the user PATH (new terminals pick it up)"
}
$env:Path = (@($bin) + @($env:Path.Split(";") | Where-Object { $_ -and ($_.TrimEnd("\") -ne $bin.TrimEnd("\")) })) -join ";"

# The machine PATH comes before the user's: report any other rufix that wins.
$found = Get-Command rufix -All -CommandType Application -ErrorAction SilentlyContinue |
  Where-Object { $_.Source -ne $target } | Select-Object -ExpandProperty Source
foreach ($other in $found) {
  Write-Warning "another rufix is on the PATH: $other - remove it, or it may answer to `rufix` instead of $target"
}

$installFlags = $flags
if ($Shell) { $installFlags += "--shell" }
if ($Mod) { $installFlags += "--mod" }
& $target install @installFlags
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $target check @flags
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
