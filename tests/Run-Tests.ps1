[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\CodexFeishuNotifier.ps1'))
$testRoot = Join-Path $env:TEMP ('CodexFeishuNotifier-tests-' + [Guid]::NewGuid().ToString('N'))
$dataRoot = Join-Path $testRoot 'data'
$bridgeDataRoot = Join-Path $testRoot 'bridge-data'
$hooksPath = Join-Path $testRoot 'hooks.json'
$script:Passed = 0
$script:Failed = 0

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) {
        $script:Passed++
        Write-Host ('PASS  {0}' -f $Name)
    }
    else {
        $script:Failed++
        Write-Host ('FAIL  {0}' -f $Name) -ForegroundColor Red
    }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Name)
    Assert-True -Condition ($Actual -eq $Expected) -Name ($Name + " (actual='$Actual', expected='$Expected')")
}

function Get-FreeTcpPort {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try {
        return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    }
    finally {
        $listener.Stop()
    }
}

function Start-MockHttpServer {
    param(
        [Parameter(Mandatory = $true)][int[]]$StatusCodes,
        [string[]]$Bodies
    )

    $port = Get-FreeTcpPort
    $readyPath = Join-Path $testRoot ('ready-' + [Guid]::NewGuid().ToString('N'))
    if ($null -eq $Bodies -or $Bodies.Count -eq 0) {
        $Bodies = @($StatusCodes | ForEach-Object { if ($_ -eq 200) { '{"code":0}' } else { '{"code":-1}' } })
    }

    $statusesJson = $StatusCodes | ConvertTo-Json -Compress
    $bodiesJson = $Bodies | ConvertTo-Json -Compress
    $job = Start-Job -ScriptBlock {
        param($Port, $StatusesJson, $ResponseBodiesJson, $ReadyPath)

        $parsedStatuses = $StatusesJson | ConvertFrom-Json
        $parsedBodies = $ResponseBodiesJson | ConvertFrom-Json
        $Statuses = @($parsedStatuses | ForEach-Object { [int]$_ })
        $ResponseBodies = @($parsedBodies | ForEach-Object { [string]$_ })

        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        [System.IO.File]::WriteAllText($ReadyPath, 'ready')
        try {
            for ($index = 0; $index -lt $Statuses.Count; $index++) {
                $client = $listener.AcceptTcpClient()
                try {
                    $stream = $client.GetStream()
                    $headerBytes = New-Object System.Collections.Generic.List[byte]
                    $tail = ''
                    while ($tail -ne "`r`n`r`n") {
                        $value = $stream.ReadByte()
                        if ($value -lt 0) { break }
                        $headerBytes.Add([byte]$value)
                        $tail += [char]$value
                        if ($tail.Length -gt 4) { $tail = $tail.Substring($tail.Length - 4) }
                    }

                    $headerText = [System.Text.Encoding]::ASCII.GetString($headerBytes.ToArray())
                    $contentLength = 0
                    $lengthMatch = [regex]::Match($headerText, '(?im)^Content-Length:\s*(\d+)\s*$')
                    if ($lengthMatch.Success) {
                        $contentLength = [int]$lengthMatch.Groups[1].Value
                    }
                    $buffer = New-Object byte[] 4096
                    while ($contentLength -gt 0) {
                        $read = $stream.Read($buffer, 0, [Math]::Min($buffer.Length, $contentLength))
                        if ($read -le 0) { break }
                        $contentLength -= $read
                    }

                    $status = [int]$Statuses[$index]
                    $body = [string]$ResponseBodies[[Math]::Min($index, $ResponseBodies.Count - 1)]
                    $reason = switch ($status) {
                        200 { 'OK' }
                        400 { 'Bad Request' }
                        429 { 'Too Many Requests' }
                        500 { 'Internal Server Error' }
                        default { 'Status' }
                    }
                    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
                    $headers = "HTTP/1.1 $status $reason`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
                    $responseBytes = [System.Text.Encoding]::ASCII.GetBytes($headers)
                    $stream.Write($responseBytes, 0, $responseBytes.Length)
                    $stream.Write($bodyBytes, 0, $bodyBytes.Length)
                    $stream.Flush()
                }
                finally {
                    $client.Dispose()
                }
            }
        }
        finally {
            $listener.Stop()
        }
    } -ArgumentList $port, $statusesJson, $bodiesJson, $readyPath

    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $readyPath)) {
        if ([DateTime]::UtcNow -gt $deadline) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            throw 'Mock HTTP server did not start.'
        }
        Start-Sleep -Milliseconds 50
    }

    return [pscustomobject]@{
        Job  = $job
        Url  = 'http://127.0.0.1:{0}/hook' -f $port
        ReadyPath = $readyPath
    }
}

function Stop-MockHttpServer {
    param($Server)
    if ($null -eq $Server) { return }
    Wait-Job -Job $Server.Job -Timeout 10 | Out-Null
    Stop-Job -Job $Server.Job -ErrorAction SilentlyContinue
    Receive-Job -Job $Server.Job -ErrorAction SilentlyContinue | Out-Null
    Remove-Job -Job $Server.Job -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Server.ReadyPath -Force -ErrorAction SilentlyContinue
}

function Reset-DeliveryState {
    $paths = Get-NotifierPaths
    foreach ($directory in @($paths.Queue, $paths.Sent, $paths.DeadLetter)) {
        if (Test-Path -LiteralPath $directory) {
            Get-ChildItem -LiteralPath $directory -File -ErrorAction SilentlyContinue | Remove-Item -Force
        }
    }
    if (Test-Path -LiteralPath $paths.State) {
        Remove-Item -LiteralPath $paths.State -Force
    }
}

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    . $scriptPath -Action Library -DataRoot $dataRoot -BridgeDataRoot $bridgeDataRoot -HooksPath $hooksPath -AllowInsecureEndpoint
    $script:RetryDelaysSeconds = @(0, 0, 0)
    $script:HttpTimeoutSeconds = 2

    $expectedSignature = 'wSds2BzzFIIGf/WrhUO+NI1q/9j+FRJd3JNHKAq0NZY='
    $actualSignature = Get-FeishuSignature -Timestamp 1599360473 -Secret 'test-secret'
    Assert-Equal $actualSignature $expectedSignature 'Feishu HMAC fixed vector'

    Assert-Equal (ConvertTo-SafeProjectName -Cwd '') $script:Text.UnknownProject 'Empty cwd is safe'
    Assert-Equal (ConvertTo-SafeProjectName -Cwd 'C:\') 'C:' 'Drive root is represented safely'
    Assert-Equal (ConvertTo-SafeProjectName -Cwd 'C:\work\project') 'project' 'Only the cwd leaf is used'
    $unsafeProject = ConvertTo-SafeProjectName -Cwd 'C:\work\bad<at user_id="all">&name'
    Assert-True (-not $unsafeProject.Contains('<') -and -not $unsafeProject.Contains('>') -and -not $unsafeProject.Contains('&')) 'Feishu mention characters are neutralized'
    Assert-Equal (ConvertTo-SafeProjectName -Cwd ('C:\work\' + ('x' * 200))).Length 120 'Long project names are capped'
    $chineseName = ConvertFrom-Json '"\u9879\u76ee\u7532"'
    Assert-Equal (ConvertTo-SafeProjectName -Cwd ('C:\work\' + $chineseName)) $chineseName 'Unicode project names survive'

    Save-ProtectedSettings -Url 'http://127.0.0.1:12345/hook' -Secret 'dpapi-secret'
    $roundTrip = Get-ProtectedSettings
    Assert-Equal $roundTrip.webhookUrl 'http://127.0.0.1:12345/hook' 'DPAPI preserves webhook URL'
    Assert-Equal $roundTrip.signingSecret 'dpapi-secret' 'DPAPI preserves signing secret'
    $protectedRaw = [System.IO.File]::ReadAllText((Get-NotifierPaths).Config)
    Assert-True (-not $protectedRaw.Contains('dpapi-secret')) 'DPAPI file contains no plaintext secret'

    $existingDocument = [pscustomobject][ordered]@{
        description = 'existing'
        hooks = [pscustomobject][ordered]@{
            Stop = @(
                [pscustomobject][ordered]@{
                    hooks = @([pscustomobject][ordered]@{ type = 'command'; command = 'existing-command' })
                }
            )
        }
    }
    Write-JsonAtomic -Path $hooksPath -Value $existingDocument
    Assert-True (Install-NotifierHook) 'Installer adds the notifier hook'
    Assert-True (-not (Install-NotifierHook)) 'Installer is idempotent'
    $installedHooks = Read-HooksDocument
    $allHandlers = @($installedHooks.hooks.Stop | ForEach-Object { @($_.hooks) })
    Assert-Equal (@($allHandlers | Where-Object { $_.command -eq 'existing-command' }).Count) 1 'Installer preserves an existing hook'
    Assert-Equal (@($allHandlers | Where-Object { Test-IsNotifierHandler $_ }).Count) 1 'Installer adds exactly one notifier hook'
    Assert-True (Uninstall-NotifierHook) 'Uninstaller removes the notifier hook'
    $remainingHooks = Read-HooksDocument
    Assert-Equal @($remainingHooks.hooks.Stop).Count 1 'Uninstaller preserves unrelated hook groups'
    Assert-Equal $remainingHooks.hooks.Stop[0].hooks[0].command 'existing-command' 'Uninstaller preserves unrelated commands'

    Reset-DeliveryState
    $hookEvent = [pscustomobject]@{
        hook_event_name       = 'Stop'
        session_id            = 'session-1'
        turn_id               = 'turn-1'
        cwd                   = 'C:\private\project-one'
        last_assistant_message = 'TOP SECRET FINAL RESPONSE'
        prompt                = 'TOP SECRET PROMPT'
    }
    Assert-True (Try-EnqueueNotification -HookEvent $hookEvent) 'First Stop event is queued'
    Assert-True (-not (Try-EnqueueNotification -HookEvent $hookEvent)) 'Duplicate Stop event is ignored'
    $queueFiles = @(Get-ChildItem -LiteralPath (Get-NotifierPaths).Queue -Filter '*.json' -File)
    Assert-Equal $queueFiles.Count 1 'Only one queue job exists per turn'
    $queueRaw = [System.IO.File]::ReadAllText($queueFiles[0].FullName)
    Assert-True (-not $queueRaw.Contains('TOP SECRET')) 'Queue excludes prompt and final response'
    Assert-True (-not $queueRaw.Contains('C:\private')) 'Queue excludes the full cwd'
    Assert-True (-not $queueRaw.Contains('session-1') -and -not $queueRaw.Contains('turn-1')) 'Queue stores only a hash of session and turn IDs'
    Assert-True ($queueRaw.Contains('project-one')) 'Queue includes the safe project leaf'
    $sessionFiles = @(Get-ChildItem -LiteralPath (Get-BridgePaths).Sessions -Filter '*.json' -File)
    Assert-Equal $sessionFiles.Count 1 'Stop events create one local conversation mapping'
    $sessionRaw = [System.IO.File]::ReadAllText($sessionFiles[0].FullName)
    Assert-True ($sessionRaw.Contains('session-1') -and $sessionRaw.Contains('project-one')) 'Conversation mapping stores only the local session target and project leaf'
    Assert-True (-not $sessionRaw.Contains('TOP SECRET')) 'Conversation mapping excludes prompt and final response'

    [System.IO.File]::WriteAllText((Get-BridgePaths).Config, 'configured')
    $bridgeState = [ordered]@{
        schema = 1
        allowedOpenIds = @('open-user')
        defaultChatByUser = [ordered]@{ 'open-user' = 'chat-one' }
        activeSessionByUser = [ordered]@{}
        pairing = $null
    }
    Write-JsonAtomic -Path (Get-BridgePaths).State -Value $bridgeState
    $bridgeMessage = New-NotificationMessage -Project 'project-one' -OccurredAt ([DateTimeOffset]::Now) -ConversationCode 'A72F19C304'
    Assert-True (Try-EnqueueBridgeCompletion -EventKey ('a' * 64) -ConversationCode 'A72F19C304' -Message $bridgeMessage) 'Configured application bot receives completion outbox jobs'
    $bridgeOutboxFiles = @(Get-ChildItem -LiteralPath (Get-BridgePaths).Outbox -Filter '*.json' -File)
    Assert-Equal $bridgeOutboxFiles.Count 1 'Bridge completion outbox deduplicates by event key'
    $bridgeOutboxRaw = [System.IO.File]::ReadAllText($bridgeOutboxFiles[0].FullName)
    Assert-True ($bridgeOutboxRaw.Contains('chat-one') -and $bridgeOutboxRaw.Contains('A72F19C304')) 'Bridge outbox targets the paired chat and anonymous conversation code'
    Assert-True (-not $bridgeOutboxRaw.Contains('session-1')) 'Bridge outbox excludes the local Codex session ID'

    Reset-DeliveryState
    $eventJson = $hookEvent | ConvertTo-Json -Compress
    $jobs = @()
    for ($index = 0; $index -lt 8; $index++) {
        $jobs += Start-Job -ScriptBlock {
            param($NotifierPath, $NotifierDataRoot, $NotifierBridgeDataRoot, $NotifierHooksPath, $Json)
            . $NotifierPath -Action Library -DataRoot $NotifierDataRoot -BridgeDataRoot $NotifierBridgeDataRoot -HooksPath $NotifierHooksPath -AllowInsecureEndpoint
            $eventObject = $Json | ConvertFrom-Json
            Try-EnqueueNotification -HookEvent $eventObject | Out-Null
        } -ArgumentList $scriptPath, $dataRoot, $bridgeDataRoot, $hooksPath, $eventJson
    }
    $jobs | Wait-Job -Timeout 30 | Out-Null
    $jobs | Receive-Job -ErrorAction SilentlyContinue | Out-Null
    $jobs | Remove-Job -Force
    Assert-Equal @(Get-ChildItem -LiteralPath (Get-NotifierPaths).Queue -Filter '*.json' -File).Count 1 'Concurrent duplicate Stop events create one job'

    $server = Start-MockHttpServer -StatusCodes @(200) -Bodies @('{"code":0}')
    try {
        $successResult = Invoke-FeishuRequest -Url $server.Url -Secret 'test-secret' -Message 'hello'
        Assert-Equal $successResult.Kind 'Success' 'HTTP 200 with Feishu code 0 succeeds'
    }
    finally { Stop-MockHttpServer $server }

    $server = Start-MockHttpServer -StatusCodes @(429)
    try {
        $limitedResult = Invoke-FeishuRequest -Url $server.Url -Secret 'test-secret' -Message 'hello'
        Assert-Equal $limitedResult.Kind 'Transient' 'HTTP 429 is retryable'
    }
    finally { Stop-MockHttpServer $server }

    $server = Start-MockHttpServer -StatusCodes @(500)
    try {
        $serverResult = Invoke-FeishuRequest -Url $server.Url -Secret 'test-secret' -Message 'hello'
        Assert-Equal $serverResult.Kind 'Transient' 'HTTP 500 is retryable'
    }
    finally { Stop-MockHttpServer $server }

    $server = Start-MockHttpServer -StatusCodes @(400)
    try {
        $badRequestResult = Invoke-FeishuRequest -Url $server.Url -Secret 'test-secret' -Message 'hello'
        Assert-Equal $badRequestResult.Kind 'Permanent' 'HTTP 400 is permanent'
    }
    finally { Stop-MockHttpServer $server }

    $server = Start-MockHttpServer -StatusCodes @(200) -Bodies @('{"code":19021}')
    try {
        $signResult = Invoke-FeishuRequest -Url $server.Url -Secret 'test-secret' -Message 'hello'
        Assert-Equal $signResult.Kind 'Permanent' 'Feishu signature error is permanent'
    }
    finally { Stop-MockHttpServer $server }

    $unusedPort = Get-FreeTcpPort
    $networkResult = Invoke-FeishuRequest -Url ('http://127.0.0.1:{0}/hook' -f $unusedPort) -Secret 'test-secret' -Message 'hello'
    Assert-Equal $networkResult.Kind 'Transient' 'Network failure is retryable'

    Reset-DeliveryState
    $server = Start-MockHttpServer -StatusCodes @(500, 429, 200) -Bodies @('{"code":-1}', '{"code":-1}', '{"code":0}')
    try {
        Save-ProtectedSettings -Url $server.Url -Secret 'test-secret'
        Assert-True (Try-EnqueueNotification -HookEvent $hookEvent) 'Retry test job is queued'
        Invoke-NotifierWorker
        $retryQueueCount = @(Get-ChildItem -LiteralPath (Get-NotifierPaths).Queue -Filter '*.json' -File).Count
        $retrySentCount = @(Get-ChildItem -LiteralPath (Get-NotifierPaths).Sent -Filter '*.done' -File).Count
        $retryDeadCount = @(Get-ChildItem -LiteralPath (Get-NotifierPaths).DeadLetter -Filter '*.json' -File).Count
        Assert-Equal $retryQueueCount 0 'Successful retry drains the queue'
        Assert-Equal $retrySentCount 1 'Successful retry writes a sent marker'
        Assert-Equal $retryDeadCount 0 'Successful retry avoids dead-letter'
    }
    finally { Stop-MockHttpServer $server }

    Reset-DeliveryState
    $server = Start-MockHttpServer -StatusCodes @(400)
    try {
        Save-ProtectedSettings -Url $server.Url -Secret 'test-secret'
        Assert-True (Try-EnqueueNotification -HookEvent $hookEvent) 'Permanent-failure test job is queued'
        Invoke-NotifierWorker
        Assert-Equal @(Get-ChildItem -LiteralPath (Get-NotifierPaths).Queue -Filter '*.json' -File).Count 0 'Permanent failure leaves no active queue job'
        Assert-Equal @(Get-ChildItem -LiteralPath (Get-NotifierPaths).DeadLetter -Filter '*.json' -File).Count 1 'Permanent failure moves the job to dead-letter'
    }
    finally { Stop-MockHttpServer $server }

    Write-Host ''
    Write-Host ('Tests passed: {0}; failed: {1}' -f $script:Passed, $script:Failed)
    if ($script:Failed -gt 0) {
        exit 1
    }
}
finally {
    Get-Job -ErrorAction SilentlyContinue | Where-Object { $_.State -ne 'Completed' } | Stop-Job -ErrorAction SilentlyContinue
    Get-Job -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
        $resolvedTemp = [System.IO.Path]::GetFullPath($env:TEMP)
        if ($resolvedTestRoot.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and $resolvedTestRoot -like '*CodexFeishuNotifier-tests-*') {
            Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
        }
    }
}
