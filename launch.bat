@echo off
:: Obsidian Git Launcher
:: This file is a thin wrapper only. All sync logic lives in sync.ps1.
:: Do not add business logic here.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync.ps1"

:: Pause only on error so the window stays open for inspection
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo [ERROR] Sync failed with exit code %ERRORLEVEL%. See logs\ for details.
    pause
)
