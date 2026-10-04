@echo off
REM Deploy backend code and language resources without replacing runtime data.
REM Usage: deploy.bat [python-file ...]
REM Example: set VPS_HOST=root@your-server:/root/agent/
if "%VPS_HOST%"=="" (
    echo Set VPS_HOST to user@host:/path/to/agent/ first.
    exit /b 1
)
if "%~1"=="" (
    scp -o StrictHostKeyChecking=accept-new *.py %VPS_HOST%
) else (
    scp -o StrictHostKeyChecking=accept-new %* %VPS_HOST%
)
if errorlevel 1 exit /b 1
scp -r -o StrictHostKeyChecking=accept-new locales %VPS_HOST%
if errorlevel 1 exit /b 1
for /f "delims=:" %%a in ("%VPS_HOST%") do set VPS_SSH=%%a
ssh %VPS_SSH% "systemctl restart dailynote-agent && systemctl is-active dailynote-agent"
