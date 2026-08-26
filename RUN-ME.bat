@echo off
REM ============================================================
REM  Windows 11 Optimization - one-click launcher
REM  Double-click this file. It requests admin rights, bypasses
REM  the execution policy for this run only, and runs the script.
REM ============================================================

title Windows 11 Optimization

REM --- Are we already elevated? ---
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"

if not exist "%~dp0Optimize-AllInOne.ps1" (
    echo.
    echo ERROR: Optimize-AllInOne.ps1 was not found next to this launcher.
    echo Keep both files in the same folder.
    echo.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Optimize-AllInOne.ps1"

echo.
echo ============================================================
echo  Finished. Review the output above.
echo ============================================================
pause
