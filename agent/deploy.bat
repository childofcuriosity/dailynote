@echo off
REM 部署 agent 到 VPS。用法：deploy.bat [文件名...]
REM 不带参数部署所有 py 文件，带参数只部署指定的
REM 服务器地址从环境变量读取，防止泄露：
REM   setx VPS_HOST "root@你的服务器IP:/root/agent/"

if "%VPS_HOST%"=="" (
    echo 请先设置环境变量 VPS_HOST，例如：
    echo   setx VPS_HOST "root@1.2.3.4:/root/agent/"
    exit /b 1
)

if "%~1"=="" (
    scp -o StrictHostKeyChecking=accept-new *.py %VPS_HOST%
) else (
    scp -o StrictHostKeyChecking=accept-new %* %VPS_HOST%
)

REM 从 VPS_HOST 里提取 root@IP 部分做 ssh 连接
for /f "delims=:" %%a in ("%VPS_HOST%") do set VPS_SSH=%%a

ssh %VPS_SSH% "systemctl restart dailynote-agent && sleep 2 && curl -s http://localhost:8080/status"
