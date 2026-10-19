@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\to_images.ps1" %*
