# connect.ps1 — 客户机一键接入（Windows）
# 用法（客户只跑这一行）：
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "iwr -UseBasicParsing $u/connect.ps1 -OutFile $env:TEMP\xy.ps1; & $env:TEMP\xy.ps1"
# 做的事：选线路 → 下内核 → 起本地终端 → cloudflared 临时隧道 → 打印配对串 xy1://HOST/KEY
param(
  [string]$Key = "",
  [int]$Ttl = 14400,
  [string]$Root = "$env:USERPROFILE",
  [switch]$NoTunnel
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) xy-boot/2"

# ---- 线路表（与 relay.json 同步；自建反代上线后把它放第一位） ----
$Repo = "liuzekun666393/xy-hub"          # ← 改成实际 GitHub 仓库，如 someone/xy-hub
$Lines = @(
  @{ id = "self";  tpl = "https://xy.example.com/{path}" },
  @{ id = "ghproxy"; tpl = "https://ghproxy.net/https://raw.githubusercontent.com/$Repo/main/{path}" },
  @{ id = "ghfast";  tpl = "https://ghfast.top/https://raw.githubusercontent.com/$Repo/main/{path}" },
  @{ id = "jsdelivr";tpl = "https://cdn.jsdelivr.net/gh/$Repo@main/{path}" },
  @{ id = "raw";     tpl = "https://raw.githubusercontent.com/$Repo/main/{path}" }
)

function Get-Url([string]$tpl, [string]$path) { $tpl -replace "\{path\}", $path }
function Get-File([string]$path, [string]$out) {
  foreach ($l in $Lines) {
    $u = Get-Url $l.tpl $path
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
      Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile $out -Headers @{ "User-Agent" = $UA } -TimeoutSec 25
      if ((Get-Item $out).Length -gt 0) {
        $sw.Stop()
        Write-Host ("[line] {0} {1}ms {2}" -f $l.id, $sw.ElapsedMilliseconds, $path) -ForegroundColor DarkGray
        return $u
      }
    } catch {
      Write-Host ("[line] {0} 失败: {1}" -f $l.id, $_.Exception.Message) -ForegroundColor DarkYellow
    }
    $sw.Stop()
  }
  throw "所有线路都拉不到 $path —— 让客户换个网络或用手机热点再试"
}

function New-Key {
  $b = New-Object byte[] 16
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
  ($b | ForEach-Object { $_.ToString("x2") }) -join ""
}

if (-not $Key) { $Key = New-Key }
$Work = Join-Path $env:TEMP "xy_boot"
New-Item -ItemType Directory -Force -Path $Work | Out-Null

Write-Host "== 闲鱼装机器 · 接入 ==" -ForegroundColor Cyan
Write-Host "工作目录 $Work"

# ---- 1. 内核 ----
$core = Join-Path $Work "connect_core.py"
Get-File "bootstrap/connect_core.py" $core | Out-Null

# ---- 2. python ----
$py = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $py) { $py = (Get-Command py -ErrorAction SilentlyContinue).Source }
if (-not $py) {
  Write-Host "没找到 Python，正在装（winget）..." -ForegroundColor Yellow
  try { winget install -e --id Python.Python.3.12 --accept-source-agreements --accept-package-agreements | Out-Null } catch {}
  $py = (Get-Command python -ErrorAction SilentlyContinue).Source
  if (-not $py) { throw "Python 装不上，让客户手动装一下 https://www.python.org/downloads/ 再跑一次" }
}
Write-Host "python: $py"

# ---- 3. 起本地终端 ----
$coreOut = Join-Path $Work "core.out"
$coreErr = Join-Path $Work "core.err"
if (Test-Path $coreOut) { Remove-Item $coreOut -Force }
$args = @($core, "--key", $Key, "--port", "0", "--ttl", "$Ttl", "--root", $Root)
$p = Start-Process -FilePath $py -ArgumentList $args -WorkingDirectory $Work -PassThru -WindowStyle Hidden `
  -RedirectStandardOutput $coreOut -RedirectStandardError $coreErr
Start-Sleep -Seconds 2
$port = $null
for ($i = 0; $i -lt 20; $i++) {
  if (Test-Path $coreOut) {
    $line = (Get-Content $coreOut -Raw -ErrorAction SilentlyContinue)
    if ($line -match '"port":\s*(\d+)') { $port = [int]$Matches[1]; break }
  }
  Start-Sleep -Milliseconds 500
}
if (-not $port) {
  Get-Content $coreErr -ErrorAction SilentlyContinue | Select-Object -Last 5 | Write-Host -ForegroundColor Red
  throw "本地终端没起来（看上面报错）"
}
Write-Host "本地终端: 127.0.0.1:$port  root=$Root"
$ping = Invoke-RestMethod -Uri "http://127.0.0.1:$port/ping" -Headers @{ "X-Key" = $Key } -TimeoutSec 10
Write-Host "自检: host=$($ping.host) ttl_left=$($ping.ttl_left)s"

# ---- 4. 隧道 ----
if ($NoTunnel) {
  Write-Host "已跳过隧道（本地调试）。配对: xy0://127.0.0.1:$port/$Key" -ForegroundColor Green
  return
}
$cf = Join-Path $Work "cloudflared.exe"
if (-not (Test-Path $cf)) { Get-File "bootstrap/bin/cloudflared-windows-amd64.exe" $cf | Out-Null }
$cfLog = Join-Path $Work "cloudflared.log"
if (Test-Path $cfLog) { Remove-Item $cfLog -Force }
$cfp = Start-Process -FilePath $cf -ArgumentList @("tunnel", "--url", "http://127.0.0.1:$port",
    "--no-autoupdate", "--logfile", $cfLog, "--loglevel", "info") -PassThru -WindowStyle Hidden

$host_ = $null
for ($i = 0; $i -lt 60; $i++) {
  Start-Sleep -Seconds 1
  if (Test-Path $cfLog) {
    $txt = Get-Content $cfLog -Raw -ErrorAction SilentlyContinue
    if ($txt -match "https://([a-z0-9-]+\.trycloudflare\.com)") { $host_ = $Matches[1]; break }
  }
}
if (-not $host_) {
  Write-Host "隧道没起来，日志尾部：" -ForegroundColor Red
  Get-Content $cfLog -ErrorAction SilentlyContinue | Select-Object -Last 10 | Write-Host
  throw "cloudflared 启动失败（多半是网络；让客户用手机热点再跑一次）"
}

$pair = "xy1://$host_/$Key"
Write-Host ""
Write-Host "==== 把下面这一行原样发我 ====" -ForegroundColor Green
Write-Host $pair -ForegroundColor Green
Write-Host "==============================" -ForegroundColor Green
Write-Host "有效期 $([int]($Ttl/3600)) 小时；装完我会关掉。关掉窗口即断开。" -ForegroundColor DarkGray

# ---- 5. 守到内核退出 ----
try {
  $p.WaitForExit()
} finally {
  if ($cfp -and -not $cfp.HasExited) { Stop-Process -Id $cfp.Id -Force -ErrorAction SilentlyContinue }
  Write-Host "会话结束，隧道已关闭。" -ForegroundColor Yellow
}
