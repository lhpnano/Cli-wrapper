@echo off
setlocal
set "AGYMODE="
for /f "usebackq delims=" %%i in (`call "%LOCALAPPDATA%\agy-shim\pwsh-auto.cmd" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\agy-shim\agy-mode.ps1" -Network Auto`) do set "AGYMODE=%%i"
if "%AGYMODE%"=="" goto :route_err
echo %AGYMODE% | findstr /b /c:"ERROR:" >nul
if not errorlevel 1 goto :route_err
if /i "%AGYMODE%"=="DIRECT" (
  set "HTTP_PROXY="
  set "HTTPS_PROXY="
  set "ALL_PROXY="
) else (
  set "HTTP_PROXY=%AGYMODE%"
  set "HTTPS_PROXY=%AGYMODE%"
  set "ALL_PROXY="
)
set "NO_PROXY=127.0.0.1,localhost"
codebuddy %*
exit /b %errorlevel%
:route_err
echo [codebuddy] %AGYMODE% 1>&2
exit /b 9
