@echo off
chcp 65001 >nul
title 轻账win功能工具箱
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0WinGuard.ps1"
