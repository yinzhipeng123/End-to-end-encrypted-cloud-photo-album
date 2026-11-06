@echo off
setlocal
set "APP=%~dp0build\windows\x64\runner\Release\encrypted_photo_app.exe"
if not exist "%APP%" (
  echo Windows build not found. See README.md for build instructions.
  pause
  exit /b 1
)
start "" "%APP%"
