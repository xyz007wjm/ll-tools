@echo off
chcp 65001 >nul
title 轻账win功能工具箱 - 恢复系统默认
net session >nul 2>&1
if errorlevel 1 (
    powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0cli.ps1" -Action restore-all
pause
