@echo off
rem rufix setup wrapper: runs install.ps1 (PowerShell) from cmd.exe.
rem Flags are remapped to PowerShell switches:
rem   install.cmd              install (global hooks)
rem   install.cmd --project    hooks into .\.claude\settings.json
rem   install.cmd --revert     uninstall hooks and remove the binary
setlocal EnableDelayedExpansion
set "PSARGS="
:next
if "%~1"=="" goto run
set "A=%~1"
if /i "%A%"=="--revert" set "PSARGS=!PSARGS! -Revert"
if /i "%A%"=="--project" set "PSARGS=!PSARGS! -Project"
shift
goto next
:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"!PSARGS!
