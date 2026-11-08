@echo off
setlocal
cd /d "%~dp0"
echo Installing WPS Background Guard...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
echo.
pause
