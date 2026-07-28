@echo off
call "%LOCALAPPDATA%\agy-shim\pwsh-auto.cmd" -NoProfile -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\agy-shim\claude-shared.ps1" %*
