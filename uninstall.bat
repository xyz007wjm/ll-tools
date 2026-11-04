@echo off
chcp 65001 >nul
title 轻账win功能工具箱 - 卸载并恢复
net session >nul 2>&1
if errorlevel 1 (
    powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
echo 即将恢复更新、防火墙与共享设置，并删除轻账win功能工具箱守护任务和数据目录。
pause
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0cli.ps1" -Action uninstall
pause
