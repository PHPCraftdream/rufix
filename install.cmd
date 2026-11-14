@echo off
rem rufix setup wrapper: runs install.ps1 (PowerShell) from cmd.exe. Once per
rem machine, from any folder; a repository is set up by `rufix install` in it.
rem   install.cmd              build, install, add to the PATH
rem   install.cmd --uninstall  remove the binaries and the PATH entry
setlocal EnableDelayedExpansion
set "PSARGS="
:next
if "%~1"=="" goto run
set "A=%~1"
if /i "%A%"=="--uninstall" (
  set "PSARGS=!PSARGS! -Uninstall"
) else (
  echo rufix setup: unknown flag %A% ^(supported: --uninstall^) 1>&2
  exit /b 1
)
shift
goto next
:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"!PSARGS!
exit /b %ERRORLEVEL%
