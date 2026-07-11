#Requires -Version 5.1
<#
.SYNOPSIS
  new-api 一键部署 / 启动脚本（Windows）

.DESCRIPTION
  支持两种模式：
    local  - 本地 SQLite + Redis + Go 后端 + 前端开发服务（默认）
    docker - Docker Compose 生产镜像一键拉起

  本地模式会：
    1. 检测并自动安装缺失依赖（Go / Bun / Redis / 前端 node_modules / Go modules）
    2. 强制释放项目所需端口上的占用进程，确保可以启动

.EXAMPLE
  .\scripts\deploy.ps1
  .\scripts\deploy.ps1 -Mode local
  .\scripts\deploy.ps1 -Mode docker
  .\scripts\deploy.ps1 -Stop
#>
[CmdletBinding()]
param(
  [ValidateSet('local', 'docker')]
  [string]$Mode = 'local',

  [switch]$Stop,

  [int]$ApiPort = 0,

  [int]$WebPort = 5173,

  [int]$RedisPort = 6379,

  # 启动前强制杀掉占用所需端口的进程（默认开启）
  [bool]$ForceFreePorts = $true
)

$ErrorActionPreference = 'Stop'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..')
$PidFile = Join-Path $Root '.local-deploy.pids'
$EnvFile = Join-Path $Root '.env'
$LogDir = Join-Path $Root 'logs'
$DataDir = Join-Path $Root 'data'
$Winget = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'

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
  $bunBin = Join-Path $env:USERPROFILE '.bun\bin'
  $goBin = 'C:\Program Files\Go\bin'
  $env:Path = "$machine;$user;$goBin;$bunBin;$env:Path"
}

function Test-Command([string]$Name) {
  return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-ListeningPids([int]$Port) {
  $pids = New-Object System.Collections.Generic.HashSet[int]
  $lines = & "$env:SystemRoot\System32\netstat.exe" -ano 2>$null |
    Select-String "LISTENING" |
    Select-String ":$Port\s"
  foreach ($line in $lines) {
    if ($line -match '\s+(\d+)\s*$') {
      [void]$pids.Add([int]$Matches[1])
    }
  }
  return @($pids)
}

function Get-ListeningPid([int]$Port) {
  $list = Get-ListeningPids $Port
  if ($list.Count -gt 0) { return $list[0] }
  return $null
}

function Get-ProcessLabel([int]$ProcessId) {
  $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
  if (-not $proc) { return "pid=$ProcessId" }
  $name = $proc.Name
  $cmd = $proc.CommandLine
  if ($cmd -and $cmd.Length -gt 80) { $cmd = $cmd.Substring(0, 80) + '...' }
  if ($cmd) { return "$name ($cmd)" }
  return $name
}

function Stop-ProcessTree([int]$ProcessId) {
  if ($ProcessId -le 0) { return }
  # /T 结束子进程树，避免 go run 残留 main.exe
  & "$env:SystemRoot\System32\taskkill.exe" /F /T /PID $ProcessId 2>$null | Out-Null
  Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

function Clear-PortForce([int]$Port, [string]$Role) {
  $pids = Get-ListeningPids $Port
  if ($pids.Count -eq 0) { return }

  foreach ($pidOnPort in $pids) {
    $label = Get-ProcessLabel $pidOnPort
    Write-Warn "端口 $Port ($Role) 被占用: $label — 正在结束进程 $pidOnPort"
    Stop-ProcessTree $pidOnPort
  }

  Start-Sleep -Milliseconds 500
  $left = Get-ListeningPids $Port
  if ($left.Count -gt 0) {
    foreach ($pidOnPort in $left) {
      Write-Warn "重试结束端口 $Port 占用进程 $pidOnPort"
      Stop-ProcessTree $pidOnPort
    }
    Start-Sleep -Milliseconds 500
  }

  if ((Get-ListeningPids $Port).Count -gt 0) {
    throw "无法释放端口 $Port ($Role)，请手动结束占用进程后重试"
  }
  Write-Ok "端口 $Port ($Role) 已释放"
}

function Install-WithWinget([string]$PackageId, [string]$DisplayName) {
  if (-not (Test-Path $Winget)) {
    throw "未找到 winget，无法自动安装 $DisplayName。请手动安装后重试。"
  }
  Write-Step "正在通过 winget 安装 $DisplayName ($PackageId)..."
  & $Winget install --id $PackageId -e --accept-package-agreements --accept-source-agreements
  if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
    # -1978335189 = already installed
    throw "winget 安装 $DisplayName 失败 (exit=$LASTEXITCODE)"
  }
  Refresh-Path
}

function Ensure-Go {
  Refresh-Path
  if (Test-Command 'go') {
    Write-Ok "Go: $(go version)"
    return
  }
  Install-WithWinget 'GoLang.Go' 'Go'
  Refresh-Path
  if (-not (Test-Command 'go')) {
    throw "Go 安装后仍未找到 go 命令，请重新打开终端后再运行"
  }
  Write-Ok "Go: $(go version)"
}

function Ensure-Bun {
  Refresh-Path
  if (Test-Command 'bun') {
    Write-Ok "Bun: $(bun --version)"
    return
  }
  Write-Step "正在安装 Bun..."
  try {
    irm https://bun.sh/install.ps1 | iex
  } catch {
    throw "Bun 安装失败: $($_.Exception.Message)"
  }
  Refresh-Path
  if (-not (Test-Command 'bun')) {
    throw "Bun 安装后仍未找到 bun 命令，请重新打开终端后再运行"
  }
  Write-Ok "Bun: $(bun --version)"
}

function Ensure-Redis {
  Refresh-Path
  if (Test-Command 'redis-server') {
    Write-Ok "Redis: $(redis-server --version 2>&1 | Select-Object -First 1)"
    return
  }
  Install-WithWinget 'taizod1024.redis-windows-fork' 'Redis'
  Refresh-Path
  if (-not (Test-Command 'redis-server')) {
    throw "Redis 安装后仍未找到 redis-server，请重新打开终端后再运行"
  }
  Write-Ok "Redis: $(redis-server --version 2>&1 | Select-Object -First 1)"
}

function Ensure-GoModules {
  Write-Step "检查 Go 模块依赖..."
  Push-Location $Root
  try {
    $env:GOPROXY = 'https://goproxy.cn,direct'
    $env:GOSUMDB = 'sum.golang.google.cn'
    go mod download
    Write-Ok "Go 模块依赖就绪"
  } finally {
    Pop-Location
  }
}

function Ensure-WebDependencies {
  $webRoot = Join-Path $Root 'web'
  $nm = Join-Path $webRoot 'node_modules'
  $needInstall = -not (Test-Path $nm)
  if (-not $needInstall) {
    $pkgCount = @(Get-ChildItem $nm -ErrorAction SilentlyContinue).Count
    if ($pkgCount -lt 50) { $needInstall = $true }
  }

  if ($needInstall) {
    Write-Step "安装前端依赖 (bun install)..."
    Push-Location $webRoot
    try {
      bun install --registry https://registry.npmmirror.com
      if ($LASTEXITCODE -ne 0) {
        Write-Warn "npmmirror 安装异常，改用默认 registry 重试..."
        bun pm cache rm 2>$null | Out-Null
        bun install
      }
      if ($LASTEXITCODE -ne 0) {
        throw "前端依赖安装失败"
      }
    } finally {
      Pop-Location
    }
    Write-Ok "前端依赖安装完成"
  } else {
    Write-Ok "前端依赖已存在"
  }

  Ensure-NodeModulesJunction
}

function Ensure-EnvFile([int]$Port) {
  if (Test-Path $EnvFile) { return }

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
  if (-not (Test-Path $PidFile)) { return $map }
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
    $ok = $iar.AsyncWaitHandle.WaitOne(800, $false)
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

function Resolve-ApiPort {
  if ($ApiPort -gt 0) { return $ApiPort }
  if (Test-Path $EnvFile) {
    $portLine = Get-Content $EnvFile | Where-Object { $_ -match '^\s*PORT\s*=' } | Select-Object -First 1
    if ($portLine -match 'PORT\s*=\s*(\d+)') {
      return [int]$Matches[1]
    }
  }
  return 3000
}

function Sync-EnvPort([int]$Port) {
  if (-not (Test-Path $EnvFile)) {
    Ensure-EnvFile $Port
    return
  }
  $lines = Get-Content $EnvFile
  $found = $false
  $newLines = foreach ($line in $lines) {
    if ($line -match '^\s*PORT\s*=') {
      $found = $true
      "PORT=$Port"
    } else {
      $line
    }
  }
  if (-not $found) {
    $newLines = @("PORT=$Port") + $newLines
  }
  Set-Content -Path $EnvFile -Value $newLines -Encoding utf8
}

function Stop-Local {
  Write-Step "停止本地服务..."
  $pids = Read-Pids
  foreach ($name in @('api', 'web', 'redis')) {
    if ($pids.ContainsKey($name)) {
      Stop-ProcessTree $pids[$name]
    }
  }

  Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
      $_.CommandLine -and (
        ($_.CommandLine -match 'go run main\.go' -and $_.CommandLine -match [regex]::Escape([string]$Root)) -or
        ($_.CommandLine -match 'main\.exe' -and $_.CommandLine -match 'go-build|cursor-sandbox-cache') -or
        ($_.CommandLine -match 'rsbuild' -and $_.CommandLine -match [regex]::Escape((Join-Path $Root 'web'))) -or
        ($_.CommandLine -match 'redis-server')
      )
    } |
    ForEach-Object { Stop-ProcessTree $_.ProcessId }

  $port = Resolve-ApiPort
  foreach ($item in @(
      @{ Port = $port; Role = 'API' },
      @{ Port = $WebPort; Role = 'Web' },
      @{ Port = $RedisPort; Role = 'Redis' }
    )) {
    foreach ($pidOnPort in (Get-ListeningPids $item.Port)) {
      Write-Step "停止占用 $($item.Role) 端口 $($item.Port) 的进程 $pidOnPort"
      Stop-ProcessTree $pidOnPort
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

  if ($ForceFreePorts) {
    Clear-PortForce 3000 'Docker-API'
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
      if (Test-PortOpen 3000) {
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

function Start-Local {
  Write-Step "检查并安装依赖..."
  Ensure-Go
  Ensure-Bun
  Ensure-Redis
  Ensure-GoModules
  Ensure-WebDependencies
  Ensure-EmbedPlaceholders
  New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

  $port = Resolve-ApiPort
  Ensure-EnvFile $port
  Sync-EnvPort $port

  Write-Step "清理占用端口，确保可启动 (API=$port Web=$WebPort Redis=$RedisPort)..."
  # 先停本仓库旧进程，再强制清端口
  $oldPids = Read-Pids
  foreach ($name in @('api', 'web', 'redis')) {
    if ($oldPids.ContainsKey($name)) {
      Stop-ProcessTree $oldPids[$name]
    }
  }
  if ($ForceFreePorts) {
    Clear-PortForce $port 'API'
    Clear-PortForce $WebPort 'Web'
    Clear-PortForce $RedisPort 'Redis'
  }

  Write-Step "启动 Redis (:$RedisPort)..."
  $redisCmd = Get-Command redis-server
  $redisDir = Split-Path $redisCmd.Source
  $redisProc = Start-Process -FilePath $redisCmd.Source -ArgumentList "--port $RedisPort" -WorkingDirectory $redisDir -WindowStyle Hidden -PassThru

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
  for ($i = 0; $i -lt 120; $i++) {
    Start-Sleep -Seconds 1
    if (-not $apiOk -and (Test-PortOpen $port)) { $apiOk = $true }
    if (-not $webOk -and (Test-PortOpen $WebPort)) { $webOk = $true }
    if ($apiOk -and $webOk) { break }
  }

  if ($apiOk -and $webOk) {
    Write-Ok "本地部署成功"
  } else {
    Write-Warn "进程已启动，但部分服务尚未就绪，请查看 logs/ 目录日志"
    if (-not $apiOk) { Write-Warn "API 日志: $apiErr" }
    if (-not $webOk) { Write-Warn "Web 日志: $webErr" }
  }

  Write-Host ""
  Write-Host "  前端:  http://localhost:$WebPort/" -ForegroundColor Green
  Write-Host "  后端:  http://localhost:$port/" -ForegroundColor Green
  Write-Host "  Redis: localhost:$RedisPort" -ForegroundColor Green
  Write-Host "  停止:  .\stop.bat   或  .\scripts\deploy.ps1 -Stop" -ForegroundColor DarkGray
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
