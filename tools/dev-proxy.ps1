# 联调开关：把 SUPABASE_URL 在"正式地址"和"本机代理"之间切换，并自动重新构建安装。
#
# 为什么需要：这台机器上的模拟器 netstack 拿不到可用 DNS（ping 能解析、App 不能），
# 但到宿主机 10.0.2.2 的 TCP 是通的。所以本地联调时走本机反代。
#
# 用法：
#   tools\dev-proxy.cmd on      起代理 + 切到 http://10.0.2.2:8787 + 构建安装
#   tools\dev-proxy.cmd off     停代理 + 切回正式地址 + 构建安装
#   tools\dev-proxy.cmd status  只看当前地址和代理状态，不动任何东西
param(
  [Parameter(Mandatory = $true)][ValidateSet('on', 'off', 'status')][string]$Mode,
  [string]$Device = ""
)

$Root   = Split-Path -Parent $PSScriptRoot
$Client = Join-Path $Root "entry\src\main\ets\service\SupabaseClient.ets"
$ProdUrl = "https://hfumlfksryyzaebiuaca.supabase.co"
$DevUrl  = "http://10.0.2.2:8787"
$Port    = 8787

function Get-CurrentUrl {
  $c = Get-Content $Client -Raw -Encoding UTF8
  if ($c -match "export const SUPABASE_URL: string = '([^']*)';") { return $matches[1] }
  return ""
}

function Set-CurrentUrl([string]$url) {
  $c = Get-Content $Client -Raw -Encoding UTF8
  $new = [regex]::Replace($c, "export const SUPABASE_URL: string = '[^']*';", "export const SUPABASE_URL: string = '$url';")
  if ($new -ne $c) {
    [IO.File]::WriteAllText($Client, $new, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "  SUPABASE_URL -> $url"
  } else {
    Write-Host "  SUPABASE_URL 已经是 $url"
  }
}

function Get-ProxyPid {
  $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
  if ($conn) { return @($conn)[0].OwningProcess }
  return 0
}

function Start-Proxy {
  $exists = Get-ProxyPid
  if ($exists -ne 0) { Write-Host "  代理已在运行（pid $exists）"; return }
  $py = Get-Command py -ErrorAction SilentlyContinue
  if (-not $py) { $py = Get-Command python -ErrorAction SilentlyContinue }
  if (-not $py) { throw "找不到 Python（py / python），装一个再试。" }
  # 不用 Start-Process：某些环境里同时存在 HTTPS_PROXY / https_proxy 会让它报
  # "字典中的关键字已添加"。直接用 .NET 起进程，绕开这个坑。
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $py.Source
  $psi.Arguments = '"' + (Join-Path $PSScriptRoot "dev_proxy.py") + '"'
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.WorkingDirectory = $Root
  [System.Diagnostics.Process]::Start($psi) | Out-Null
  for ($i = 0; $i -lt 25; $i++) {
    Start-Sleep -Milliseconds 300
    $pid2 = Get-ProxyPid
    if ($pid2 -ne 0) { Write-Host "  代理已启动（pid $pid2，监听 $Port）"; return }
  }
  throw "代理没起来，检查 $Port 端口是否被别的程序占了。"
}

function Stop-Proxy {
  $p = Get-ProxyPid
  if ($p -eq 0) { Write-Host "  代理本来就没在跑"; return }
  Stop-Process -Id $p -Force -ErrorAction SilentlyContinue
  Write-Host "  代理已停止（pid $p）"
}

function Test-Proxy {
  # 随便打一个 Supabase 路径：拿到任何 HTTP 状态码（包括 401）都说明链路通了
  try {
    $req = [System.Net.WebRequest]::Create("http://127.0.0.1:8787/rest/v1/")
    $req.Timeout = 8000
    $resp = $req.GetResponse()
    $code = [int]$resp.StatusCode
    $resp.Close()
    return $code
  } catch [System.Net.WebException] {
    if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode }
    return -1
  }
}

if ($Mode -eq 'status') {
  Write-Host ("当前 SUPABASE_URL：" + (Get-CurrentUrl))
  $p = Get-ProxyPid
  if ($p -eq 0) { Write-Host "本机代理：未运行" } else { Write-Host "本机代理：运行中（pid $p）" }
  return
}

Write-Host ("== 切换到 " + $Mode)
if ($Mode -eq 'on') {
  Set-CurrentUrl $DevUrl
  Start-Proxy
  $code = Test-Proxy
  if ($code -eq 401 -or $code -eq 200) {
    Write-Host "  代理自检通过（HTTP $code，能连到 Supabase）"
  } else {
    Write-Host "  [警告] 代理自检失败（返回 $code），先别急着登录，看看 $Port 端口和网络。"
  }
} else {
  Stop-Proxy
  Set-CurrentUrl $ProdUrl
}

Write-Host "== 重新构建并安装"
$runParams = @{}
if ($Device) { $runParams['Device'] = $Device }
& (Join-Path $PSScriptRoot "run.ps1") @runParams

if ($Mode -eq 'on') {
  Write-Host ""
  Write-Host "现在可以登录了。注意：这只在本地联调有效，演示/交付前记得执行 tools\dev-proxy.cmd off 还原地址。"
}
