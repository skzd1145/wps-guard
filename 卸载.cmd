@echo off
setlocal
cd /d "%~dp0"
echo Uninstalling WPS Background Guard...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1"
echo.
pause
