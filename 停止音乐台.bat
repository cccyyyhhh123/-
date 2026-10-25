@echo off
rem ============================================================
rem  Stop the music bridge (it starts automatically with Windows)
rem  To disable auto-start, delete the shortcut
rem  "Music bridge" in shell:startup
rem ============================================================
title Stop Music Bridge
powershell -NoProfile -ExecutionPolicy Bypass -Command "try{ Invoke-WebRequest 'http://127.0.0.1:8787/quit' -UseBasicParsing -TimeoutSec 3 | Out-Null }catch{}; Start-Sleep -Milliseconds 700; $c = Get-NetTCPConnection -LocalPort 8787 -State Listen -ErrorAction SilentlyContinue; if ($c) { Stop-Process -Id $c.OwningProcess -Force }; Write-Host 'Music bridge stopped.'"
timeout /t 2 >nul
