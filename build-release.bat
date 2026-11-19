@echo off
setlocal
pushd "%~dp0" || exit /b 1
pwsh -NoProfile -File "%~dp0tools\windows-wallpaper\build-release.ps1" %*
set "result=%ERRORLEVEL%"
popd
echo.
if not "%result%"=="0" echo Build failed. Exit code: %result%
pause
exit /b %result%
