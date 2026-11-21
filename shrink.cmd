@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0shrink.ps1" %*
