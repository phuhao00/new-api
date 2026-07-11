#Requires -Version 5.1
<#
.SYNOPSIS
  new-api 一键部署 / 启动脚本（Windows）

.DESCRIPTION
  支持两种模式：
    local  - 本地 SQLite + Redis + Go 后端 + 前端开发服务（默认）
    docker - Docker Compose 生产镜像一键拉起

.EXAMPLE
  .\scripts\deploy.ps1
  .\scripts\deploy.ps1 -Mode local
  .\scripts\deploy.ps1 -Mode docker
  .\scripts\deploy.ps1 -Stop
  .\scripts\deploy.ps1 -Mode docker -Stop
#>
[CmdletBinding()]
param(
  [ValidateSet('local', 'docker')]
  [string]$Mode = 'local',

  [switch]$Stop,

  [int]$ApiPort = 0,

  [int]$WebPort = 5173,

  [int]$RedisPort = 6379
)

$ErrorActionPreference = 'Stop'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..')
$PidFile = Join-Path $Root '.local-deploy.pids'
$EnvFile = Join-Path $Root '.env'
$LogDir = Join-Path $Root 'logs'
$DataDir = Join-Path $Root 'data'

function Write-Step([string]$Message) {
  Write-Host "[deploy] $Message" -ForegroundColor Cyan
}

function Write-Ok([string]$Message) {
  Write-Host "[ok] $Message" -ForegroundColor Green
}

function Write-Warn([string]$Message) {
  Write-Host "[warn] $Message" -ForegroundColor Yellow
}

function Refresh-Path {
  $machine = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
  $user = [System.Environment]::GetEnvironmentVariable('Path', 'User')
  $env:Path = "$machine;$user;C:\Program Files\Go\bin;C:\Users\$env:USERNAME\.bun\bin;$env:Path"
}

function Test-Command([string]$Name) {
  return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-ListeningPid([int]$Port) {
  $lines = & "$env:SystemRoot\System32\netstat.exe" -ano 2>$null | Select-String "LISTENING" | Select-String ":$Port "
  foreach ($line in $lines) {
    if ($line -match '\s+(\d+)\s*$') {
      return [int]$Matches[1]
    }
  }
  return $null
}

function Stop-Port([int]$Port) {
  $pidOnPort = Get-ListeningPid $Port
  if ($pidOnPort) {
    Stop-Process -Id $pidOnPort -Force -ErrorAction SilentlyContinue
    Write-Step "已释放端口 $Port (PID $pidOnPort)"
  }
}

function Ensure-EnvFile([int]$Port) {
  if (Test-Path $EnvFile) {
    return
  }

  Write-Step "未找到 .env，正在生成本地默认配置..."
  @"
# 由 scripts/deploy.ps1 自动生成
PORT=$Port

# SQLite（不设置 SQL_DSN 即使用 SQLite）
SQLITE_PATH=one-api.db?_busy_timeout=30000

# Redis 缓存
REDIS_CONN_STRING=redis://localhost:$RedisPort/0
MEMORY_CACHE_ENABLED=true
SYNC_FREQUENCY=60
BATCH_UPDATE_ENABLED=true
"@ | Set-Content -Path $EnvFile -Encoding utf8
  Write-Ok "已创建 $EnvFile"
}

function Ensure-EmbedPlaceholders {
  $targets = @(
    (Join-Path $Root 'web\default\dist'),
    (Join-Path $Root 'web\classic\dist')
  )
  foreach ($dir in $targets) {
    if (-not (Test-Path $dir)) {
      New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $index = Join-Path $dir 'index.html'
    if (-not (Test-Path $index)) {
      Set-Content -Path $index -Value '<!doctype html><html><body>new-api</body></html>' -Encoding utf8
    }
  }
}

function Ensure-NodeModulesJunction {
  $defaultNm = Join-Path $Root 'web\default\node_modules'
  $rootNm = Join-Path $Root 'web\node_modules'
  if ((Test-Path $rootNm) -and -not (Test-Path $defaultNm)) {
    New-Item -ItemType Junction -Path $defaultNm -Target $rootNm | Out-Null
    Write-Step "已创建 web/default/node_modules 链接"
  }
}

function Save-Pids([hashtable]$Map) {
  $lines = @()
  foreach ($key in $Map.Keys) {
    $lines += "$key=$($Map[$key])"
  }
  Set-Content -Path $PidFile -Value $lines -Encoding utf8
}

function Read-Pids {
  $map = @{}
  if (-not (Test-Path $PidFile)) {
    return $map
  }
  Get-Content $PidFile | ForEach-Object {
    if ($_ -match '^([^=]+)=(\d+)$') {
      $map[$Matches[1]] = [int]$Matches[2]
    }
  }
  return $map
}

function Test-PortOpen([int]$Port) {
  try {
    $client = New-Object System.Net.Sockets.TcpClient
    $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
    $ok = $iar.AsyncWaitHandle.WaitOne(1000, $false)
    if (-not $ok) {
      $client.Close()
      return $false
    }
    $client.EndConnect($iar)
    $client.Close()
    return $true
  } catch {
    return $false
  }
}

function Test-HttpOk([string]$Url) {
  try {
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = 'GET'
    $req.Timeout = 2000
    $req.ReadWriteTimeout = 2000
    $resp = $req.GetResponse()
    $code = [int]$resp.StatusCode
    $resp.Close()
    return ($code -ge 200 -and $code -lt 500)
  } catch {
    return $false
  }
}

function Stop-Local {
  Write-Step "停止本地服务..."
  $pids = Read-Pids
  foreach ($name in @('api', 'web', 'redis')) {
    if ($pids.ContainsKey($name)) {
      Stop-Process -Id $pids[$name] -Force -ErrorAction SilentlyContinue
    }
  }

  # 仅结束本仓库相关进程，避免误杀其他占用 3000 的项目
  Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
      $_.CommandLine -and (
        ($_.CommandLine -match 'go run main\.go' -and $_.CommandLine -match [regex]::Escape($Root)) -or
        ($_.CommandLine -match 'main\.exe' -and $_.CommandLine -match 'go-build|cursor-sandbox-cache') -or
        ($_.CommandLine -match 'rsbuild' -and $_.CommandLine -match [regex]::Escape((Join-Path $Root 'web'))) -or
        ($_.CommandLine -match 'redis-server' -and $_.CommandLine -match "--port $RedisPort")
      )
    } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

  $portToFree = $ApiPort
  if ($portToFree -le 0 -and (Test-Path $EnvFile)) {
    $portLine = Get-Content $EnvFile | Where-Object { $_ -match '^\s*PORT\s*=' } | Select-Object -First 1
    if ($portLine -match 'PORT\s*=\s*(\d+)') {
      $portToFree = [int]$Matches[1]
    }
  }
  if ($portToFree -le 0) {
    $portToFree = 3001
  }
  # 不要默认清扫 3000，避免误杀其他项目
  $apiPid = Get-ListeningPid $portToFree
  if ($apiPid) {
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$apiPid" -ErrorAction SilentlyContinue
    if ($proc -and $proc.CommandLine -and (
      $proc.CommandLine -match 'go-build|cursor-sandbox-cache|go run main' -or
      $proc.Name -match 'main|go'
    )) {
      Stop-Process -Id $apiPid -Force -ErrorAction SilentlyContinue
      Write-Step "已释放端口 $portToFree (PID $apiPid)"
    }
  }

  $webPid = Get-ListeningPid $WebPort
  if ($webPid) {
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$webPid" -ErrorAction SilentlyContinue
    if ($proc -and $proc.CommandLine -and $proc.CommandLine -match 'rsbuild') {
      Stop-Process -Id $webPid -Force -ErrorAction SilentlyContinue
      Write-Step "已释放端口 $WebPort (PID $webPid)"
    }
  }

  $redisPid = Get-ListeningPid $RedisPort
  if ($redisPid) {
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$redisPid" -ErrorAction SilentlyContinue
    if ($proc -and $proc.Name -match 'redis') {
      Stop-Process -Id $redisPid -Force -ErrorAction SilentlyContinue
      Write-Step "已释放端口 $RedisPort (PID $redisPid)"
    }
  }

  if (Test-Path $PidFile) {
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
  }
  Write-Ok "本地服务已停止"
}

function Stop-Docker {
  Write-Step "停止 Docker Compose 服务..."
  Push-Location $Root
  try {
    if (Test-Command 'docker') {
      docker compose down
      Write-Ok "Docker 服务已停止"
    } else {
      throw "未找到 docker 命令"
    }
  } finally {
    Pop-Location
  }
}

function Start-Docker {
  Refresh-Path
  if (-not (Test-Command 'docker')) {
    throw "未安装 Docker。请先安装 Docker Desktop，或改用: .\scripts\deploy.ps1 -Mode local"
  }

  New-Item -ItemType Directory -Force -Path $DataDir, $LogDir | Out-Null
  Write-Step "启动 Docker Compose（镜像 calciumion/new-api:latest）..."
  Push-Location $Root
  try {
    docker compose up -d
    Write-Step "等待服务就绪..."
    $ok = $false
    for ($i = 0; $i -lt 60; $i++) {
      Start-Sleep -Seconds 2
      if ((Test-PortOpen 3000) -and (Test-HttpOk 'http://127.0.0.1:3000/api/status')) {
        $ok = $true
        break
      }
    }
    if ($ok) {
      Write-Ok "部署成功"
      Write-Host ""
      Write-Host "  访问地址: http://localhost:3000/" -ForegroundColor Green
      Write-Host "  数据目录: $DataDir" -ForegroundColor DarkGray
      Write-Host "  停止服务: .\scripts\deploy.ps1 -Mode docker -Stop" -ForegroundColor DarkGray
    } else {
      Write-Warn "容器已启动，但健康检查尚未通过，请稍后访问 http://localhost:3000/"
      docker compose ps
    }
  } finally {
    Pop-Location
  }
}

function Resolve-ApiPort {
  if ($ApiPort -gt 0) {
    return $ApiPort
  }
  if (Test-Path $EnvFile) {
    $portLine = Get-Content $EnvFile | Where-Object { $_ -match '^\s*PORT\s*=' } | Select-Object -First 1
    if ($portLine -match 'PORT\s*=\s*(\d+)') {
      return [int]$Matches[1]
    }
  }
  $busy = Get-ListeningPid 3000
  if ($busy) {
    Write-Warn "端口 3000 已被占用，改用 3001"
    return 3001
  }
  return 3000
}

function Start-Local {
  Refresh-Path

  if (-not (Test-Command 'go')) {
    throw "未找到 go，请先安装 Go 1.22+"
  }
  if (-not (Test-Command 'bun')) {
    throw "未找到 bun，请先安装: irm bun.sh/install.ps1 | iex"
  }
  if (-not (Test-Command 'redis-server')) {
    throw "未找到 redis-server。可用 winget 安装: winget install taizod1024.redis-windows-fork"
  }

  $port = Resolve-ApiPort
  Ensure-EnvFile $port
  Ensure-EmbedPlaceholders
  New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

  # 前端依赖
  $webRoot = Join-Path $Root 'web'
  if (-not (Test-Path (Join-Path $webRoot 'node_modules'))) {
    Write-Step "安装前端依赖..."
    Push-Location $webRoot
    try {
      bun install --registry https://registry.npmmirror.com
    } finally {
      Pop-Location
    }
  }
  Ensure-NodeModulesJunction

  Stop-Local | Out-Null
  Start-Sleep -Seconds 1

  Write-Step "启动 Redis (:$RedisPort)..."
  $redisDir = Split-Path (Get-Command redis-server).Source
  $redisProc = Start-Process -FilePath 'redis-server' -ArgumentList "--port $RedisPort" -WorkingDirectory $redisDir -WindowStyle Hidden -PassThru

  Write-Step "启动后端 API (:$port)..."
  $apiOut = Join-Path $LogDir 'api.out.log'
  $apiErr = Join-Path $LogDir 'api.err.log'
  $prevPort = $env:PORT
  $prevProxy = $env:GOPROXY
  $env:PORT = "$port"
  $env:GOPROXY = 'https://goproxy.cn,direct'
  $apiProc = Start-Process -FilePath 'go' `
    -ArgumentList @('run', 'main.go') `
    -WorkingDirectory $Root `
    -WindowStyle Hidden `
    -RedirectStandardOutput $apiOut `
    -RedirectStandardError $apiErr `
    -PassThru
  if ($null -ne $prevPort) { $env:PORT = $prevPort } else { Remove-Item Env:PORT -ErrorAction SilentlyContinue }
  if ($null -ne $prevProxy) { $env:GOPROXY = $prevProxy } else { Remove-Item Env:GOPROXY -ErrorAction SilentlyContinue }

  Write-Step "启动前端 (:$WebPort)..."
  $webOut = Join-Path $LogDir 'web.out.log'
  $webErr = Join-Path $LogDir 'web.err.log'
  $webDir = Join-Path $Root 'web\default'
  $prevServer = $env:VITE_REACT_APP_SERVER_URL
  $env:VITE_REACT_APP_SERVER_URL = "http://localhost:$port"
  $webProc = Start-Process -FilePath 'bun' `
    -ArgumentList @('run', 'dev', '--', '--host', '0.0.0.0', '--port', "$WebPort") `
    -WorkingDirectory $webDir `
    -WindowStyle Hidden `
    -RedirectStandardOutput $webOut `
    -RedirectStandardError $webErr `
    -PassThru
  if ($null -ne $prevServer) { $env:VITE_REACT_APP_SERVER_URL = $prevServer } else { Remove-Item Env:VITE_REACT_APP_SERVER_URL -ErrorAction SilentlyContinue }

  Save-Pids @{
    redis = $redisProc.Id
    api   = $apiProc.Id
    web   = $webProc.Id
  }

  Write-Step "等待服务就绪..."
  $apiOk = $false
  $webOk = $false
  for ($i = 0; $i -lt 90; $i++) {
    Start-Sleep -Seconds 1
    if (-not $apiOk) {
      if ((Test-PortOpen $port) -and (Test-HttpOk "http://127.0.0.1:$port/api/status")) {
        $apiOk = $true
      }
    }
    if (-not $webOk) {
      if ((Test-PortOpen $WebPort) -and (Test-HttpOk "http://127.0.0.1:$WebPort/")) {
        $webOk = $true
      }
    }
    if ($apiOk -and $webOk) { break }
  }

  if ($apiOk -and $webOk) {
    Write-Ok "本地部署成功"
  } else {
    Write-Warn "进程已启动，但部分服务尚未就绪，请查看 logs/ 目录日志"
  }

  Write-Host ""
  Write-Host "  前端:  http://localhost:$WebPort/" -ForegroundColor Green
  Write-Host "  后端:  http://localhost:$port/" -ForegroundColor Green
  Write-Host "  Redis: localhost:$RedisPort" -ForegroundColor Green
  Write-Host "  停止:  .\scripts\deploy.ps1 -Stop" -ForegroundColor DarkGray
  Write-Host "  日志:  $LogDir" -ForegroundColor DarkGray
}

# --- main ---
Set-Location $Root
Refresh-Path

if ($Stop) {
  if ($Mode -eq 'docker') {
    Stop-Docker
  } else {
    Stop-Local
  }
  exit 0
}

switch ($Mode) {
  'docker' { Start-Docker }
  'local' { Start-Local }
}
