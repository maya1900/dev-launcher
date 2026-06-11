@echo off
setlocal

set "SCRIPT_DIR=%~dp0"

where bash >nul 2>nul
if errorlevel 1 (
  echo [dev] bash not found. Install Git for Windows or add bash to PATH. 1>&2
  exit /b 1
)

bash "%SCRIPT_DIR%dev.sh" %*
