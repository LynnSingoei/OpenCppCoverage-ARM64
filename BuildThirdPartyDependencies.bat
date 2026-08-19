@echo off
setlocal

set TRIPLET=%~1
if "%TRIPLET%"=="" set TRIPLET=x64-windows

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0InstallThirdPartyLibraries.ps1" -Triplet "%TRIPLET%"
exit /b %ERRORLEVEL%