@echo off
rem Kenshi Mod Manager - launcher
cd /d "%~dp0"
start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0KenshiModManager.ps1"
