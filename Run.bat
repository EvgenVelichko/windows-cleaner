@echo off
setlocal
if exist "%~dp0WindowsCleaner.exe" (
  start "" "%~dp0WindowsCleaner.exe"
) else (
  echo WindowsCleaner.exe was not found in this folder.
  pause
)
