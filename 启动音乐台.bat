@echo off
rem ============================================================
rem  Music bridge launcher
rem  1) starts music-bridge.ps1 (minimized window, keep it open)
rem  2) opens index.html in the default browser
rem  Close the minimized PowerShell window to stop the bridge.
rem ============================================================
title Music Bridge
cd /d "%~dp0"

start "" /min powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0music-bridge.ps1"
timeout /t 2 /nobreak >nul

start "" "%~dp0index.html"
exit
