@echo off
rem Double-click launcher for the Windows self-check script - no manual PowerShell steps needed.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\Get-MatlabDiagnostic.ps1" -OutputDir "%~dp0."
rem Keep the window open even if PowerShell failed to start or exited early, so any error stays readable.
pause
