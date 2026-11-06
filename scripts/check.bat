@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0pppoe-watchdog.ps1" -Check
endlocal
pause