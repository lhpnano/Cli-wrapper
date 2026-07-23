@echo off
setlocal
set "AGYMODE="
for /f "usebackq delims=" %%i in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\agy-shim\agy-mode.ps1" -Network Surfshark`) do set "AGYMODE=%%i"
if "%AGYMODE%"=="" goto :agyerr
echo %AGYMODE% | findstr /b /c:"ERROR:" >nul
if not errorlevel 1 goto :agyerr
if /i "%AGYMODE%"=="DIRECT" (
  set "HTTP_PROXY="
  set "HTTPS_PROXY="
  set "ALL_PROXY="
) else (
  set "HTTP_PROXY=%AGYMODE%"
  set "HTTPS_PROXY=%AGYMODE%"
)
set "NO_PROXY=127.0.0.1,localhost"
"%LOCALAPPDATA%\agy\bin\agy.exe" %*
exit /b %errorlevel%
:agyerr
echo [agy] %AGYMODE% 1>&2
exit /b 9