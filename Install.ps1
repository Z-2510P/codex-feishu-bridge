[CmdletBinding()]
param(
    [string]$AppId,
    [string]$AppSecret,
    [switch]$NoStartup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sourceRoot = $PSScriptRoot
$targetRoot = Join-Path $env:USERPROFILE '.codex\mobile-notifier'
$targetBridge = Join-Path $targetRoot 'bridge'

New-Item -ItemType Directory -Path $targetBridge -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $targetRoot 'tests') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $targetBridge 'tests') -Force | Out-Null

Copy-Item -LiteralPath (Join-Path $sourceRoot 'CodexFeishuNotifier.ps1') -Destination $targetRoot -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot 'tests\Run-Tests.ps1') -Destination (Join-Path $targetRoot 'tests') -Force
foreach ($name in @('bridge.js', 'bridge-admin.js', 'CodexFeishuBridge.ps1', 'package.json', 'package-lock.json')) {
    Copy-Item -LiteralPath (Join-Path $sourceRoot "bridge\$name") -Destination $targetBridge -Force
}
Copy-Item -LiteralPath (Join-Path $sourceRoot 'bridge\tests\bridge.test.js') -Destination (Join-Path $targetBridge 'tests') -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot 'bridge\tests\bridge-admin.test.js') -Destination (Join-Path $targetBridge 'tests') -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot 'bridge\tests\Run-PowerShellTests.ps1') -Destination (Join-Path $targetBridge 'tests') -Force

$manager = Join-Path $targetBridge 'CodexFeishuBridge.ps1'
$arguments = @{ Action = 'Install' }
if ($AppId) { $arguments.AppId = $AppId }
if ($AppSecret) { $arguments.AppSecret = $AppSecret }
if ($NoStartup) { $arguments.NoStartup = $true }
& $manager @arguments
