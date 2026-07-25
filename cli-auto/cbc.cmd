@echo off
setlocal
set "AI_ROUTE="
for /f "usebackq delims=" %%i in (`powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\agy-shim\cli-network-sync.ps1" -Network Auto`) do set "AI_ROUTE=%%i"
if "%AI_ROUTE%"=="" goto :route_error
echo %AI_ROUTE% | findstr /b /c:"ERROR:" >nul
if not errorlevel 1 goto :route_error
set "CODEBUDDY_TARGET="
for /f "usebackq delims=" %%i in (`powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command "$versions=Join-Path $env:USERPROFILE '.workbuddy\binaries\node\versions'; $cmd=Get-ChildItem $versions -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | ForEach-Object { Join-Path $_.FullName 'codebuddy.cmd' } | Where-Object { Test-Path $_ } | Select-Object -First 1; if($cmd){$cmd}"`) do set "CODEBUDDY_TARGET=%%i"
if "%CODEBUDDY_TARGET%"=="" goto :target_error
if /i "%AI_ROUTE%"=="DIRECT" (set "HTTP_PROXY=" & set "HTTPS_PROXY=" & set "ALL_PROXY=") else (set "HTTP_PROXY=%AI_ROUTE%" & set "HTTPS_PROXY=%AI_ROUTE%" & set "ALL_PROXY=")
set "NO_PROXY=127.0.0.1,localhost,::1"
call "%CODEBUDDY_TARGET%" %*
exit /b %errorlevel%
:target_error
echo [ai-cli-auto] CodeBuddy CLI target not found 1>&2
exit /b 8
:route_error
echo [ai-cli-auto] %AI_ROUTE% 1>&2
exit /b 9
