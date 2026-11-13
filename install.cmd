@echo off
rem rufix setup wrapper: runs install.ps1 (PowerShell) from cmd.exe.
rem Flags are remapped to PowerShell switches:
rem   install.cmd                       install (global hooks)
rem   install.cmd --project             hooks into .\.claude\settings.json
rem   install.cmd --env-files           hooks also load external env files
rem   install.cmd --project --shell     also wrap this repository's shell
rem   install.cmd --project --mod       also add the mod masking prompts and failed tool output
rem   install.cmd --revert              uninstall hooks and remove the binaries
setlocal EnableDelayedExpansion
set "PSARGS="
:next
if "%~1"=="" goto run
set "A=%~1"
if /i "%A%"=="--revert" (
  set "PSARGS=!PSARGS! -Revert"
) else if /i "%A%"=="--project" (
  set "PSARGS=!PSARGS! -Project"
) else if /i "%A%"=="--env-files" (
  set "PSARGS=!PSARGS! -EnvFiles"
) else if /i "%A%"=="--mod" (
  set "PSARGS=!PSARGS! -Mod"
) else if /i "%A%"=="--shell" (
  set "PSARGS=!PSARGS! -Shell"
) else (
  echo rufix setup: unknown flag %A% ^(supported: --project, --env-files, --shell, --mod, --revert^) 1>&2
  exit /b 1
)
shift
goto next
:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"!PSARGS!
exit /b %ERRORLEVEL%
