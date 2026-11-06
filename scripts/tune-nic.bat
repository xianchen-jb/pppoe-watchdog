@echo off
rem Preview only (no changes). To actually write, run tune-nic-apply.bat instead.
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tune-nic.ps1"
endlocal