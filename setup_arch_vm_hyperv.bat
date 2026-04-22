@echo off
REM Auto-elevate PowerShell script to create Arch VM in Hyper-V
REM Right-click and Run as Administrator, or double-click to auto-elevate

setlocal enabledelayedexpansion
cd /d "%~dp0"

REM Check if running as admin
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -Command "Start-Process 'cmd.exe' -ArgumentList '/c \"%~f0\"' -Verb RunAs"
    exit /b
)

REM Running as admin now
echo.
echo Checking if Hyper-V is enabled...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$f = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All; if ($f.State -ne 'Enabled') { Write-Host 'Enabling Hyper-V...' -ForegroundColor Yellow; Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All -NoRestart | Out-Null; Write-Host 'Hyper-V enabled. A reboot is required.' -ForegroundColor Green } else { Write-Host 'Hyper-V is already enabled.' -ForegroundColor Green }"

REM Check if reboot is needed
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$f = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All; if ($f.State -eq 'EnablePending') { exit 1 } else { exit 0 }"

if %errorlevel% equ 1 (
    echo.
    echo Hyper-V was just enabled and requires a reboot before the VM can be created.
    echo After rebooting, run this batch file again.
    echo.
    set /p REBOOT="Reboot now? [Y/N]: "
    if /i "%REBOOT%"=="Y" shutdown /r /t 5
    pause
    exit /b 0
)

echo.
echo Starting Hyper-V VM setup...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup_arch_vm_hyperv.ps1" -IsoPath "%~dp0archlinux-latest-x86_64.iso" -StartVm

echo.
echo CMD window: press any key to close...
pause >nul
exit /b 0
