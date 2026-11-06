@echo off
rem Do NOT change the console code page here: Windows PowerShell 5.1
rem renders Chinese correctly with the system default code page.
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0pppoe-watchdog.ps1" -Setup
endlocal
echo.
pause