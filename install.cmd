@echo off
rem rufix setup wrapper: runs install.ps1 (PowerShell) from cmd.exe, in the
rem current folder (the repository to protect). Flags become PowerShell switches:
rem   install.cmd                  set up this folder
rem   install.cmd --env-files      hooks also load external env files
rem   install.cmd --revert         take everything out of this folder
rem   install.cmd --clean-global   one-off: remove what older versions put outside repositories
setlocal EnableDelayedExpansion
set "PSARGS="
:next
if "%~1"=="" goto run
set "A=%~1"
if /i "%A%"=="--revert" (
  set "PSARGS=!PSARGS! -Revert"
) else if /i "%A%"=="--env-files" (
  set "PSARGS=!PSARGS! -EnvFiles"
) else if /i "%A%"=="--clean-global" (
  set "PSARGS=!PSARGS! -CleanGlobal"
) else (
  echo rufix setup: unknown flag %A% ^(supported: --env-files, --revert, --clean-global^) 1>&2
  exit /b 1
)
shift
goto next
:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"!PSARGS!
exit /b %ERRORLEVEL%
