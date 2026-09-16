@echo off
setlocal
set "HERE=%~dp0"
where pwsh >nul 2>nul
if %ERRORLEVEL%==0 (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "%HERE%wmic.ps1" %*
  exit /b %ERRORLEVEL%
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%wmic.ps1" %*
exit /b %ERRORLEVEL%
