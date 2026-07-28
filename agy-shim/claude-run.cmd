@echo off
call "%LOCALAPPDATA%\agy-shim\pwsh-auto.cmd" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\agy-shim\claude-run.ps1" %*
