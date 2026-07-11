#Requires -Version 5.1
# scripts/ 目录下的启动入口
[CmdletBinding()]
param(
  [int]$ApiPort = 0,
  [int]$WebPort = 5173,
  [int]$RedisPort = 6379
)

$ErrorActionPreference = 'Stop'
$DeployScript = Join-Path $PSScriptRoot 'deploy.ps1'
$params = @{
  Mode = 'local'
  WebPort = $WebPort
  RedisPort = $RedisPort
}
if ($ApiPort -gt 0) {
  $params.ApiPort = $ApiPort
}
& $DeployScript @params
