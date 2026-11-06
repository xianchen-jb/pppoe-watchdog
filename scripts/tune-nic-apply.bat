@echo off
rem Actually apply the NIC power-saving changes (requests administrator rights).
rem This briefly renegotiates the link, so the network may drop for a few seconds.
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tune-nic.ps1" -Apply
endlocal