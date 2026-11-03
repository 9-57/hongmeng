@echo off
rem 一键：构建 + 本地签名 + 安装 + 启动。
rem 直接转交给 run.ps1（PowerShell 原生实现），不依赖 Git Bash / WSL。
rem
rem 用法（在项目根目录，cmd 或双击）：
rem   tools\run.cmd                          只有一台设备时直接用它
rem   tools\run.cmd -Device 127.0.0.1:5555   多台设备时指定其一
rem   tools\run.cmd -All                     已连接的所有设备都装一遍（两台模拟器最省事）
rem   tools\run.cmd -NoEmulator              没设备时不要自动启动模拟器
setlocal enabledelayedexpansion

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" (
  echo 找不到 PowerShell：%PS%
  exit /b 1
)

rem 允许 --device / --all 这类 GNU 风格写法，统一转成 PowerShell 参数
set "ARGS=%*"
if defined ARGS set "ARGS=%ARGS:--device=-Device%"
if defined ARGS set "ARGS=%ARGS:--all=-All%"
if defined ARGS set "ARGS=%ARGS:--no-emulator=-NoEmulator%"

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0run.ps1" %ARGS%
if errorlevel 1 (
  echo.
  echo [失败] 见上面的错误信息。没设备就先开模拟器；多台设备用 -Device 指定，或用 -All 全装。
  pause
)
endlocal
