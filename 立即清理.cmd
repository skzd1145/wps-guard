@echo off
setlocal
set "GUARD=%LOCALAPPDATA%\WpsGuard\wps-guard.ps1"
if not exist "%GUARD%" set "GUARD=%~dp0wps-guard.ps1"
echo Cleaning WPS background processes now...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%GUARD%" -Once
echo.
pause
