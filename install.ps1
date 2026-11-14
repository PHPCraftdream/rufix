# rufix setup, once per machine: build the release binary with Zig and put it,
# with its rufix-shell twin, into a folder on the user's PATH. A repository is
# then set up by `rufix install`, run in that repository; this script touches no
# repository and nothing in ~\.claude.
#
# Usage (from anywhere):
#   C:\path\to\rufix\install.ps1              build, install, add to the PATH
#   C:\path\to\rufix\install.ps1 -Uninstall   remove the binaries and the PATH entry,
#                                             and the hooks older versions put into
#                                             ~\.claude\settings.json
#
# The binary goes to $env:RUFIX_BIN_DIR (default %LOCALAPPDATA%\rufix\bin).
# Private values come from secrets\values.zig (in the rufix folder) when it
# exists; run this again after editing it.
param(
  [switch]$Uninstall
)

$ErrorActionPreference = "Stop"
$src = $PSScriptRoot

$bin = if ($env:RUFIX_BIN_DIR) { $env:RUFIX_BIN_DIR } else { Join-Path $env:LOCALAPPDATA "rufix\bin" }
$target = Join-Path $bin "rufix.exe"
$twin = Join-Path $bin "rufix-shell.exe"

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

# The entries of the user's PATH other than $dir.
function Get-UserPathWithout([string]$dir) {
  return @((Get-RawUserPath).Split(";") | Where-Object { $_ -and ($_.TrimEnd("\") -ne $dir.TrimEnd("\")) })
}

# A folder that still holds anything is somebody else's: never removed.
function Remove-EmptyDir([string]$path) {
  if ((Test-Path $path) -and -not (Get-ChildItem -Force $path)) { Remove-Item $path }
}

if ($Uninstall) {
  if (Test-Path $target) {
    # Hooks of older versions, which applied to every repository.
    & $target uninstall --global
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  }
  Remove-Item -Force -ErrorAction SilentlyContinue $target, $twin, "$target.old", "$twin.old"
  Remove-EmptyDir $bin
  if (-not $env:RUFIX_BIN_DIR) { Remove-EmptyDir (Split-Path $bin -Parent) }
  $entries = @((Get-RawUserPath).Split(";") | Where-Object { $_ })
  $kept = @(Get-UserPathWithout $bin)
  if ($kept.Count -ne $entries.Count) {
    Set-RawUserPath ($kept -join ";")
    Write-Host "rufix setup: removed $bin from the user's PATH"
  }
  if ((Test-Path $target) -or (Test-Path $twin)) {
    Write-Warning "a running rufix could not be deleted: remove $bin by hand when it has stopped"
  } else {
    Write-Host "rufix removed from $bin."
  }
  Write-Host "rufix setup: a repository where rufix is still installed now calls a missing binary,"
  Write-Host "rufix setup: which blocks its tool calls: take it out there with ``rufix uninstall`` first."
  exit 0
}

Push-Location $src
try {
  zig build -Doptimize=ReleaseSmall
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
  Pop-Location
}
$built = Join-Path $src "zig-out\bin\rufix.exe"
New-Item -ItemType Directory -Force -Path $bin | Out-Null

# A running hook keeps its executable open: move it aside instead of overwriting.
function Place([string]$from, [string]$to) {
  if (Test-Path $to) { Move-Item -Force $to "$to.old" }
  Copy-Item $from $to
  Remove-Item -Force -ErrorAction SilentlyContinue "$to.old"
}
Place $built $target
Place $built $twin

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
  Write-Warning "another rufix is on the PATH: $other - remove it, or it may answer to ``rufix`` instead of $target"
}

& $target check
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host "rufix setup: installed in $bin"
Write-Host "rufix setup: set up a repository: cd <repository>; rufix install"
