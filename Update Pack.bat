@echo off
title Update Rift SMP
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-pack.ps1" %*
echo.
pause
