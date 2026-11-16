# Smoke test of install.ps1 and install.cmd on a scratch machine (a temporary
# bin dir) and a scratch repository: install through both wrappers, the user's
# PATH entry (added once, removed again), a reinstall while a copy of rufix
# runs, `rufix install` / `status` / `uninstall` in the repository, the
# refusal in a subfolder, and an unknown flag.
# CI runs it on Windows. It edits the user's PATH in the registry and puts it
# back; locally: pwsh .github/smoke.ps1
$ErrorActionPreference = "Stop"

$src = Split-Path -Parent $PSScriptRoot
$scratch = Join-Path ([IO.Path]::GetTempPath()) ("rufix-smoke-" + [guid]::NewGuid().ToString("N"))
$env:RUFIX_BIN_DIR = Join-Path $scratch "bin"
$bin = $env:RUFIX_BIN_DIR
$rufix = Join-Path $bin "rufix.exe"
$twin = Join-Path $bin "rufix-shell.exe"
$repo = Join-Path $scratch "repo"

function Fail([string]$why) { throw "SMOKE FAIL: $why" }
function Need([string]$path) { if (-not (Test-Path $path)) { Fail "missing: $path" } }
function Absent([string]$path) { if (Test-Path $path) { Fail "still there: $path" } }
function Succeeds([string]$what) { if ($LASTEXITCODE -ne 0) { Fail "$what failed ($LASTEXITCODE)" } }

# How many times $bin is in the user's PATH, read raw from the registry.
function PathEntries {
  $raw = [string](Get-Item "HKCU:\Environment").GetValue("Path", "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
  return @($raw.Split(";") | Where-Object { $_ -and ($_.TrimEnd("\") -eq $bin.TrimEnd("\")) }).Count
}

function Installed([string]$step) {
  Need $rufix
  Need $twin
  if ((PathEntries) -ne 1) { Fail "$step`: expected one PATH entry, found $(PathEntries)" }
}

New-Item -ItemType Directory -Force -Path (Join-Path $repo "pkg") | Out-Null
git -C $repo init -q

try {
  Write-Host "== install.ps1, then install.cmd (Windows PowerShell), from a folder that is no repository"
  Push-Location $scratch
  & "$src\install.ps1"; Succeeds "install.ps1"
  Installed "install.ps1"
  & "$src\install.cmd"; Succeeds "install.cmd"
  Installed "install.cmd"
  Absent (Join-Path $scratch ".claude")
  Pop-Location

  Write-Host "== install again while a copy of rufix is running"
  # A hook may be running when the binary is replaced, and Windows cannot
  # overwrite a running executable: the installer has to move it aside.
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $rufix
  $psi.Arguments = "redact"
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $holder = [System.Diagnostics.Process]::Start($psi)
  try {
    & "$src\install.ps1"; Succeeds "install.ps1 while rufix runs"
  } finally {
    $holder.StandardInput.Close()
    if (-not $holder.WaitForExit(10000)) { $holder.Kill() }
  }
  Installed "reinstall while running"
  & $rufix version | Out-Null; Succeeds "the reinstalled rufix"

  Write-Host "== the shell twin runs Git Bash, not System32's WSL bash"
  # Claude Code starts MCP servers and hooks through the twin with the
  # Windows PATH, where System32 (bash.exe = WSL) comes before Git.
  $savedPath = $env:Path
  try {
    $env:Path = "$env:SystemRoot\System32;$savedPath"
    $uname = (& $twin 'uname -s' | Out-String).Trim(); Succeeds "rufix-shell"
  } finally { $env:Path = $savedPath }
  if ($uname -notmatch '^(MINGW|MSYS)') { Fail "rufix-shell ran another bash: '$uname'" }

  Write-Host "== set up the repository, then again"
  Push-Location $repo
  foreach ($round in 1, 2) {
    & $rufix install; Succeeds "rufix install"
    Need ".claude\settings.local.json"
    Need ".claude\skills\rufix\hooks\register.ts"
    Need ".claude\skills\rufix\.gitignore"
    Absent ".claude\rufix"
    $status = & $rufix status | Out-String
    Write-Host $status
    foreach ($want in "installed: PostToolUse, PreToolUse", "rufix shell: on", "rufix mod: on") {
      if ($status -notmatch [regex]::Escape($want)) { Fail "status lacks '$want': $status" }
    }
  }

  Write-Host "== a subfolder of the repository is refused"
  Push-Location "pkg"
  & $rufix install *> $null
  if ($LASTEXITCODE -eq 0) { Fail "install in a subfolder succeeded" }
  Absent ".claude"
  Pop-Location

  Write-Host "== take rufix out of the repository"
  & $rufix uninstall; Succeeds "rufix uninstall"
  Absent ".claude\skills\rufix"
  Pop-Location

  Write-Host "== install.cmd --uninstall"
  & "$src\install.cmd" --uninstall; Succeeds "install.cmd --uninstall"
  Absent $rufix
  Absent $twin
  Absent "$rufix.old"
  if ((PathEntries) -ne 0) { Fail "the PATH entry is still there" }

  Write-Host "== install.cmd, then install.ps1 -Uninstall (also with nothing installed)"
  & "$src\install.cmd"; Succeeds "install.cmd"
  Installed "install.cmd after an uninstall"
  & "$src\install.ps1" -Uninstall; Succeeds "install.ps1 -Uninstall"
  Absent $rufix
  if ((PathEntries) -ne 0) { Fail "the PATH entry is still there" }
  & "$src\install.ps1" -Uninstall; Succeeds "a second install.ps1 -Uninstall"

  Write-Host "== an unknown flag is refused"
  & "$src\install.cmd" --bogus *> $null
  if ($LASTEXITCODE -eq 0) { Fail "install.cmd accepted --bogus" }
  Absent $rufix
  Write-Host "SMOKE OK"
} finally {
  while ((Get-Location).Path.StartsWith($scratch)) { Pop-Location }
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $scratch
}
# The last native command was meant to fail; the runner would take its code.
exit 0
