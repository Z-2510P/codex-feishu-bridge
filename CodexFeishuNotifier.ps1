[CmdletBinding()]
param(
    [ValidateSet('Install', 'InstallHook', 'Hook', 'Worker', 'Test', 'Status', 'Uninstall', 'Library')]
    [string]$Action = 'Status',

    [string]$WebhookUrl,
    [string]$SigningSecret,
    [string]$DataRoot,
    [string]$BridgeDataRoot,
    [string]$HooksPath,

    [switch]$RemoveData,
    [switch]$AllowInsecureEndpoint,
    [switch]$NoStartWorker
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Security
Add-Type -AssemblyName System.Net.Http

if ([string]::IsNullOrWhiteSpace($DataRoot)) {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_FEISHU_NOTIFIER_DATA_ROOT)) {
        $DataRoot = $env:CODEX_FEISHU_NOTIFIER_DATA_ROOT
    }
    else {
        $DataRoot = Join-Path $env:LOCALAPPDATA 'CodexFeishuNotifier'
    }
}

if ([string]::IsNullOrWhiteSpace($HooksPath)) {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_FEISHU_NOTIFIER_HOOKS_PATH)) {
        $HooksPath = $env:CODEX_FEISHU_NOTIFIER_HOOKS_PATH
    }
    else {
        $HooksPath = Join-Path (Join-Path $env:USERPROFILE '.codex') 'hooks.json'
    }
}

$script:NotifierScriptPath = $PSCommandPath
$script:DataRoot = [System.IO.Path]::GetFullPath($DataRoot)
if ([string]::IsNullOrWhiteSpace($BridgeDataRoot)) {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_FEISHU_BRIDGE_DATA_ROOT)) {
        $BridgeDataRoot = $env:CODEX_FEISHU_BRIDGE_DATA_ROOT
    }
    else {
        $BridgeDataRoot = Join-Path $env:LOCALAPPDATA 'CodexFeishuBridge'
    }
}
$script:BridgeDataRoot = [System.IO.Path]::GetFullPath($BridgeDataRoot)
$script:HooksPath = [System.IO.Path]::GetFullPath($HooksPath)
$script:AllowInsecureEndpoint = [bool]$AllowInsecureEndpoint
$script:RetryDelaysSeconds = @(5, 30, 120)
$script:HttpTimeoutSeconds = 8
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:DpapiEntropy = [System.Text.Encoding]::UTF8.GetBytes('CodexFeishuNotifier/v1')

$script:Text = @{
    Finished       = ConvertFrom-Json '"[Codex] \u672c\u8f6e\u5df2\u7ed3\u675f"'
    Title          = ConvertFrom-Json '"\u6807\u9898"'
    Project        = ConvertFrom-Json '"\u9879\u76ee"'
    Conversation   = ConvertFrom-Json '"\u5bf9\u8bdd"'
    Time           = ConvertFrom-Json '"\u65f6\u95f4"'
    UnknownProject = ConvertFrom-Json '"\u672a\u77e5\u9879\u76ee"'
    TestTitle      = ConvertFrom-Json '"[Codex] \u901a\u77e5\u6d4b\u8bd5"'
}

function Get-NotifierPaths {
    $root = $script:DataRoot
    return [pscustomobject][ordered]@{
        Root       = $root
        Config     = Join-Path $root 'settings.dpapi'
        Queue      = Join-Path $root 'queue'
        Sent       = Join-Path $root 'sent'
        DeadLetter = Join-Path $root 'dead-letter'
        Logs       = Join-Path $root 'logs'
        Log        = Join-Path (Join-Path $root 'logs') 'notifier.log'
        State      = Join-Path $root 'status.json'
    }
}

function Initialize-NotifierStorage {
    $paths = Get-NotifierPaths
    foreach ($path in @($paths.Root, $paths.Queue, $paths.Sent, $paths.DeadLetter, $paths.Logs)) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }
}

function Get-BridgePaths {
    $root = $script:BridgeDataRoot
    return [pscustomobject][ordered]@{
        Root     = $root
        Config   = Join-Path $root 'settings.dpapi'
        State    = Join-Path $root 'state.json'
        Sessions = Join-Path $root 'sessions'
        Outbox   = Join-Path $root 'outbox'
    }
}

function Initialize-BridgeStorage {
    $paths = Get-BridgePaths
    foreach ($path in @($paths.Root, $paths.Sessions, $paths.Outbox)) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }
}

function Get-ObjectProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $Default
    }

    return $property.Value
}

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][string]$Text)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)
        return -join ($hash | ForEach-Object { $_.ToString('x2') })
    }
    finally {
        $sha.Dispose()
    }
}

function Write-Utf8TextAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $temporaryPath = Join-Path $directory ([System.IO.Path]::GetRandomFileName())
    [System.IO.File]::WriteAllText($temporaryPath, $Content, $script:Utf8NoBom)
    $replacementBackup = $null
    try {
        if (Test-Path -LiteralPath $Path) {
            $replacementBackup = Join-Path $directory ([System.IO.Path]::GetRandomFileName())
            [System.IO.File]::Replace($temporaryPath, $Path, $replacementBackup)
        }
        else {
            [System.IO.File]::Move($temporaryPath, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
        if ($null -ne $replacementBackup -and (Test-Path -LiteralPath $replacementBackup)) {
            Remove-Item -LiteralPath $replacementBackup -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 30 -Compress
    Write-Utf8TextAtomic -Path $Path -Content $json
}

function Rotate-NotifierLog {
    $paths = Get-NotifierPaths
    if (-not (Test-Path -LiteralPath $paths.Log)) {
        return
    }

    $file = Get-Item -LiteralPath $paths.Log
    if ($file.Length -lt 1MB) {
        return
    }

    for ($index = 4; $index -ge 1; $index--) {
        $source = '{0}.{1}' -f $paths.Log, $index
        $destination = '{0}.{1}' -f $paths.Log, ($index + 1)
        if (Test-Path -LiteralPath $source) {
            Move-Item -LiteralPath $source -Destination $destination -Force
        }
    }
    Move-Item -LiteralPath $paths.Log -Destination ($paths.Log + '.1') -Force
}

function Write-NotifierLog {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('info', 'warning', 'error')][string]$Level,
        [Parameter(Mandatory = $true)][string]$Event,
        [string]$Detail = ''
    )

    try {
        Initialize-NotifierStorage
        Rotate-NotifierLog
        $safeDetail = [regex]::Replace($Detail, '[\x00-\x1F\x7F]+', ' ').Trim()
        if ($safeDetail.Length -gt 240) {
            $safeDetail = $safeDetail.Substring(0, 240)
        }
        $record = [ordered]@{
            at     = [DateTimeOffset]::UtcNow.ToString('o')
            level  = $Level
            event  = $Event
            detail = $safeDetail
        }
        $line = ($record | ConvertTo-Json -Compress) + [Environment]::NewLine
        [System.IO.File]::AppendAllText((Get-NotifierPaths).Log, $line, $script:Utf8NoBom)
    }
    catch {
        # Logging must never break Codex hook execution.
    }
}

function Set-NotifierState {
    param(
        [string]$LastSuccessAtUtc,
        [string]$LastFailureAtUtc,
        [string]$LastFailureClass,
        [string]$LastEventKey
    )

    $paths = Get-NotifierPaths
    $state = [ordered]@{
        schema             = 1
        lastSuccessAtUtc   = $LastSuccessAtUtc
        lastFailureAtUtc   = $LastFailureAtUtc
        lastFailureClass   = $LastFailureClass
        lastEventKey       = $LastEventKey
    }
    Write-JsonAtomic -Path $paths.State -Value $state
}

function Save-ProtectedSettings {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Secret
    )

    Initialize-NotifierStorage
    $settings = [ordered]@{
        schema        = 1
        webhookUrl    = $Url
        signingSecret = $Secret
    }
    $plainText = $settings | ConvertTo-Json -Compress
    $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($plainText)
    try {
        $protectedBytes = [System.Security.Cryptography.ProtectedData]::Protect(
            $plainBytes,
            $script:DpapiEntropy,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        $encoded = [Convert]::ToBase64String($protectedBytes)
        Write-Utf8TextAtomic -Path (Get-NotifierPaths).Config -Content $encoded
    }
    finally {
        [Array]::Clear($plainBytes, 0, $plainBytes.Length)
    }
}

function Get-ProtectedSettings {
    $path = (Get-NotifierPaths).Config
    if (-not (Test-Path -LiteralPath $path)) {
        throw 'Notifier settings are not installed.'
    }

    $encoded = [System.IO.File]::ReadAllText($path, $script:Utf8NoBom).Trim()
    $protectedBytes = [Convert]::FromBase64String($encoded)
    $plainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $protectedBytes,
        $script:DpapiEntropy,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    try {
        $plainText = [System.Text.Encoding]::UTF8.GetString($plainBytes)
        return $plainText | ConvertFrom-Json
    }
    finally {
        [Array]::Clear($plainBytes, 0, $plainBytes.Length)
    }
}

function Assert-WebhookUrl {
    param([Parameter(Mandatory = $true)][string]$Url)

    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) {
        throw 'The Feishu webhook URL is invalid.'
    }

    if ($script:AllowInsecureEndpoint) {
        if (($uri.Host -eq '127.0.0.1' -or $uri.Host -eq 'localhost') -and $uri.Scheme -eq 'http') {
            return $uri
        }
    }

    if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'open.feishu.cn') {
        throw 'The webhook must use https://open.feishu.cn.'
    }
    if ($uri.AbsolutePath -notmatch '^/open-apis/bot/v2/hook/[^/]+$') {
        throw 'The webhook must be a Feishu V2 custom-bot URL.'
    }
    if (-not [string]::IsNullOrEmpty($uri.Query) -or -not [string]::IsNullOrEmpty($uri.Fragment)) {
        throw 'The webhook URL must not contain a query string or fragment.'
    }

    return $uri
}

function Get-FeishuSignature {
    param(
        [Parameter(Mandatory = $true)][long]$Timestamp,
        [Parameter(Mandatory = $true)][string]$Secret
    )

    $keyText = "{0}`n{1}" -f $Timestamp, $Secret
    $keyBytes = [System.Text.Encoding]::UTF8.GetBytes($keyText)
    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    try {
        $hmac.Key = $keyBytes
        $digest = $hmac.ComputeHash([byte[]]@())
        return [Convert]::ToBase64String($digest)
    }
    finally {
        $hmac.Dispose()
        [Array]::Clear($keyBytes, 0, $keyBytes.Length)
    }
}

function Get-UnixTimestampSeconds {
    $epoch = [DateTimeOffset]::new([DateTime]::SpecifyKind([DateTime]'1970-01-01', [DateTimeKind]::Utc))
    return [long][Math]::Floor(([DateTimeOffset]::UtcNow - $epoch).TotalSeconds)
}

function New-FeishuRequestBody {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][string]$Secret,
        [Nullable[long]]$Timestamp
    )

    $timestampValue = if ($null -eq $Timestamp) { Get-UnixTimestampSeconds } else { [long]$Timestamp }
    return [ordered]@{
        timestamp = $timestampValue.ToString([Globalization.CultureInfo]::InvariantCulture)
        sign       = Get-FeishuSignature -Timestamp $timestampValue -Secret $Secret
        msg_type   = 'text'
        content    = [ordered]@{
            text = $Message
        }
    }
}

function Invoke-FeishuRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Secret,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $uri = Assert-WebhookUrl -Url $Url
    $body = New-FeishuRequestBody -Message $Message -Secret $Secret
    $json = $body | ConvertTo-Json -Depth 8 -Compress

    $handler = New-Object -TypeName System.Net.Http.HttpClientHandler
    $client = New-Object -TypeName System.Net.Http.HttpClient -ArgumentList @($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($script:HttpTimeoutSeconds)
    $content = New-Object -TypeName System.Net.Http.StringContent -ArgumentList @($json, [System.Text.Encoding]::UTF8, 'application/json')

    try {
        $response = $client.PostAsync($uri, $content).GetAwaiter().GetResult()
        $statusCode = [int]$response.StatusCode
        $responseText = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()

        if ($statusCode -eq 429 -or $statusCode -ge 500) {
            return [pscustomobject]@{ Kind = 'Transient'; HttpStatus = $statusCode; FeishuCode = $null }
        }
        if ($statusCode -lt 200 -or $statusCode -ge 300) {
            return [pscustomobject]@{ Kind = 'Permanent'; HttpStatus = $statusCode; FeishuCode = $null }
        }

        try {
            $responseObject = $responseText | ConvertFrom-Json
            $feishuCode = [int](Get-ObjectProperty -Object $responseObject -Name 'code' -Default -1)
        }
        catch {
            return [pscustomobject]@{ Kind = 'Transient'; HttpStatus = $statusCode; FeishuCode = $null }
        }

        if ($feishuCode -eq 0) {
            return [pscustomobject]@{ Kind = 'Success'; HttpStatus = $statusCode; FeishuCode = 0 }
        }
        if ($feishuCode -in @(11232, 99991400, 99991403)) {
            return [pscustomobject]@{ Kind = 'Transient'; HttpStatus = $statusCode; FeishuCode = $feishuCode }
        }
        return [pscustomobject]@{ Kind = 'Permanent'; HttpStatus = $statusCode; FeishuCode = $feishuCode }
    }
    catch {
        return [pscustomobject]@{
            Kind        = 'Transient'
            HttpStatus  = $null
            FeishuCode  = $null
            FailureType = $_.Exception.GetType().Name
        }
    }
    finally {
        $content.Dispose()
        $client.Dispose()
        $handler.Dispose()
    }
}

function ConvertTo-SafeProjectName {
    param([string]$Cwd)

    if ([string]::IsNullOrWhiteSpace($Cwd)) {
        return $script:Text.UnknownProject
    }

    $candidate = $Cwd.Trim()
    $trimmed = $candidate.TrimEnd([char[]]@('\', '/'))
    try {
        $leaf = [System.IO.Path]::GetFileName($trimmed)
    }
    catch {
        $segments = @([regex]::Split($trimmed, '[\\/]') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $leaf = if ($segments.Count -gt 0) { [string]$segments[-1] } else { '' }
    }
    if ([string]::IsNullOrWhiteSpace($leaf)) {
        $root = [System.IO.Path]::GetPathRoot($candidate)
        if ($root -match '^[A-Za-z]:\\$') {
            $leaf = $root.Substring(0, 2)
        }
        elseif (-not [string]::IsNullOrWhiteSpace($root)) {
            $leaf = $root.TrimEnd([char[]]@('\', '/'))
        }
    }
    if ([string]::IsNullOrWhiteSpace($leaf)) {
        $leaf = $script:Text.UnknownProject
    }

    $leaf = [regex]::Replace($leaf, '[\x00-\x1F\x7F]+', ' ').Trim()
    $leaf = $leaf.Replace('<', [string][char]0xFF1C)
    $leaf = $leaf.Replace('>', [string][char]0xFF1E)
    $leaf = $leaf.Replace('&', [string][char]0xFF06)
    if ($leaf.Length -gt 120) {
        $leaf = $leaf.Substring(0, 120)
    }
    if ([string]::IsNullOrWhiteSpace($leaf)) {
        return $script:Text.UnknownProject
    }
    return $leaf
}

function New-NotificationMessage {
    param(
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)][DateTimeOffset]$OccurredAt,
        [string]$ConversationCode = '',
        [string]$Title = ''
    )

    $lines = @($script:Text.Finished)
    if (-not [string]::IsNullOrWhiteSpace($Title)) {
        $lines += ('{0}: {1}' -f $script:Text.Title, $Title)
    }
    $lines += ('{0}: {1}' -f $script:Text.Project, $Project)
    if (-not [string]::IsNullOrWhiteSpace($ConversationCode)) {
        $lines += ('{0}: {1}' -f $script:Text.Conversation, $ConversationCode)
    }
    $lines += ('{0}: {1}' -f $script:Text.Time, $OccurredAt.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss'))
    return $lines -join "`n"
}

function Get-ConversationCode {
    param([Parameter(Mandatory = $true)][string]$SessionId)
    return (Get-Sha256Hex $SessionId).Substring(0, 10).ToUpperInvariant()
}

function Update-SessionMap {
    param(
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$Project
    )

    Initialize-BridgeStorage
    $code = Get-ConversationCode -SessionId $SessionId
    $path = Join-Path (Get-BridgePaths).Sessions ($code + '.json')
    $title = $null
    if (Test-Path -LiteralPath $path) {
        try {
            $existing = [System.IO.File]::ReadAllText($path, $script:Utf8NoBom) | ConvertFrom-Json
            $titleProperty = $existing.PSObject.Properties['title']
            if ($null -ne $titleProperty -and -not [string]::IsNullOrWhiteSpace([string]$titleProperty.Value)) {
                $title = [string]$titleProperty.Value
            }
        }
        catch {
            $title = $null
        }
    }
    $record = [ordered]@{
        schema      = 2
        code        = $code
        sessionId   = $SessionId
        project     = $Project
        lastSeenUtc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    if ($null -ne $title) {
        $record['title'] = $title
    }
    Write-JsonAtomic -Path $path -Value $record
    return $code
}

function Get-SessionTitle {
    param([Parameter(Mandatory = $true)][string]$ConversationCode)

    $path = Join-Path (Get-BridgePaths).Sessions ($ConversationCode + '.json')
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    try {
        $record = [System.IO.File]::ReadAllText($path, $script:Utf8NoBom) | ConvertFrom-Json
        return [string](Get-ObjectProperty -Object $record -Name 'title' -Default '')
    }
    catch {
        return ''
    }
}

function Get-BridgeTargetChatId {
    $paths = Get-BridgePaths
    if (-not (Test-Path -LiteralPath $paths.Config) -or -not (Test-Path -LiteralPath $paths.State)) {
        return $null
    }
    try {
        $state = [System.IO.File]::ReadAllText($paths.State, $script:Utf8NoBom) | ConvertFrom-Json
        $allowed = @((Get-ObjectProperty -Object $state -Name 'allowedOpenIds' -Default @()))
        if ($allowed.Count -eq 0) {
            return $null
        }
        $chatMap = Get-ObjectProperty -Object $state -Name 'defaultChatByUser' -Default $null
        if ($null -eq $chatMap) {
            return $null
        }
        foreach ($openId in $allowed) {
            $chatId = [string](Get-ObjectProperty -Object $chatMap -Name ([string]$openId) -Default '')
            if (-not [string]::IsNullOrWhiteSpace($chatId)) {
                return $chatId
            }
        }
    }
    catch {
        return $null
    }
    return $null
}

function Try-EnqueueBridgeCompletion {
    param(
        [Parameter(Mandatory = $true)][string]$EventKey,
        [Parameter(Mandatory = $true)][string]$ConversationCode,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $chatId = Get-BridgeTargetChatId
    if ([string]::IsNullOrWhiteSpace($chatId)) {
        return $false
    }

    Initialize-BridgeStorage
    $path = Join-Path (Get-BridgePaths).Outbox ($EventKey + '.json')
    if (Test-Path -LiteralPath $path) {
        return $true
    }
    $job = [ordered]@{
        schema           = 1
        kind             = 'completion'
        eventKey         = $EventKey
        targetChatId     = $chatId
        conversationCode = $ConversationCode
        message          = $Message
        createdAtUtc     = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $temporaryPath = Join-Path (Get-BridgePaths).Outbox ([System.IO.Path]::GetRandomFileName())
    [System.IO.File]::WriteAllText($temporaryPath, ($job | ConvertTo-Json -Compress), $script:Utf8NoBom)
    try {
        [System.IO.File]::Move($temporaryPath, $path)
        return $true
    }
    catch [System.IO.IOException] {
        return $true
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Try-EnqueueNotification {
    param([Parameter(Mandatory = $true)]$HookEvent)

    Initialize-NotifierStorage
    $eventName = [string](Get-ObjectProperty -Object $HookEvent -Name 'hook_event_name' -Default '')
    if ($eventName -ne 'Stop') {
        return $false
    }

    $sessionId = [string](Get-ObjectProperty -Object $HookEvent -Name 'session_id' -Default '')
    $turnId = [string](Get-ObjectProperty -Object $HookEvent -Name 'turn_id' -Default '')
    if ([string]::IsNullOrWhiteSpace($sessionId) -or [string]::IsNullOrWhiteSpace($turnId)) {
        Write-NotifierLog -Level warning -Event 'invalid_hook_event' -Detail 'Missing session_id or turn_id.'
        return $false
    }

    $eventKey = Get-Sha256Hex ($sessionId + "`n" + $turnId)
    $paths = Get-NotifierPaths
    $queuePath = Join-Path $paths.Queue ($eventKey + '.json')
    $sentPath = Join-Path $paths.Sent ($eventKey + '.done')
    $deadPath = Join-Path $paths.DeadLetter ($eventKey + '.json')
    if ((Test-Path -LiteralPath $queuePath) -or (Test-Path -LiteralPath $sentPath) -or (Test-Path -LiteralPath $deadPath)) {
        Write-NotifierLog -Level info -Event 'duplicate_ignored' -Detail $eventKey.Substring(0, 12)
        return $false
    }

    $occurredAt = [DateTimeOffset]::Now
    $project = ConvertTo-SafeProjectName -Cwd ([string](Get-ObjectProperty -Object $HookEvent -Name 'cwd' -Default ''))
    $conversationCode = Update-SessionMap -SessionId $sessionId -Project $project
    $title = Get-SessionTitle -ConversationCode $conversationCode
    $job = [ordered]@{
        schema           = 1
        eventKey         = $eventKey
        project          = $project
        conversationCode = $conversationCode
        occurredAtUtc    = $occurredAt.ToUniversalTime().ToString('o')
        message          = New-NotificationMessage -Project $project -OccurredAt $occurredAt -ConversationCode $conversationCode -Title $title
        attempt          = 0
        nextAttemptAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    }

    $temporaryPath = Join-Path $paths.Queue ([System.IO.Path]::GetRandomFileName())
    $json = $job | ConvertTo-Json -Depth 10 -Compress
    [System.IO.File]::WriteAllText($temporaryPath, $json, $script:Utf8NoBom)
    try {
        [System.IO.File]::Move($temporaryPath, $queuePath)
        Write-NotifierLog -Level info -Event 'queued' -Detail $eventKey.Substring(0, 12)
        return $true
    }
    catch [System.IO.IOException] {
        Write-NotifierLog -Level info -Event 'duplicate_race_ignored' -Detail $eventKey.Substring(0, 12)
        return $false
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Start-NotifierWorker {
    $powerShellPath = Join-Path $PSHOME 'powershell.exe'
    $arguments = @(
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $script:NotifierScriptPath),
        '-Action', 'Worker',
        '-DataRoot', ('"{0}"' -f $script:DataRoot)
    )
    if ($script:AllowInsecureEndpoint) {
        $arguments += '-AllowInsecureEndpoint'
    }

    Start-Process -FilePath $powerShellPath -ArgumentList $arguments -WindowStyle Hidden | Out-Null
}

function Invoke-HookAction {
    try {
        $rawInput = [Console]::In.ReadToEnd()
        if ([string]::IsNullOrWhiteSpace($rawInput)) {
            Write-NotifierLog -Level warning -Event 'empty_hook_input'
            return
        }
        try {
            $hookEvent = $rawInput | ConvertFrom-Json
        }
        catch {
            Write-NotifierLog -Level warning -Event 'invalid_hook_json'
            return
        }

        $eventName = [string](Get-ObjectProperty -Object $hookEvent -Name 'hook_event_name' -Default '')
        $sessionId = [string](Get-ObjectProperty -Object $hookEvent -Name 'session_id' -Default '')
        $turnId = [string](Get-ObjectProperty -Object $hookEvent -Name 'turn_id' -Default '')
        if ($eventName -ne 'Stop' -or [string]::IsNullOrWhiteSpace($sessionId) -or [string]::IsNullOrWhiteSpace($turnId)) {
            Write-NotifierLog -Level warning -Event 'invalid_hook_event' -Detail 'Missing Stop, session_id, or turn_id.'
            return
        }

        $project = ConvertTo-SafeProjectName -Cwd ([string](Get-ObjectProperty -Object $hookEvent -Name 'cwd' -Default ''))
        $conversationCode = Update-SessionMap -SessionId $sessionId -Project $project
        $title = Get-SessionTitle -ConversationCode $conversationCode
        $eventKey = Get-Sha256Hex ($sessionId + "`n" + $turnId)
        $occurredAt = [DateTimeOffset]::Now
        $message = New-NotificationMessage -Project $project -OccurredAt $occurredAt -ConversationCode $conversationCode -Title $title

        if ($env:CODEX_FEISHU_REMOTE_RUN -eq '1') {
            Write-NotifierLog -Level info -Event 'remote_turn_mapped_without_completion' -Detail $conversationCode
            return
        }

        if (-not [string]::IsNullOrWhiteSpace([string](Get-BridgeTargetChatId))) {
            Write-NotifierLog -Level info -Event 'completion_owned_by_global_watcher' -Detail $eventKey.Substring(0, 12)
            return
        }

        if (Test-Path -LiteralPath (Get-NotifierPaths).Config) {
            $queued = Try-EnqueueNotification -HookEvent $hookEvent
            if ($queued -and -not $NoStartWorker) {
                Start-NotifierWorker
            }
        }
        else {
            Write-NotifierLog -Level info -Event 'session_mapped_without_delivery' -Detail $conversationCode
        }
    }
    catch {
        Write-NotifierLog -Level error -Event 'hook_failure' -Detail $_.Exception.GetType().Name
    }
}

function Move-JobToDeadLetter {
    param(
        [Parameter(Mandatory = $true)][string]$QueuePath,
        [Parameter(Mandatory = $true)]$Job,
        [Parameter(Mandatory = $true)][string]$FailureClass
    )

    $paths = Get-NotifierPaths
    $job | Add-Member -NotePropertyName failedAtUtc -NotePropertyValue ([DateTimeOffset]::UtcNow.ToString('o')) -Force
    $job | Add-Member -NotePropertyName failureClass -NotePropertyValue $FailureClass -Force
    Write-JsonAtomic -Path $QueuePath -Value $Job
    $deadPath = Join-Path $paths.DeadLetter (([string]$Job.eventKey) + '.json')
    Move-Item -LiteralPath $QueuePath -Destination $deadPath -Force
    Set-NotifierState -LastFailureAtUtc ([DateTimeOffset]::UtcNow.ToString('o')) -LastFailureClass $FailureClass -LastEventKey ([string]$Job.eventKey)
    Write-NotifierLog -Level error -Event 'dead_lettered' -Detail ('{0} {1}' -f ([string]$Job.eventKey).Substring(0, 12), $FailureClass)
}

function Invoke-NotifierWorker {
    Initialize-NotifierStorage
    try {
        $settings = Get-ProtectedSettings
        $url = [string](Get-ObjectProperty -Object $settings -Name 'webhookUrl' -Default '')
        $secret = [string](Get-ObjectProperty -Object $settings -Name 'signingSecret' -Default '')
        Assert-WebhookUrl -Url $url | Out-Null
        if ([string]::IsNullOrWhiteSpace($secret)) {
            throw 'The signing secret is missing.'
        }
    }
    catch {
        Write-NotifierLog -Level error -Event 'settings_unavailable' -Detail $_.Exception.GetType().Name
        return
    }

    $mutexName = 'Local\CodexFeishuNotifier_' + (Get-Sha256Hex $script:DataRoot).Substring(0, 16)
    $mutex = New-Object -TypeName System.Threading.Mutex -ArgumentList @($false, $mutexName)
    $hasMutex = $false
    try {
        $hasMutex = $mutex.WaitOne(0, $false)
        if (-not $hasMutex) {
            return
        }

        while ($true) {
            $paths = Get-NotifierPaths
            $queueFiles = @(Get-ChildItem -LiteralPath $paths.Queue -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)
            if ($queueFiles.Count -eq 0) {
                break
            }

            $now = [DateTimeOffset]::UtcNow
            $nextDue = $null
            $madeProgress = $false

            foreach ($file in $queueFiles) {
                try {
                    $job = [System.IO.File]::ReadAllText($file.FullName, $script:Utf8NoBom) | ConvertFrom-Json
                    $eventKey = [string](Get-ObjectProperty -Object $job -Name 'eventKey' -Default '')
                    if ($eventKey -notmatch '^[a-f0-9]{64}$') {
                        throw 'Invalid event key.'
                    }

                    $sentPath = Join-Path $paths.Sent ($eventKey + '.done')
                    if (Test-Path -LiteralPath $sentPath) {
                        Remove-Item -LiteralPath $file.FullName -Force
                        $madeProgress = $true
                        continue
                    }

                    $nextAttemptText = [string](Get-ObjectProperty -Object $job -Name 'nextAttemptAtUtc' -Default '')
                    $nextAttempt = [DateTimeOffset]::MinValue
                    if (-not [DateTimeOffset]::TryParse($nextAttemptText, [ref]$nextAttempt)) {
                        $nextAttempt = [DateTimeOffset]::MinValue
                    }
                    if ($nextAttempt -gt $now) {
                        if ($null -eq $nextDue -or $nextAttempt -lt $nextDue) {
                            $nextDue = $nextAttempt
                        }
                        continue
                    }

                    $result = Invoke-FeishuRequest -Url $url -Secret $secret -Message ([string]$job.message)
                    if ($result.Kind -eq 'Success') {
                        [System.IO.File]::WriteAllText($sentPath, [DateTimeOffset]::UtcNow.ToString('o'), $script:Utf8NoBom)
                        Remove-Item -LiteralPath $file.FullName -Force
                        Set-NotifierState -LastSuccessAtUtc ([DateTimeOffset]::UtcNow.ToString('o')) -LastEventKey $eventKey
                        Write-NotifierLog -Level info -Event 'sent' -Detail $eventKey.Substring(0, 12)
                        $madeProgress = $true
                        continue
                    }

                    if ($result.Kind -eq 'Permanent') {
                        $failureClass = 'permanent_http'
                        if ($null -ne $result.FeishuCode) {
                            $failureClass = 'feishu_code_' + [string]$result.FeishuCode
                        }
                        Move-JobToDeadLetter -QueuePath $file.FullName -Job $job -FailureClass $failureClass
                        $madeProgress = $true
                        continue
                    }

                    $attempt = [int](Get-ObjectProperty -Object $job -Name 'attempt' -Default 0) + 1
                    if ($attempt -gt $script:RetryDelaysSeconds.Count) {
                        Move-JobToDeadLetter -QueuePath $file.FullName -Job $job -FailureClass 'transient_retries_exhausted'
                        $madeProgress = $true
                        continue
                    }

                    $delay = [int]$script:RetryDelaysSeconds[$attempt - 1]
                    $retryAt = [DateTimeOffset]::UtcNow.AddSeconds($delay)
                    $job.attempt = $attempt
                    $job.nextAttemptAtUtc = $retryAt.ToString('o')
                    Write-JsonAtomic -Path $file.FullName -Value $job
                    Write-NotifierLog -Level warning -Event 'retry_scheduled' -Detail ('{0} attempt={1}' -f $eventKey.Substring(0, 12), $attempt)
                    if ($null -eq $nextDue -or $retryAt -lt $nextDue) {
                        $nextDue = $retryAt
                    }
                    $madeProgress = $true
                }
                catch {
                    try {
                        $fallbackKey = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
                        $fallbackJob = [pscustomobject]@{ eventKey = $fallbackKey }
                        Move-JobToDeadLetter -QueuePath $file.FullName -Job $fallbackJob -FailureClass 'invalid_queue_job'
                    }
                    catch {
                        Write-NotifierLog -Level error -Event 'queue_job_failure' -Detail $_.Exception.GetType().Name
                    }
                    $madeProgress = $true
                }
            }

            if ($null -ne $nextDue) {
                $waitMilliseconds = [int][Math]::Max(50, [Math]::Min(30000, ($nextDue - [DateTimeOffset]::UtcNow).TotalMilliseconds))
                Start-Sleep -Milliseconds $waitMilliseconds
            }
            elseif (-not $madeProgress) {
                break
            }
        }

        $cutoff = [DateTime]::UtcNow.AddDays(-30)
        Get-ChildItem -LiteralPath (Get-NotifierPaths).Sent -Filter '*.done' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTimeUtc -lt $cutoff } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    finally {
        if ($hasMutex) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}

function Get-HookCommand {
    $powerShellPath = Join-Path $PSHOME 'powershell.exe'
    return '"{0}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{1}" -Action Hook' -f $powerShellPath, $script:NotifierScriptPath
}

function Read-HooksDocument {
    if (-not (Test-Path -LiteralPath $script:HooksPath)) {
        return [pscustomobject][ordered]@{
            description = 'User-level Codex lifecycle hooks.'
            hooks       = [pscustomobject][ordered]@{}
        }
    }

    $raw = [System.IO.File]::ReadAllText($script:HooksPath, $script:Utf8NoBom)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw 'hooks.json is empty.'
    }
    return $raw | ConvertFrom-Json
}

function Ensure-HooksShape {
    param([Parameter(Mandatory = $true)]$Document)

    if ($null -eq $Document.PSObject.Properties['hooks']) {
        $Document | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject][ordered]@{})
    }
    if ($null -eq $Document.hooks.PSObject.Properties['Stop']) {
        $Document.hooks | Add-Member -NotePropertyName Stop -NotePropertyValue @()
    }
    return $Document
}

function Test-IsNotifierHandler {
    param($Handler)

    if ($null -eq $Handler) {
        return $false
    }
    $type = [string](Get-ObjectProperty -Object $Handler -Name 'type' -Default '')
    $command = [string](Get-ObjectProperty -Object $Handler -Name 'command' -Default '')
    return ($type -eq 'command' -and $command -eq (Get-HookCommand))
}

function Test-HookInstalled {
    if (-not (Test-Path -LiteralPath $script:HooksPath)) {
        return $false
    }
    try {
        $document = Ensure-HooksShape -Document (Read-HooksDocument)
        foreach ($group in @($document.hooks.Stop)) {
            foreach ($handler in @((Get-ObjectProperty -Object $group -Name 'hooks' -Default @()))) {
                if (Test-IsNotifierHandler -Handler $handler) {
                    return $true
                }
            }
        }
    }
    catch {
        return $false
    }
    return $false
}

function Backup-HooksDocument {
    if (Test-Path -LiteralPath $script:HooksPath) {
        $timestamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $script:HooksPath -Destination ($script:HooksPath + '.bak-' + $timestamp)
    }
}

function Install-NotifierHook {
    $document = Ensure-HooksShape -Document (Read-HooksDocument)
    foreach ($group in @($document.hooks.Stop)) {
        foreach ($handler in @((Get-ObjectProperty -Object $group -Name 'hooks' -Default @()))) {
            if (Test-IsNotifierHandler -Handler $handler) {
                return $false
            }
        }
    }

    $newGroup = [pscustomobject][ordered]@{
        hooks = @(
            [pscustomobject][ordered]@{
                type    = 'command'
                command = Get-HookCommand
                timeout = 5
            }
        )
    }
    $document.hooks.Stop = @($document.hooks.Stop) + @($newGroup)
    Backup-HooksDocument
    Write-JsonAtomic -Path $script:HooksPath -Value $document
    return $true
}

function Uninstall-NotifierHook {
    if (-not (Test-Path -LiteralPath $script:HooksPath)) {
        return $false
    }

    $document = Ensure-HooksShape -Document (Read-HooksDocument)
    $changed = $false
    $remainingGroups = @()
    foreach ($group in @($document.hooks.Stop)) {
        $remainingHandlers = @()
        foreach ($handler in @((Get-ObjectProperty -Object $group -Name 'hooks' -Default @()))) {
            if (Test-IsNotifierHandler -Handler $handler) {
                $changed = $true
            }
            else {
                $remainingHandlers += $handler
            }
        }
        if ($remainingHandlers.Count -gt 0) {
            $group.hooks = $remainingHandlers
            $remainingGroups += $group
        }
    }

    if ($changed) {
        $document.hooks.Stop = $remainingGroups
        Backup-HooksDocument
        Write-JsonAtomic -Path $script:HooksPath -Value $document
    }
    return $changed
}

function Convert-SecureStringToPlainText {
    param([Parameter(Mandatory = $true)][Security.SecureString]$SecureValue)

    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Invoke-InstallAction {
    $url = $WebhookUrl
    $secret = $SigningSecret

    if ([string]::IsNullOrWhiteSpace($url)) {
        $secureUrl = Read-Host 'Paste the Feishu V2 webhook URL' -AsSecureString
        $url = Convert-SecureStringToPlainText -SecureValue $secureUrl
    }
    if ([string]::IsNullOrWhiteSpace($secret)) {
        $secureSecret = Read-Host 'Paste the Feishu signing secret' -AsSecureString
        $secret = Convert-SecureStringToPlainText -SecureValue $secureSecret
    }

    Assert-WebhookUrl -Url $url | Out-Null
    if ([string]::IsNullOrWhiteSpace($secret)) {
        throw 'The Feishu signing secret cannot be empty.'
    }

    Save-ProtectedSettings -Url $url -Secret $secret
    $hookAdded = Install-NotifierHook
    Write-Host 'Codex Feishu notifier installed.'
    Write-Host ('Hook file: {0}' -f $script:HooksPath)
    Write-Host ('Encrypted settings: {0}' -f (Get-NotifierPaths).Config)
    if (-not $hookAdded) {
        Write-Host 'The hook was already present; it was not duplicated.'
    }
    Write-Host 'Next: run -Action Test, restart Codex, then review/trust the hook with /hooks.'
}

function Invoke-InstallHookAction {
    $hookAdded = Install-NotifierHook
    if ($hookAdded) {
        Write-Host ('Installed the Codex Stop hook in {0}.' -f $script:HooksPath)
    }
    else {
        Write-Host 'The Codex Stop hook is already installed.'
    }
}

function Invoke-TestAction {
    $settings = Get-ProtectedSettings
    $url = [string](Get-ObjectProperty -Object $settings -Name 'webhookUrl' -Default '')
    $secret = [string](Get-ObjectProperty -Object $settings -Name 'signingSecret' -Default '')
    $project = ConvertTo-SafeProjectName -Cwd (Get-Location).Path
    $message = "{0}`n{1}: {2}`n{3}: {4}" -f @(
        $script:Text.TestTitle,
        $script:Text.Project,
        $project,
        $script:Text.Time,
        [DateTimeOffset]::Now.ToString('yyyy-MM-dd HH:mm:ss')
    )
    $result = Invoke-FeishuRequest -Url $url -Secret $secret -Message $message
    if ($result.Kind -ne 'Success') {
        throw ('Feishu test failed: {0}, HTTP={1}, code={2}' -f $result.Kind, $result.HttpStatus, $result.FeishuCode)
    }
    Write-Host 'Feishu accepted the test notification (code=0).'
}

function Invoke-StatusAction {
    $paths = Get-NotifierPaths
    $settingsState = 'missing'
    $endpointHost = '-'
    if (Test-Path -LiteralPath $paths.Config) {
        try {
            $settings = Get-ProtectedSettings
            $uri = Assert-WebhookUrl -Url ([string]$settings.webhookUrl)
            if ([string]::IsNullOrWhiteSpace([string]$settings.signingSecret)) {
                $settingsState = 'invalid'
            }
            else {
                $settingsState = 'ready'
                $endpointHost = $uri.Host
            }
        }
        catch {
            $settingsState = 'invalid'
        }
    }

    $queueCount = if (Test-Path -LiteralPath $paths.Queue) { @(Get-ChildItem -LiteralPath $paths.Queue -Filter '*.json' -File).Count } else { 0 }
    $deadCount = if (Test-Path -LiteralPath $paths.DeadLetter) { @(Get-ChildItem -LiteralPath $paths.DeadLetter -Filter '*.json' -File).Count } else { 0 }
    $lastState = $null
    if (Test-Path -LiteralPath $paths.State) {
        try { $lastState = [System.IO.File]::ReadAllText($paths.State, $script:Utf8NoBom) | ConvertFrom-Json } catch { $lastState = $null }
    }

    [pscustomobject][ordered]@{
        Script          = $script:NotifierScriptPath
        HookInstalled   = Test-HookInstalled
        HookTrust       = 'review with /hooks'
        Settings        = $settingsState
        EndpointHost    = $endpointHost
        QueueCount      = $queueCount
        DeadLetterCount = $deadCount
        LastSuccessUtc  = if ($null -eq $lastState) { $null } else { Get-ObjectProperty -Object $lastState -Name 'lastSuccessAtUtc' }
        LastFailureUtc  = if ($null -eq $lastState) { $null } else { Get-ObjectProperty -Object $lastState -Name 'lastFailureAtUtc' }
        LastFailure     = if ($null -eq $lastState) { $null } else { Get-ObjectProperty -Object $lastState -Name 'lastFailureClass' }
    } | Format-List
}

function Invoke-UninstallAction {
    $removed = Uninstall-NotifierHook
    if ($removed) {
        Write-Host 'The Codex Feishu Stop hook was removed.'
    }
    else {
        Write-Host 'No matching Codex Feishu Stop hook was present.'
    }

    if ($RemoveData) {
        $expected = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'CodexFeishuNotifier'))
        $target = [System.IO.Path]::GetFullPath($script:DataRoot)
        if (-not [string]::Equals($target.TrimEnd('\'), $expected.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Refusing recursive deletion because DataRoot is not the default notifier data directory.'
        }
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Recurse -Force
            Write-Host ('Removed notifier data: {0}' -f $target)
        }
    }
}

switch ($Action) {
    'Install'   { Invoke-InstallAction }
    'InstallHook' { Invoke-InstallHookAction }
    'Hook'      { Invoke-HookAction }
    'Worker'    { Invoke-NotifierWorker }
    'Test'      { Invoke-TestAction }
    'Status'    { Invoke-StatusAction }
    'Uninstall' { Invoke-UninstallAction }
    'Library'   { return }
}
