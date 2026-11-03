# 一键：构建 + 本地签名 + 安装 + 启动（PowerShell 原生版，不依赖 bash / WSL / Git）
#
# 用法（在项目根目录，PowerShell 里）：
#   powershell -ExecutionPolicy Bypass -File tools\run.ps1
#   .\tools\run.ps1 -Device 127.0.0.1:5555   （模拟器 + 真机同时插着时指定）
#   .\tools\run.ps1 -All                     （已连接的所有设备都装一遍）
#   .\tools\run.ps1 -NoEmulator              （没设备时不要自动启动模拟器）
param(
  [string]$Device = "",
  [switch]$All,
  [switch]$NoEmulator,
  [string]$BuildMode = "debug"
)
$ErrorActionPreference = "Continue"   # hvigor 把 WARN 写 stderr，Stop 会误判为终止错误

# DevEco 安装位置在不同机器/不同时期可能不一样（本机是 "D:\DevEco studio"，
# 早期文档里写的是 "D:\deveco-studio\DevEco Studio"）。这里按候选顺序探测，
# 避免把项目拷到别的电脑后脚本直接跑不起来。
function Resolve-DevEco {
  $candidates = @(
    $env:DEVECO_HOME,
    "D:\DevEco studio",
    "D:\deveco-studio\DevEco Studio",
    "D:\HarmonyOS\DevEco Studio6.0.1\DevEco Studio",
    "C:\Program Files\Huawei\DevEco Studio"
  )
  foreach ($c in $candidates) {
    if ($c -and (Test-Path (Join-Path $c "sdk"))) { return $c }
  }
  throw "找不到 DevEco Studio 安装目录，请设置 DEVECO_HOME 指向它（例如 D:\DevEco studio）。"
}

$DevEco   = Resolve-DevEco
$Hdc      = Join-Path $DevEco "sdk\default\openharmony\toolchains\hdc.exe"
$Emulator = Join-Path $DevEco "tools\emulator\Emulator.exe"
$SdkLib   = Join-Path $DevEco "sdk\default\openharmony\toolchains\lib"
$EmuName  = if ($env:EMU_NAME) { $env:EMU_NAME } else { "Mate 80 Pro Max" }
# 模拟器实例目录跟着当前用户走，不能写死成别人的用户目录
$EmuPath  = if ($env:EMU_PATH) { $env:EMU_PATH } else { Join-Path $env:LOCALAPPDATA "Huawei\Emulator\deployed" }
$Bundle   = "com.example.harmony03"
$Ability  = "EntryAbility"

# 签名用 DevEco 自带的 JBR，别依赖系统 PATH 上的 java（版本可能不对）
$Java = Join-Path $DevEco "jbr\bin\java.exe"
if (-not (Test-Path $Java)) { $Java = "java" }

$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

function Get-Targets {
  (& $Hdc list targets) 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" -and $_ -ne "[Empty]" }
}

# ---- 1. 选定设备 ----
$Device = $Device.Trim()
$Devices = @()
if ($All) {
  $Devices = @(Get-Targets)
  if ($Devices.Count -eq 0) { throw "没有连接的设备，无法 -All。" }
} elseif ($Device) {
  $Devices = @($Device)
} else {
  $t = @(Get-Targets)
  if ($t.Count -eq 0) {
    if ($NoEmulator) { throw "没有连接的设备，且已指定 -NoEmulator。" }
    Write-Host "[0/4] 没有设备，启动模拟器 $EmuName （约 60~120 秒）"
    Start-Process -FilePath $Emulator -ArgumentList @("-hvd", $EmuName, "-path", $EmuPath) -WindowStyle Minimized
    for ($i = 0; $i -lt 90; $i++) {
      Start-Sleep -Seconds 2
      $t = @(Get-Targets)
      if ($t.Count -gt 0) { break }
    }
    if ($t.Count -eq 0) {
      throw "模拟器 180 秒内未就绪。手动启动：`n  `"$Emulator`" -hvd `"$EmuName`" -path `"$EmuPath`""
    }
  }
  if ($t.Count -gt 1) {
    throw ("检测到多台设备，请用 -Device 指定其一，或用 -All 全装：`n  " + ($t -join "`n  "))
  }
  $Devices = @($t[0])
}
Write-Host ("目标设备：" + ($Devices -join ", "))

# ---- 2. 构建 ----
Write-Host "[1/4] 构建（$BuildMode）"
$env:DEVECO_SDK_HOME = Join-Path $DevEco "sdk"
$env:PATH = (Join-Path $DevEco "tools\node") + ";" + $env:PATH
& node (Join-Path $DevEco "tools\hvigor\bin\hvigorw.js") --mode module -p product=default -p buildMode=$BuildMode assembleHap --no-daemon 2>&1 | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) { throw "构建失败（hvigor 退出码 $LASTEXITCODE）" }

$Unsigned = "entry\build\default\outputs\default\entry-default-unsigned.hap"
$Signed   = "dist\harmony03-signed.hap"
if (-not (Test-Path $Unsigned)) { throw "找不到构建产物 $Unsigned" }

# ---- 3. 签名 ----
Write-Host "[2/4] 本地签名"
if (Test-Path $Signed) { Remove-Item $Signed -Force -ErrorAction SilentlyContinue }   # 别让上次的旧包冒充成功
$signLog = & $Java -jar (Join-Path $SdkLib "hap-sign-tool.jar") sign-app `
  -keyAlias "openharmony application release" -signAlg SHA256withECDSA -mode localSign `
  -appCertFile "signature\harmony03_chain.cer" -profileFile "signature\openharmony.p7b" `
  -inFile $Unsigned -outFile $Signed `
  -keystoreFile "signature\openharmony.p12" -keyPwd 123456 -keystorePwd 123456 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $Signed)) {
  Write-Host $signLog
  throw "签名失败（hap-sign-tool 退出码 $LASTEXITCODE）"
}
Write-Host ("  " + $Signed + "  " + (Get-Item $Signed).Length + " 字节")

# ---- 4+5. 逐台安装 + 启动 ----
$i = 0
foreach ($dev in $Devices) {
  $i++
  Write-Host "[3/4] 安装到 $dev"
  $out = (& $Hdc -t $dev install -r $Signed) 2>&1 | Out-String
  if ($out -notmatch "successfully") {
    if ($out -match "9568332") {
      Write-Host "  签名不一致（设备上装的是别的证书签的包），卸载旧包重装——本机 App 数据会清空"
      & $Hdc -t $dev uninstall $Bundle 2>&1 | Out-Null
      $out = (& $Hdc -t $dev install -r $Signed) 2>&1 | Out-String
    }
    if ($out -notmatch "successfully") { Write-Host $out; throw "$dev 安装失败" }
  }
  Write-Host "  安装成功，启动 $Bundle/$Ability"
  & $Hdc -t $dev shell aa start -a $Ability -b $Bundle | Out-Null
}

Write-Host "[4/4] 完成。实时日志："
foreach ($dev in $Devices) {
  Write-Host ("  `"$Hdc`" -t $dev shell hilog | Select-String carbon")
}
