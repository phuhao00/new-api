@echo off
REM new-api Windows 一键部署入口（调用 PowerShell 脚本）
setlocal
cd /d "%~dp0\.."
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy.ps1" %*
