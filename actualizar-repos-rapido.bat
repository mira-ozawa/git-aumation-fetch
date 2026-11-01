@echo off
title Actualizar remotes de git (rapido, sin fetch)
cd /d "%~dp0"
if not exist "%~dp0actualizar-repos.ps1" (
  echo No encuentro actualizar-repos.ps1 en esta carpeta: %~dp0
  echo Pon este .bat junto al .ps1 y vuelve a abrirlo.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0actualizar-repos.ps1" -Apply -NoFetch
echo.
echo ===== Terminado. Revisa el resumen de arriba. =====
pause
