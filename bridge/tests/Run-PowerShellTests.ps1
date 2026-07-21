[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$managerPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\CodexFeishuBridge.ps1'))
$testRoot = Join-Path $env:TEMP ('CodexFeishuBridge-ps-tests-' + [Guid]::NewGuid().ToString('N'))
$previousCodexExe = [Environment]::GetEnvironmentVariable('CODEX_EXE')
$passed = 0
$failed = 0

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) {
        $script:passed++
        Write-Host ('PASS  {0}' -f $Name)
    }
    else {
        $script:failed++
        Write-Host ('FAIL  {0}' -f $Name) -ForegroundColor Red
    }
}

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    . $managerPath -Action Library -DataRoot $testRoot

    Save-BridgeCredentials -ClientId 'cli_test123' -ClientSecret 'secret-value'
    $credentials = Get-BridgeCredentials
    Assert-True ($credentials.appId -eq 'cli_test123') 'DPAPI preserves the Feishu App ID'
    Assert-True ($credentials.appSecret -eq 'secret-value') 'DPAPI preserves the Feishu App Secret'
    $protectedRaw = [System.IO.File]::ReadAllText((Get-BridgeManagerPaths).Config)
    Assert-True (-not $protectedRaw.Contains('secret-value')) 'DPAPI file excludes the plaintext App Secret'

    $sampleCode = New-PairingCode
    Assert-True ($sampleCode -match '^[A-Z0-9]{8}$') 'Pairing codes use eight unambiguous characters'
    Invoke-PairAction
    $state = Get-BridgeState
    Assert-True ($state.pairing.hash -match '^[a-f0-9]{64}$') 'State stores a SHA-256 pairing-code hash'
    $pairingProperties = @($state.pairing.PSObject.Properties.Name)
    Assert-True ($pairingProperties.Count -eq 2 -and $pairingProperties -contains 'hash' -and $pairingProperties -contains 'expiresAtUtc') 'State contains no plaintext pairing-code field'
    Assert-True ([DateTimeOffset]$state.pairing.expiresAtUtc -gt [DateTimeOffset]::UtcNow) 'Pairing code has a future expiry'
    $fakeCodex = Join-Path $testRoot 'codex.exe'
    [System.IO.File]::WriteAllBytes($fakeCodex, [byte[]]@(0))
    $env:CODEX_EXE = $fakeCodex
    $codexPath = Get-CodexPath
    Assert-True ((Test-Path -LiteralPath $codexPath -PathType Leaf) -and ([IO.Path]::GetFileName($codexPath) -eq 'codex.exe')) 'Codex executable resolves to a current absolute path'
    Assert-True ($null -eq (Get-BridgePid)) 'No bridge process is reported for an offline test root'

    Write-Host ''
    Write-Host ('Tests passed: {0}; failed: {1}' -f $passed, $failed)
    if ($failed -gt 0) { exit 1 }
}
finally {
    if ([string]::IsNullOrWhiteSpace($previousCodexExe)) {
        Remove-Item Env:CODEX_EXE -ErrorAction SilentlyContinue
    }
    else {
        $env:CODEX_EXE = $previousCodexExe
    }
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = [System.IO.Path]::GetFullPath($testRoot)
        $tempRoot = [System.IO.Path]::GetFullPath($env:TEMP)
        if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and $resolved -like '*CodexFeishuBridge-ps-tests-*') {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}
