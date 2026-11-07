# connect.ps1 — 客户机接入（Windows）
param(
  [string]$Key = "",
  [int]$Ttl = 14400
)
$ErrorActionPreference = "Stop"
$repo = "liuzekun666393/xy-hub"
$dir  = Join-Path $env:TEMP "xy_boot"
New-Item -ItemType Directory -Force -Path $dir | Out-Null

if (-not $Key) {
  $bytes = New-Object byte[] 16
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  $Key = ($bytes | ForEach-Object { $_.ToString("x2") }) -join ""
}

$ProgressPreference = 'Continue'
$bases = @(
  "https://raw.githubusercontent.com/$repo/main",
  "https://gh-proxy.com/https://raw.githubusercontent.com/$repo/main",
  "https://ghproxy.net/https://raw.githubusercontent.com/$repo/main",
  "https://cdn.jsdelivr.net/gh/$repo@main"
)

Write-Output "STEP=download_core"
$core = Join-Path $dir "connect_core.py"
$ok = $false
foreach ($b in $bases) {
  try {
    Invoke-WebRequest -UseBasicParsing -TimeoutSec 30 -Uri "$b/connect_core.py" -OutFile $core
    if ((Get-Item $core).Length -gt 0) { $ok = $true; break }
  } catch { }
}
if (-not $ok) { Write-Output "ERR=download_core"; exit 1 }

$py = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $py) { $py = (Get-Command py -ErrorAction SilentlyContinue).Source }
if (-not $py) { Write-Output "ERR=no_python"; exit 1 }

$out = Join-Path $dir "core.out"
$err = Join-Path $dir "core.err"
$p = Start-Process -FilePath $py -ArgumentList @("`"$core`"", "--key", $Key, "--port", "0", "--ttl", "$Ttl", "--root", "$env:USERPROFILE") -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 2

$port = $null
if (Test-Path $out) {
  $m = Select-String -Path $out -Pattern '"port":\s*(\d+)' | Select-Object -First 1
  if ($m) { $port = $m.Matches[0].Groups[1].Value }
}
if (-not $port) { Write-Output "ERR=core_start"; exit 1 }

Write-Output "PORT=$port"
Write-Output "KEY=$Key"

$cf = (Get-Command cloudflared -ErrorAction SilentlyContinue).Source
if (-not $cf) {
  $cf = Join-Path $dir "cloudflared.exe"
  if (-not (Test-Path $cf)) {
    Write-Output "STEP=download_cloudflared"
    $gh = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe"
    foreach ($u in @($gh, "https://gh-proxy.com/$gh", "https://ghproxy.net/$gh")) {
      Write-Output "TRY=$u"
      try {
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 900 -Uri $u -OutFile $cf
        if ((Get-Item $cf).Length -gt 0) { break }
      } catch { }
    }
  }
  if (-not (Test-Path $cf)) { Write-Output "ERR=no_cloudflared"; exit 1 }
}

Write-Output "STEP=tunnel"
$log = Join-Path $dir "cf.log"
$cfp = Start-Process -FilePath $cf -ArgumentList @("tunnel", "--url", "http://127.0.0.1:$port", "--no-autoupdate", "--logfile", $log) -PassThru -WindowStyle Hidden

$host_ = $null
for ($i = 0; $i -lt 90; $i++) {
  Start-Sleep -Seconds 1
  if (Test-Path $log) {
    $m = Select-String -Path $log -Pattern 'https://[a-z0-9-]+\.trycloudflare\.com' | Select-Object -First 1
    if ($m) { $host_ = $m.Matches[0].Value; break }
  }
}
if (-not $host_) { Write-Output "ERR=no_tunnel"; exit 1 }

Write-Output "URL=$host_"
Write-Output "TTL=$Ttl"
