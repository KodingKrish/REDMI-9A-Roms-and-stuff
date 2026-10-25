@echo off
setlocal
title MTK AutoRepair
cd /d "%~dp0"

if not exist "%~dp0MTK_AutoRepair.ps1" (
    echo MTK_AutoRepair.ps1 must be in the same folder as this .bat file.
    pause
    exit /b 1
)

rem Administrator rights help with USB driver access
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator rights...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0MTK_AutoRepair.ps1"
echo.
pause
