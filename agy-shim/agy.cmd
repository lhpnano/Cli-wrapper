@echo off
setlocal
set "AGYMODE="
for /f "usebackq delims=" %%i in (`call "%LOCALAPPDATA%\agy-shim\pwsh-auto.cmd" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\agy-shim\agy-mode.ps1" -Network Auto`) do set "AGYMODE=%%i"
if "%AGYMODE%"=="" goto :agyerr
echo %AGYMODE% | findstr /b /c:"ERROR:" >nul
if not errorlevel 1 goto :agyerr
set "AGY_EXE=%LOCALAPPDATA%\agy\bin\agy.exe"
if exist "%AGY_EXE%" goto :route_ok
set "AGY_EXE="
for /f "usebackq delims=" %%i in (`call "%LOCALAPPDATA%\agy-shim\pwsh-auto.cmd" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command "$roots=@(Join-Path $env:LOCALAPPDATA 'agy', Join-Path $env:LOCALAPPDATA 'Programs'); $cmd=foreach($r in $roots){ if(Test-Path $r){ Get-ChildItem $r -Recurse -File -Filter agy.exe -ErrorAction SilentlyContinue } } | Sort-Object LastWriteTime -Descending | Select-Object -First 1; if($cmd){$cmd.FullName}"`) do set "AGY_EXE=%%i"
if "%AGY_EXE%"=="" goto :agy_target_err
:route_ok
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
"%AGY_EXE%" %*
exit /b %errorlevel%
:agy_target_err
echo [agy] agy.exe target not found 1>&2
exit /b 8
:agyerr
echo [agy] %AGYMODE% 1>&2
exit /b 9
