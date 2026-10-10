@echo off
setlocal
pushd "%~dp0" || exit /b 1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0swb.ps1" %*
set "swbExitCode=%errorlevel%"
popd
exit /b %swbExitCode%
