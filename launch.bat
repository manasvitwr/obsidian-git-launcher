@echo off
:: Obsidian Git Launcher
:: This file is a thin wrapper only. All sync logic lives in sync.ps1.
:: Do not add business logic here.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync.ps1"
set SYNC_EXIT=%ERRORLEVEL%

:: Pause only on error so the window stays open for inspection
if %SYNC_EXIT% NEQ 0 (
    echo.
    echo [ERROR] Sync failed with exit code %SYNC_EXIT%. See logs\ for details.
    pause
)

exit /b %SYNC_EXIT%
