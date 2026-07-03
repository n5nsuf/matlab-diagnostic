@echo off
rem Double-click launcher for the Windows self-check script - no manual PowerShell steps needed.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\Get-MatlabDiagnostic.ps1" -OutputDir "%~dp0"
