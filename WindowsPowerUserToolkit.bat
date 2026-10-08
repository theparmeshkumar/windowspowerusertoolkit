@echo off
setlocal
title Windows Power User Toolkit
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0WindowsPowerUserToolkit.ps1"
if errorlevel 1 (
    echo.
    echo The application could not be started.
    pause
)
endlocal
