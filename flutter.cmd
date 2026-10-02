@echo off
setlocal enabledelayedexpansion

if /i not "%1"=="run" goto passthru

set "REST="
:shiftloop
shift
if "%1"=="" goto runit
set "REST=!REST! "%1""
goto shiftloop

:runit
"C:\App\Flutter\bin\flutter.bat" run --no-enable-dart-profiling %REST%
exit /b %ERRORLEVEL%

:passthru
"C:\App\Flutter\bin\flutter.bat" %*
exit /b %ERRORLEVEL%
