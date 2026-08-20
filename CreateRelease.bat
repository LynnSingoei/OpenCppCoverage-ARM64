@echo off
setlocal

set PLATFORM=%~1
if "%PLATFORM%"=="" set PLATFORM=x64

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0CreateRelease.ps1" -Platform "%PLATFORM%" -Configuration Release
exit /b %ERRORLEVEL%