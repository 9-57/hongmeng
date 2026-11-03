@echo off
rem 联调开关：模拟器拿不到 DNS 时，用本机反代让 App 能访问 Supabase。
rem 用法：tools\dev-proxy.cmd on | off | status
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" (
  echo 找不到 PowerShell：%PS%
  exit /b 1
)
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0dev-proxy.ps1" -Mode %*
if errorlevel 1 (
  echo.
  echo [失败] 见上面的错误信息。
  pause
)
endlocal
