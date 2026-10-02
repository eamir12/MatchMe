@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_mobile.ps1" %*
exit /b %ERRORLEVEL%
