@echo off
setlocal
set "AI_ROUTE="
for /f "usebackq delims=" %%i in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\agy-shim\cli-network-sync.ps1" -Network Auto`) do set "AI_ROUTE=%%i"
if "%AI_ROUTE%"=="" goto :route_error
echo %AI_ROUTE% | findstr /b /c:"ERROR:" >nul
if not errorlevel 1 goto :route_error
if /i "%AI_ROUTE%"=="DIRECT" (set "HTTP_PROXY=" & set "HTTPS_PROXY=" & set "ALL_PROXY=") else (set "HTTP_PROXY=%AI_ROUTE%" & set "HTTPS_PROXY=%AI_ROUTE%" & set "ALL_PROXY=")
set "NO_PROXY=127.0.0.1,localhost,::1"
call "C:\Users\haipe\AppData\Roaming\npm\codex.cmd" %*
exit /b %errorlevel%
:route_error
echo [ai-cli-auto] %AI_ROUTE% 1>&2
exit /b 9
