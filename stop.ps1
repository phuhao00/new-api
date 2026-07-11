#Requires -Version 5.1
<#
.SYNOPSIS
  new-api 一键停止本地服务

.EXAMPLE
  .\stop.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

if (Test-Path (Join-Path $PSScriptRoot 'scripts\deploy.ps1')) {
  $DeployScript = Join-Path $PSScriptRoot 'scripts\deploy.ps1'
} elseif (Test-Path (Join-Path $PSScriptRoot 'deploy.ps1')) {
  $DeployScript = Join-Path $PSScriptRoot 'deploy.ps1'
} else {
  throw "未找到 deploy.ps1，请在仓库根目录执行。"
}

& $DeployScript -Mode local -Stop
