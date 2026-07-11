#Requires -Version 5.1
<#
.SYNOPSIS
  new-api 一键启动（本地开发栈）

.DESCRIPTION
  启动 Redis + Go 后端 + 前端开发服务。
  等价于: .\scripts\deploy.ps1 -Mode local

.EXAMPLE
  .\start.ps1
  .\scripts\start.ps1
#>
[CmdletBinding()]
param(
  [int]$ApiPort = 0,
  [int]$WebPort = 5173,
  [int]$RedisPort = 6379
)

$ErrorActionPreference = 'Stop'

if (Test-Path (Join-Path $PSScriptRoot 'scripts\deploy.ps1')) {
  $DeployScript = Join-Path $PSScriptRoot 'scripts\deploy.ps1'
} elseif (Test-Path (Join-Path $PSScriptRoot 'deploy.ps1')) {
  $DeployScript = Join-Path $PSScriptRoot 'deploy.ps1'
} else {
  throw "未找到 deploy.ps1，请在仓库根目录执行。"
}

$params = @{
  Mode = 'local'
  WebPort = $WebPort
  RedisPort = $RedisPort
}
if ($ApiPort -gt 0) {
  $params.ApiPort = $ApiPort
}

& $DeployScript @params
