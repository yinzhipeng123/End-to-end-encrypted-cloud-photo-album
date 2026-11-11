@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "EPA_CLEAN_SCRIPT=%~dp0src\windows\scripts\maintenance\clean-build-artifacts.ps1"
set "EPA_CLEAN_PREVIEW="
set "EPA_CLEAN_PAUSE=1"
set "EPA_CLEAN_EXIT=0"

:parse_args
if "%~1"=="" goto run_cleanup
if /I "%~1"=="-WhatIf" goto enable_preview
if /I "%~1"=="-NoPause" goto disable_pause
echo Usage: clean-build.cmd [-WhatIf] [-NoPause]
set "EPA_CLEAN_EXIT=2"
goto finish

:enable_preview
set "EPA_CLEAN_PREVIEW=-WhatIf"
shift /1
goto parse_args

:disable_pause
set "EPA_CLEAN_PAUSE=0"
shift /1
goto parse_args

:run_cleanup
if not exist "%EPA_CLEAN_SCRIPT%" (
  echo Cleanup script not found. Keep this file in the project root.
  set "EPA_CLEAN_EXIT=1"
  goto finish
)
echo Cleaning Windows build packages and intermediate outputs.
echo Source, OpenSpec, user vaults and historical test data are preserved.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%EPA_CLEAN_SCRIPT%" %EPA_CLEAN_PREVIEW%
set "EPA_CLEAN_EXIT=%ERRORLEVEL%"
if not "%EPA_CLEAN_EXIT%"=="0" (
  echo Cleanup failed. Review the error above; some outputs may remain.
  goto finish
)
if defined EPA_CLEAN_PREVIEW (
  echo Preview complete. Nothing was removed.
) else (
  echo Cleanup complete. Rebuild the Windows app before running it again.
)

:finish
if "%EPA_CLEAN_PAUSE%"=="1" pause
exit /b %EPA_CLEAN_EXIT%
