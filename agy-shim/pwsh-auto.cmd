@echo off
setlocal
set "AI_PWSH=%LOCALAPPDATA%\Programs\PowerShell\7\pwsh.exe"
if not exist "%AI_PWSH%" set "AI_PWSH=powershell.exe"
"%AI_PWSH%" %*
exit /b %errorlevel%
