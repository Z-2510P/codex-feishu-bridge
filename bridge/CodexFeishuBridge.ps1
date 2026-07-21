[CmdletBinding()]
param(
    [ValidateSet('Install', 'Pair', 'Start', 'Run', 'Stop', 'Status', 'Uninstall', 'Library')]
    [string]$Action = 'Status',

    [string]$AppId,
    [string]$AppSecret,
    [string]$DataRoot,

    [switch]$NoStartup,
    [switch]$RemoveData,
    [switch]$RemoveHook
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Security

if ([string]::IsNullOrWhiteSpace($DataRoot)) {
    $DataRoot = Join-Path $env:LOCALAPPDATA 'CodexFeishuBridge'
}

$script:BridgeScriptPath = $PSCommandPath
$script:BridgeRoot = [System.IO.Path]::GetFullPath($DataRoot)
$script:BridgeDirectory = Split-Path -Parent $script:BridgeScriptPath
$script:NodeScript = Join-Path $script:BridgeDirectory 'bridge.js'
$script:NotifierScript = [System.IO.Path]::GetFullPath((Join-Path $script:BridgeDirectory '..\CodexFeishuNotifier.ps1'))
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:DpapiEntropy = [System.Text.Encoding]::UTF8.GetBytes('CodexFeishuBridge/v1')
$script:StartupRegistryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$script:StartupValueName = 'CodexFeishuBridge'

function Get-BridgeManagerPaths {
    return [pscustomobject][ordered]@{
        Root       = $script:BridgeRoot
        Config     = Join-Path $script:BridgeRoot 'settings.dpapi'
        State      = Join-Path $script:BridgeRoot 'state.json'
        Sessions   = Join-Path $script:BridgeRoot 'sessions'
        Inbox      = Join-Path $script:BridgeRoot 'inbox'
        Outbox     = Join-Path $script:BridgeRoot 'outbox'
        DeadLetter = Join-Path $script:BridgeRoot 'dead-letter'
        Media      = Join-Path $script:BridgeRoot 'media\inbound'
        OutboundMedia = Join-Path $script:BridgeRoot 'media\outbound'
        Logs       = Join-Path $script:BridgeRoot 'logs'
        Pid        = Join-Path $script:BridgeRoot 'bridge.pid'
        Runtime    = Join-Path $script:BridgeRoot 'runtime.json'
        WatchState = Join-Path $script:BridgeRoot 'completion-watch.json'
    }
}

function Initialize-BridgeManagerStorage {
    $paths = Get-BridgeManagerPaths
    foreach ($path in @($paths.Root, $paths.Sessions, $paths.Inbox, $paths.Outbox, $paths.DeadLetter, $paths.Media, $paths.OutboundMedia, $paths.Logs)) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }
}

function Write-Utf8TextAtomic {
    param([string]$Path, [string]$Content)

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $temporary = Join-Path $directory ([System.IO.Path]::GetRandomFileName())
    [System.IO.File]::WriteAllText($temporary, $Content, $script:Utf8NoBom)
    $backup = $null
    try {
        if (Test-Path -LiteralPath $Path) {
            $backup = Join-Path $directory ([System.IO.Path]::GetRandomFileName())
            [System.IO.File]::Replace($temporary, $Path, $backup)
        }
        else {
            [System.IO.File]::Move($temporary, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
        if ($null -ne $backup -and (Test-Path -LiteralPath $backup)) {
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-JsonAtomic {
    param([string]$Path, $Value)
    Write-Utf8TextAtomic -Path $Path -Content ($Value | ConvertTo-Json -Depth 20 -Compress)
}

function Get-ObjectProperty {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Get-Sha256Hex {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) | ForEach-Object { $_.ToString('x2') })
    }
    finally {
        $sha.Dispose()
    }
}

function Convert-SecureStringToPlainText {
    param([Security.SecureString]$SecureValue)
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Save-BridgeCredentials {
    param([string]$ClientId, [string]$ClientSecret)
    Initialize-BridgeManagerStorage
    $value = [ordered]@{ schema = 1; appId = $ClientId; appSecret = $ClientSecret }
    $plainBytes = [Text.Encoding]::UTF8.GetBytes(($value | ConvertTo-Json -Compress))
    try {
        $protected = [Security.Cryptography.ProtectedData]::Protect(
            $plainBytes,
            $script:DpapiEntropy,
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        Write-Utf8TextAtomic -Path (Get-BridgeManagerPaths).Config -Content ([Convert]::ToBase64String($protected))
    }
    finally {
        [Array]::Clear($plainBytes, 0, $plainBytes.Length)
    }
}

function Get-BridgeCredentials {
    $path = (Get-BridgeManagerPaths).Config
    if (-not (Test-Path -LiteralPath $path)) {
        throw 'Bridge credentials are not installed.'
    }
    $protected = [Convert]::FromBase64String([IO.File]::ReadAllText($path, $script:Utf8NoBom).Trim())
    $plainBytes = [Security.Cryptography.ProtectedData]::Unprotect(
        $protected,
        $script:DpapiEntropy,
        [Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    try {
        return ([Text.Encoding]::UTF8.GetString($plainBytes) | ConvertFrom-Json)
    }
    finally {
        [Array]::Clear($plainBytes, 0, $plainBytes.Length)
    }
}

function Get-BridgeState {
    $path = (Get-BridgeManagerPaths).State
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject][ordered]@{
            schema              = 1
            allowedOpenIds      = @()
            defaultChatByUser   = [pscustomobject][ordered]@{}
            activeSessionByUser = [pscustomobject][ordered]@{}
            pairing             = $null
        }
    }
    return [IO.File]::ReadAllText($path, $script:Utf8NoBom) | ConvertFrom-Json
}

function Save-BridgeState {
    param($State)
    Write-JsonAtomic -Path (Get-BridgeManagerPaths).State -Value $State
}

function New-PairingCode {
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $bytes = New-Object byte[] 8
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    }
    finally {
        $rng.Dispose()
    }
    return -join ($bytes | ForEach-Object { $alphabet[[int]($_ % $alphabet.Length)] })
}

function Invoke-PairAction {
    Initialize-BridgeManagerStorage
    $code = New-PairingCode
    $state = Get-BridgeState
    $pairing = [pscustomobject][ordered]@{
        hash         = Get-Sha256Hex $code.ToUpperInvariant()
        expiresAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(15).ToString('o')
    }
    if ($null -eq $state.PSObject.Properties['pairing']) {
        $state | Add-Member -NotePropertyName pairing -NotePropertyValue $pairing
    }
    else {
        $state.pairing = $pairing
    }
    Save-BridgeState -State $state
    Write-Host ''
    Write-Host ('Pairing code: {0}' -f $code) -ForegroundColor Cyan
    Write-Host 'Send this to the Feishu application bot within 15 minutes:'
    Write-Host ('/pair {0}' -f $code) -ForegroundColor Cyan
    Write-Host ''
}

function Get-PowerShellPath {
    return Join-Path $PSHOME 'powershell.exe'
}

function Get-NodePath {
    $command = Get-Command node -ErrorAction Stop
    return $command.Source
}

function Get-CodexPath {
    $configured = [Environment]::GetEnvironmentVariable('CODEX_EXE')
    if (-not [string]::IsNullOrWhiteSpace($configured) -and (Test-Path -LiteralPath $configured -PathType Leaf)) {
        return [System.IO.Path]::GetFullPath($configured)
    }

    $command = Get-Command codex.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
        $command = Get-Command codex -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if ($null -eq $command -or [string]::IsNullOrWhiteSpace([string]$command.Source)) {
        throw 'Could not locate codex.exe. Start Codex Desktop once, then restart the bridge.'
    }
    return [System.IO.Path]::GetFullPath([string]$command.Source)
}

function Get-BridgePid {
    $pidPath = (Get-BridgeManagerPaths).Pid
    if (-not (Test-Path -LiteralPath $pidPath)) { return $null }
    $text = [IO.File]::ReadAllText($pidPath).Trim()
    $value = 0
    if (-not [int]::TryParse($text, [ref]$value)) { return $null }
    $process = Get-Process -Id $value -ErrorAction SilentlyContinue
    if ($null -eq $process -or $process.ProcessName -ne 'node') { return $null }
    return $value
}

function Enable-BridgeStartup {
    $powerShellPath = Get-PowerShellPath
    $command = '"{0}" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" -Action Run -DataRoot "{2}"' -f $powerShellPath, $script:BridgeScriptPath, $script:BridgeRoot
    if (-not (Test-Path -LiteralPath $script:StartupRegistryPath)) {
        New-Item -Path $script:StartupRegistryPath -Force | Out-Null
    }
    Set-ItemProperty -Path $script:StartupRegistryPath -Name $script:StartupValueName -Value $command
}

function Disable-BridgeStartup {
    Remove-ItemProperty -Path $script:StartupRegistryPath -Name $script:StartupValueName -ErrorAction SilentlyContinue
}

function Test-BridgeStartupEnabled {
    try {
        $value = Get-ItemPropertyValue -Path $script:StartupRegistryPath -Name $script:StartupValueName -ErrorAction Stop
        return -not [string]::IsNullOrWhiteSpace([string]$value)
    }
    catch {
        return $false
    }
}

function Invoke-StartAction {
    Initialize-BridgeManagerStorage
    if ($null -ne (Get-BridgePid)) {
        Write-Host 'The Feishu bridge is already running.'
        return
    }
    Get-BridgeCredentials | Out-Null
    $arguments = @(
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle', 'Hidden',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $script:BridgeScriptPath),
        '-Action', 'Run',
        '-DataRoot', ('"{0}"' -f $script:BridgeRoot)
    )
    Start-Process -FilePath (Get-PowerShellPath) -ArgumentList $arguments -WindowStyle Hidden | Out-Null
    Write-Host 'Feishu bridge start requested.'
}

function Invoke-RunAction {
    Initialize-BridgeManagerStorage
    if ($null -ne (Get-BridgePid)) {
        return
    }
    $credentials = Get-BridgeCredentials
    $nodePath = Get-NodePath
    $codexPath = Get-CodexPath
    $env:FEISHU_APP_ID = [string]$credentials.appId
    $env:FEISHU_APP_SECRET = [string]$credentials.appSecret
    $env:CODEX_FEISHU_BRIDGE_DATA_ROOT = $script:BridgeRoot
    $env:CODEX_FEISHU_SESSIONS_DIR = (Get-BridgeManagerPaths).Sessions
    $env:CODEX_EXE = $codexPath
    try {
        & $nodePath $script:NodeScript
        if ($LASTEXITCODE -ne 0) {
            throw ('Bridge process exited with code {0}.' -f $LASTEXITCODE)
        }
    }
    finally {
        Remove-Item Env:FEISHU_APP_ID -ErrorAction SilentlyContinue
        Remove-Item Env:FEISHU_APP_SECRET -ErrorAction SilentlyContinue
        Remove-Item Env:CODEX_EXE -ErrorAction SilentlyContinue
    }
}

function Invoke-StopAction {
    $bridgePid = Get-BridgePid
    if ($null -eq $bridgePid) {
        Write-Host 'The Feishu bridge is not running.'
        return
    }
    Stop-Process -Id $bridgePid -Force
    Write-Host ('Stopped Feishu bridge process {0}.' -f $bridgePid)
}

function Invoke-InstallHook {
    & (Get-PowerShellPath) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:NotifierScript -Action InstallHook
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to install the Codex Stop hook.'
    }
}

function Invoke-InstallAction {
    $clientId = $AppId
    $clientSecret = $AppSecret
    if ([string]::IsNullOrWhiteSpace($clientId)) {
        $clientId = Read-Host 'Feishu application App ID'
    }
    if ([string]::IsNullOrWhiteSpace($clientSecret)) {
        $secureSecret = Read-Host 'Feishu application App Secret' -AsSecureString
        $clientSecret = Convert-SecureStringToPlainText -SecureValue $secureSecret
    }
    if ($clientId -notmatch '^cli_[A-Za-z0-9]+$') {
        throw 'The Feishu App ID must start with cli_.'
    }
    if ([string]::IsNullOrWhiteSpace($clientSecret)) {
        throw 'The Feishu App Secret cannot be empty.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $script:BridgeDirectory 'node_modules\@larksuiteoapi\node-sdk'))) {
        $npm = (Get-Command npm -ErrorAction Stop).Source
        & $npm install --no-audit --no-fund --prefix $script:BridgeDirectory
        if ($LASTEXITCODE -ne 0) { throw 'npm install failed.' }
    }
    Save-BridgeCredentials -ClientId $clientId -ClientSecret $clientSecret
    Invoke-InstallHook
    if (-not $NoStartup) {
        Enable-BridgeStartup
    }
    Invoke-StartAction
    Invoke-PairAction
    Write-Host 'Bridge credentials are encrypted with Windows DPAPI for the current user.'
    Write-Host 'Next, configure Feishu long-connection events and publish the application, then send the pairing command to the bot.'
    Write-Host 'Restart Codex and review/trust the new user-level Stop hook with /hooks.'
}

function Invoke-StatusAction {
    $paths = Get-BridgeManagerPaths
    $credentials = 'missing'
    if (Test-Path -LiteralPath $paths.Config) {
        try {
            $value = Get-BridgeCredentials
            $credentials = if (-not [string]::IsNullOrWhiteSpace([string]$value.appId) -and -not [string]::IsNullOrWhiteSpace([string]$value.appSecret)) { 'ready' } else { 'invalid' }
        }
        catch { $credentials = 'invalid' }
    }
    $state = Get-BridgeState
    $runtime = if (Test-Path -LiteralPath $paths.Runtime) { try { [IO.File]::ReadAllText($paths.Runtime) | ConvertFrom-Json } catch { $null } } else { $null }
    [pscustomobject][ordered]@{
        Credentials      = $credentials
        Running          = ($null -ne (Get-BridgePid))
        ProcessId        = Get-BridgePid
        StartupEnabled   = Test-BridgeStartupEnabled
        PairedUsers      = @((Get-ObjectProperty -Object $state -Name 'allowedOpenIds' -Default @())).Count
        PairingExpiresUtc = if ($null -eq $state.pairing) { $null } else { Get-ObjectProperty -Object $state.pairing -Name 'expiresAtUtc' }
        Sessions         = if (Test-Path -LiteralPath $paths.Sessions) { @(Get-ChildItem -LiteralPath $paths.Sessions -Filter '*.json' -File).Count } else { 0 }
        Inbox            = if (Test-Path -LiteralPath $paths.Inbox) { @(Get-ChildItem -LiteralPath $paths.Inbox -Filter '*.json' -File).Count } else { 0 }
        Outbox           = if (Test-Path -LiteralPath $paths.Outbox) { @(Get-ChildItem -LiteralPath $paths.Outbox -Filter '*.json' -File).Count } else { 0 }
        DeadLetter       = if (Test-Path -LiteralPath $paths.DeadLetter) { @(Get-ChildItem -LiteralPath $paths.DeadLetter -Filter '*.json' -File).Count } else { 0 }
        RetainedImages    = @(Get-ChildItem -LiteralPath @($paths.Media, $paths.OutboundMedia) -File -ErrorAction SilentlyContinue).Count
        GlobalWatch       = if (Test-Path -LiteralPath $paths.WatchState) { 'ready' } else { 'initializing' }
        RuntimeStatus    = if ($null -eq $runtime) { $null } else { Get-ObjectProperty -Object $runtime -Name 'status' }
        DataRoot         = $script:BridgeRoot
    } | Format-List
}

function Invoke-UninstallAction {
    Invoke-StopAction
    Disable-BridgeStartup
    if ($RemoveHook) {
        & (Get-PowerShellPath) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:NotifierScript -Action Uninstall
    }
    if ($RemoveData) {
        $expected = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'CodexFeishuBridge'))
        $target = [IO.Path]::GetFullPath($script:BridgeRoot)
        if (-not [string]::Equals($expected.TrimEnd('\'), $target.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Refusing recursive deletion because DataRoot is not the default bridge directory.'
        }
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Recurse -Force
        }
    }
    Write-Host 'Feishu bridge startup integration was removed.'
}

switch ($Action) {
    'Install'   { Invoke-InstallAction }
    'Pair'      { Invoke-PairAction }
    'Start'     { Invoke-StartAction }
    'Run'       { Invoke-RunAction }
    'Stop'      { Invoke-StopAction }
    'Status'    { Invoke-StatusAction }
    'Uninstall' { Invoke-UninstallAction }
    'Library'   { return }
}
