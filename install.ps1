# rufix setup for ONE repository: run it from that repository's folder.
# It builds the release binary with Zig and runs `rufix install` there, which
# copies the binary to .claude\rufix\ and writes the hooks, the shell wrapper
# and the mod into .claude\. Nothing is installed outside the folder: no PATH
# entry, nothing in ~\.claude.
#
# Usage (from the repository to protect):
#   C:\path\to\rufix\install.ps1                 set up this folder
#   C:\path\to\rufix\install.ps1 -EnvFiles       hooks also load external env files
#   C:\path\to\rufix\install.ps1 -Revert         take everything out of this folder
#   C:\path\to\rufix\install.ps1 -CleanGlobal    one-off: remove what older versions put
#                                                outside repositories (hooks in
#                                                ~\.claude\settings.json, the binaries,
#                                                the user's PATH entry)
#
# Private values come from secrets\values.zig (in the rufix folder) when it exists.
param(
  [switch]$EnvFiles,
  [switch]$Revert,
  [switch]$CleanGlobal
)

$ErrorActionPreference = "Stop"
$target = (Get-Location).Path
$src = $PSScriptRoot
$local = Join-Path $target ".claude\rufix"
$localExe = Join-Path $local "rufix.exe"
$flags = @()
if ($EnvFiles) { $flags += "--env-files" }

# A folder that still holds anything is somebody else's: never removed.
function Remove-EmptyDir([string]$path) {
  if ((Test-Path $path) -and -not (Get-ChildItem -Force $path)) { Remove-Item $path }
}

if ($Revert) {
  if (Test-Path $localExe) {
    & $localExe uninstall
  } else {
    Write-Host "rufix is not installed in $target"
  }
  # A binary that was running could not delete itself: it is gone now.
  Remove-Item -Force -ErrorAction SilentlyContinue $localExe, (Join-Path $local "rufix-shell.exe"), (Join-Path $local ".gitignore")
  Remove-EmptyDir $local
  Write-Host "rufix removed from $target."
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

if ($CleanGlobal) {
  # What older versions installed: hooks in ~\.claude\settings.json, the
  # binaries in $env:RUFIX_BIN_DIR (default %LOCALAPPDATA%\rufix\bin) and a
  # PATH entry. The user's PATH is read and written raw (REG_EXPAND_SZ):
  # going through [Environment] would expand entries such as %USERPROFILE%\bin.
  $bin = if ($env:RUFIX_BIN_DIR) { $env:RUFIX_BIN_DIR } else { Join-Path $env:LOCALAPPDATA "rufix\bin" }
  & $built uninstall --global
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $bin "rufix.exe"), (Join-Path $bin "rufix-shell.exe"), (Join-Path $bin "rufix.exe.old"), (Join-Path $bin "rufix-shell.exe.old")
  Remove-EmptyDir $bin
  Remove-EmptyDir (Split-Path $bin -Parent)
  $key = Get-Item -Path "HKCU:\Environment"
  $raw = [string]$key.GetValue("Path", "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
  $entries = @($raw.Split(";") | Where-Object { $_ })
  $kept = @($entries | Where-Object { $_.TrimEnd("\") -ne $bin.TrimEnd("\") })
  if ($kept.Count -ne $entries.Count) {
    Set-ItemProperty -Path "HKCU:\Environment" -Name "Path" -Value ($kept -join ";") -Type ExpandString
    # Setting any variable through [Environment] broadcasts the change to new terminals.
    [Environment]::SetEnvironmentVariable("RUFIX_PATH_REFRESH", "1", "User")
    [Environment]::SetEnvironmentVariable("RUFIX_PATH_REFRESH", $null, "User")
    Write-Host "rufix setup: removed $bin from the user's PATH"
  }
  Write-Host "rufix setup: repositories set up by an older version still call $bin\rufix:"
  Write-Host "rufix setup: run the installer again in each of them."
  exit 0
}

& $built install @flags
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $localExe check @flags
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
