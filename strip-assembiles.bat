@echo off
setlocal

if "%~1"=="" (
  echo Usage: %~nx0 ^<PathToGame.exe^> [UnityVersion]
  pause
  exit /b 1
)

set scriptPath=%~dp0strip-assemblies.ps1

if "%~2"=="" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%scriptPath%" "%~1"
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%scriptPath%" "%~1" "%~2"
)

set exitCode=%ERRORLEVEL%
if not "%exitCode%"=="0" (
  echo.
  echo Failed with exit code %exitCode%.
)

pause
exit /b %exitCode%
