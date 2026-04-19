# passthrough-handler.ps1
# agentbox -- generischer MCP-Passthrough-Wrapper (Tier 1)
#
# Spawnt einen beliebigen bestehenden stdio-MCP-Server (z.B. KiCad_MCP,
# GitHub-MCP, Filesystem-MCP) als Child-Prozess und forwarded die
# agentbox-File-Queue 1:1 auf seinen JSON-RPC-Stdio-Kanal. So laesst
# sich **jeder** MCP-Server, der die Claude-Desktop/Cursor-Standard-
# Config versteht, ohne Custom-Code in agentbox einbinden.
#
# Aufruf durch den Dispatcher, der per ENV-Vars konfiguriert:
#   AGENTBOX_MCP_ID        - MCP-ID aus config.json
#   AGENTBOX_MCP_CMD       - executable (z.B. "python", "node", "npx", "uv")
#   AGENTBOX_MCP_ARGS_JSON - JSON-Array, z.B. '["-m","kicad_mcp"]'
#   AGENTBOX_MCP_ENV_JSON  - JSON-Object (optional), z.B. '{"KICAD_PATH":"..."}'
#   AGENTBOX_MCP_CWD       - optional, working-dir fuer den Child
#
# Flow:
#   1. Child spawnen mit Stdin/Stdout-Pipe, ENV-Vars injizieren.
#   2. Async-Stdout-Reader schreibt empfangene JSON-RPC-Responses in
#      eine ConcurrentDictionary<id, response>.
#   3. `initialize` + `tools/list` an Child senden, Antwort abwarten,
#      Tools in runtime/tools.json spiegeln.
#   4. FileSystemWatcher auf requests/; pro Request-File:
#        - Parse {id, tool, arguments}
#        - JSON-RPC-Call bauen mit interner ID, an Child stdin schreiben
#        - Auf Response mit passender ID warten (Timeout 30s)
#        - `result` unwrappen, in responses/<id>.res.json schreiben
#   5. daemon.heartbeat alle 10s touchen, Watchdog prueft Child auf Leben.
#
# Bei Child-Crash: Handler exitet mit !=0 -> Dispatcher startet uns neu.

$ErrorActionPreference = "Stop"

# --- Konfiguration ---
$mcpId = $env:AGENTBOX_MCP_ID
$mcpCmd = $env:AGENTBOX_MCP_CMD
$mcpArgsJson = $env:AGENTBOX_MCP_ARGS_JSON
$mcpEnvJson = $env:AGENTBOX_MCP_ENV_JSON
$mcpCwd = $env:AGENTBOX_MCP_CWD

if ([string]::IsNullOrEmpty($mcpId)) {
    Write-Error "AGENTBOX_MCP_ID nicht gesetzt."
    exit 2
}
if ([string]::IsNullOrEmpty($mcpCmd)) {
    Write-Error "AGENTBOX_MCP_CMD nicht gesetzt."
    exit 2
}

$runtimeBase = Join-Path $env:LOCALAPPDATA "agentbox\mcp-runtime\$mcpId"
$requestsDir = Join-Path $runtimeBase "requests"
$responsesDir = Join-Path $runtimeBase "responses"
$heartbeatFile = Join-Path $runtimeBase "daemon.heartbeat"
$pidFile = Join-Path $runtimeBase "daemon.pid"
$toolsFile = Join-Path $runtimeBase "tools.json"
$logFile = Join-Path $runtimeBase "handler.log"

[System.IO.Directory]::CreateDirectory($runtimeBase) | Out-Null
[System.IO.Directory]::CreateDirectory($requestsDir) | Out-Null
[System.IO.Directory]::CreateDirectory($responsesDir) | Out-Null

function Write-HandlerLog {
    param([string]$Message, [string]$Level = "INFO")
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Level -- $Message"
    try { Add-Content -LiteralPath $logFile -Value $line -Encoding utf8 } catch { }
}

Write-HandlerLog "passthrough-handler starting: id=$mcpId cmd=$mcpCmd args=$mcpArgsJson"

# --- Args parsen ---
$mcpArgs = @()
if (-not [string]::IsNullOrEmpty($mcpArgsJson)) {
    try {
        $parsed = $mcpArgsJson | ConvertFrom-Json -ErrorAction Stop
        if ($parsed -is [array]) {
            $mcpArgs = @($parsed | ForEach-Object { [string]$_ })
        } else {
            Write-HandlerLog "AGENTBOX_MCP_ARGS_JSON ist kein Array -- ignoriere" "WARN"
        }
    } catch {
        Write-HandlerLog "AGENTBOX_MCP_ARGS_JSON parse failed: $($_.Exception.Message)" "ERROR"
        exit 3
    }
}

# --- Child-Prozess vorbereiten ---
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $mcpCmd
foreach ($a in $mcpArgs) { $psi.ArgumentList.Add($a) 2>$null }
# ArgumentList gibt's erst ab .NET 5 -- Fallback fuer PS 5.1 / .NET Framework:
if ($psi.ArgumentList.Count -eq 0 -and $mcpArgs.Count -gt 0) {
    $quoted = $mcpArgs | ForEach-Object {
        if ($_ -match '\s|"') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }
    $psi.Arguments = ($quoted -join " ")
}
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $true
$psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
$psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
if (-not [string]::IsNullOrEmpty($mcpCwd)) {
    $psi.WorkingDirectory = $mcpCwd
}

# ENV-Vars aus JSON injizieren (optional)
if (-not [string]::IsNullOrEmpty($mcpEnvJson)) {
    try {
        $envObj = $mcpEnvJson | ConvertFrom-Json -ErrorAction Stop
        foreach ($prop in $envObj.PSObject.Properties) {
            $psi.EnvironmentVariables[$prop.Name] = [string]$prop.Value
        }
    } catch {
        Write-HandlerLog "AGENTBOX_MCP_ENV_JSON parse failed: $($_.Exception.Message)" "WARN"
    }
}

# --- Child starten ---
$child = $null
try {
    $child = [System.Diagnostics.Process]::Start($psi)
} catch {
    Write-HandlerLog "Child-Start fehlgeschlagen: $($_.Exception.Message)" "ERROR"
    exit 4
}
Write-HandlerLog "Child gestartet: pid=$($child.Id)"

# --- Response-Matching via ConcurrentDictionary ---
# Wir speichern JSON-RPC-Responses (Hashtable aus ConvertFrom-Json) unter
# ihrer id. Der Request-Handler pollt dieses Dict bis "seine" id drin
# ist. Thread-safe, weil OutputDataReceived asynchron feuert.
$script:ResponseMap = [System.Collections.Concurrent.ConcurrentDictionary[string, string]]::new()
$script:ChildExited = $false

# --- Async-Stdout-Reader ---
# Process.OutputDataReceived feuert pro Zeile. Jede Zeile ist eine MCP-
# JSON-RPC-Nachricht (Response oder Notification). Wir filtern auf
# "id"-haltige Antworten und stecken sie in die Map.
$stdoutHandler = {
    param($senderObj, $e)
    if ($null -eq $e.Data) { return }
    $line = $e.Data.Trim()
    if ([string]::IsNullOrEmpty($line)) { return }
    try {
        $msg = $line | ConvertFrom-Json -ErrorAction Stop
        if ($msg.PSObject.Properties['id'] -and $null -ne $msg.id) {
            $idStr = [string]$msg.id
            # Raw-Zeile speichern, nicht geparsed -- spart uns
            # Rekonstruktions-Kosten fuer das relay.
            [void]$script:ResponseMap.TryAdd($idStr, $line)
        }
        # Notifications (ohne id) werden verworfen -- MCP-Server
        # schicken die z.B. fuer notifications/tools/list_changed, fuer
        # unseren Sandbox-Vertrag uninteressant, weil wir tools.json
        # ohnehin nur beim Start spiegeln.
    } catch {
        # Kein gueltiges JSON -- manche MCP-Server loggen Debug-Ausgaben
        # auf stdout. Loggen und weiterziehen.
        Write-HandlerLog "non-JSON stdout line: $line" "DEBUG"
    }
}
$stderrHandler = {
    param($senderObj, $e)
    if ($null -eq $e.Data) { return }
    $line = $e.Data.Trim()
    if (-not [string]::IsNullOrEmpty($line)) {
        Write-HandlerLog "[child-stderr] $line" "CHILD"
    }
}
$exitHandler = {
    $script:ChildExited = $true
    Write-HandlerLog "Child beendet (exit=$($senderObj.ExitCode))" "WARN"
}

Register-ObjectEvent -InputObject $child -EventName "OutputDataReceived" `
    -Action $stdoutHandler -SourceIdentifier "agentbox-pt-stdout-$mcpId" | Out-Null
Register-ObjectEvent -InputObject $child -EventName "ErrorDataReceived" `
    -Action $stderrHandler -SourceIdentifier "agentbox-pt-stderr-$mcpId" | Out-Null
$child.EnableRaisingEvents = $true
Register-ObjectEvent -InputObject $child -EventName "Exited" `
    -Action $exitHandler -SourceIdentifier "agentbox-pt-exit-$mcpId" | Out-Null

$child.BeginOutputReadLine()
$child.BeginErrorReadLine()

# --- JSON-RPC-Helper ---
$script:NextRpcId = 1
$script:RpcIdLock = New-Object object

function Get-NextRpcId {
    [System.Threading.Monitor]::Enter($script:RpcIdLock)
    try {
        $id = $script:NextRpcId
        $script:NextRpcId++
        return "pt-$id"
    } finally {
        [System.Threading.Monitor]::Exit($script:RpcIdLock)
    }
}

function Send-ChildRpc {
    param(
        [Parameter(Mandatory)][string]$Method,
        $Params,
        [string]$OverrideId = $null,
        [int]$TimeoutSeconds = 30
    )
    if ($script:ChildExited) {
        throw "child has exited"
    }
    $rpcId = if ($OverrideId) { $OverrideId } else { Get-NextRpcId }
    $msg = @{ jsonrpc = "2.0"; id = $rpcId; method = $Method }
    if ($null -ne $Params) {
        $msg.params = $Params
    }
    $json = $msg | ConvertTo-Json -Depth 20 -Compress

    try {
        $child.StandardInput.WriteLine($json)
        $child.StandardInput.Flush()
    } catch {
        throw "stdin write failed: $($_.Exception.Message)"
    }

    # Auf Response warten
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $raw = $null
    while ((Get-Date) -lt $deadline) {
        if ($script:ChildExited) { throw "child exited during rpc wait" }
        $ok = $script:ResponseMap.TryRemove($rpcId, [ref]$raw)
        if ($ok) {
            return ($raw | ConvertFrom-Json)
        }
        Start-Sleep -Milliseconds 20
    }
    throw "rpc timeout ($TimeoutSeconds s) for $Method"
}

function Send-ChildNotification {
    param(
        [Parameter(Mandatory)][string]$Method,
        $Params
    )
    if ($script:ChildExited) { return }
    $msg = @{ jsonrpc = "2.0"; method = $Method }
    if ($null -ne $Params) { $msg.params = $Params }
    $json = $msg | ConvertTo-Json -Depth 20 -Compress
    try {
        $child.StandardInput.WriteLine($json)
        $child.StandardInput.Flush()
    } catch { }
}

# --- MCP-Handshake + Tools spiegeln ---
try {
    $initResp = Send-ChildRpc -Method "initialize" -Params @{
        protocolVersion = "2024-11-05"
        capabilities = @{}
        clientInfo = @{ name = "agentbox-passthrough"; version = "1.0.0" }
    } -TimeoutSeconds 15
    Write-HandlerLog "initialize ok (server=$($initResp.result.serverInfo.name) v$($initResp.result.serverInfo.version))"
    Send-ChildNotification -Method "notifications/initialized"

    $toolsResp = Send-ChildRpc -Method "tools/list" -TimeoutSeconds 15
    $tools = if ($toolsResp.result.tools) { $toolsResp.result.tools } else { @() }
    $toolsPayload = @{ tools = $tools } | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($toolsFile, $toolsPayload, (New-Object System.Text.UTF8Encoding $false))
    Write-HandlerLog "tools/list: $($tools.Count) tools gespiegelt nach $toolsFile"
} catch {
    Write-HandlerLog "MCP-Handshake fehlgeschlagen: $($_.Exception.Message)" "ERROR"
    try { $child.Kill() } catch { }
    exit 5
}

# --- PID + Heartbeat anlegen ---
$PID | Out-File -LiteralPath $pidFile -Encoding ascii -NoNewline -Force
New-Item -ItemType File -Path $heartbeatFile -Force | Out-Null

# --- Request-Verarbeitung ---
function Process-Request {
    param([string]$ReqPath)

    if (-not (Test-Path -LiteralPath $ReqPath)) { return }

    $reqJson = $null
    try {
        $reqRaw = Get-Content -LiteralPath $ReqPath -Raw -ErrorAction Stop
        $reqJson = $reqRaw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-HandlerLog "request parse fail ($ReqPath): $($_.Exception.Message)" "WARN"
        try { [System.IO.File]::Delete($ReqPath) } catch { }
        return
    }

    $reqId = [string]$reqJson.id
    $tool = [string]$reqJson.tool
    $arguments = if ($null -ne $reqJson.arguments) { $reqJson.arguments } else { New-Object PSObject }

    if ([string]::IsNullOrEmpty($reqId) -or [string]::IsNullOrEmpty($tool)) {
        Write-HandlerLog "invalid request (missing id/tool): $ReqPath" "WARN"
        try { [System.IO.File]::Delete($ReqPath) } catch { }
        return
    }

    Write-HandlerLog "request id=$reqId tool=$tool"

    $response = $null
    try {
        $rpcResp = Send-ChildRpc -Method "tools/call" -Params @{
            name = $tool
            arguments = $arguments
        } -TimeoutSeconds 30
        if ($rpcResp.PSObject.Properties['error'] -and $rpcResp.error) {
            $response = @{
                content = @(@{ type = "text"; text = "MCP-server error: $($rpcResp.error.message)" })
                isError = $true
            }
        } elseif ($rpcResp.PSObject.Properties['result']) {
            # Das MCP-tools/call-result-Schema ist direkt das, was der
            # Sandbox-Proxy sehen will ({content:[...], isError?}). 1:1.
            $response = $rpcResp.result
        } else {
            $response = @{ error = "empty rpc response" }
        }
    } catch {
        $response = @{ error = "passthrough exception: $($_.Exception.Message)" }
        Write-HandlerLog "passthrough exception (tool=$tool): $($_.Exception.Message)" "ERROR"
    }

    $resPath = Join-Path $responsesDir "$reqId.res.json"
    $tmpPath = "$resPath.tmp"
    try {
        $responseJson = $response | ConvertTo-Json -Depth 20 -Compress
        [System.IO.File]::WriteAllText($tmpPath, $responseJson, (New-Object System.Text.UTF8Encoding $false))
        [System.IO.File]::Move($tmpPath, $resPath)
    } catch {
        Write-HandlerLog "response write fail (id=$reqId): $($_.Exception.Message)" "ERROR"
        try { [System.IO.File]::Delete($tmpPath) } catch { }
    }

    try { [System.IO.File]::Delete($ReqPath) } catch { }
}

# --- Initialer Sweep ---
Get-ChildItem -LiteralPath $requestsDir -Filter "*.req.json" -ErrorAction SilentlyContinue |
    Sort-Object CreationTime |
    ForEach-Object { Process-Request -ReqPath $_.FullName }

# --- FileSystemWatcher ---
$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = $requestsDir
$watcher.Filter = "*.req.json"
$watcher.NotifyFilter = [System.IO.NotifyFilters]::FileName -bor [System.IO.NotifyFilters]::LastWrite
$watcher.EnableRaisingEvents = $true

$srcCreated = "agentbox-pt-req-created-$mcpId"
$srcRenamed = "agentbox-pt-req-renamed-$mcpId"
Register-ObjectEvent -InputObject $watcher -EventName "Created" -SourceIdentifier $srcCreated -Action {
    try { Process-Request -ReqPath $Event.SourceEventArgs.FullPath } catch {
        Write-HandlerLog "watcher crashed: $($_.Exception.Message)" "ERROR"
    }
} | Out-Null
Register-ObjectEvent -InputObject $watcher -EventName "Renamed" -SourceIdentifier $srcRenamed -Action {
    try { Process-Request -ReqPath $Event.SourceEventArgs.FullPath } catch {
        Write-HandlerLog "watcher crashed: $($_.Exception.Message)" "ERROR"
    }
} | Out-Null

Write-HandlerLog "watcher active -- entering heartbeat loop"

# --- Heartbeat + Child-Liveness-Check ---
try {
    while ($true) {
        if ($script:ChildExited -or $child.HasExited) {
            Write-HandlerLog "Child ist tot -- passthrough beendet" "WARN"
            break
        }
        try {
            (Get-Item -LiteralPath $heartbeatFile).LastWriteTime = Get-Date
        } catch {
            New-Item -ItemType File -Path $heartbeatFile -Force | Out-Null
        }

        # Safety-Sweep (Watcher-Glitch-Absicherung)
        Get-ChildItem -LiteralPath $requestsDir -Filter "*.req.json" -ErrorAction SilentlyContinue |
            ForEach-Object { Process-Request -ReqPath $_.FullName }

        Start-Sleep -Seconds 10
    }
} finally {
    Write-HandlerLog "passthrough shutting down"
    Unregister-Event -SourceIdentifier $srcCreated -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier $srcRenamed -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier "agentbox-pt-stdout-$mcpId" -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier "agentbox-pt-stderr-$mcpId" -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier "agentbox-pt-exit-$mcpId" -ErrorAction SilentlyContinue
    $watcher.EnableRaisingEvents = $false
    $watcher.Dispose()
    try { if (-not $child.HasExited) { $child.Kill() } } catch { }
    try { [System.IO.File]::Delete($pidFile) } catch { }
}
# Bewusster non-zero-Exit, damit der Dispatcher uns neu startet wenn der
# Child gestorben ist (z.B. Agent hat `kill` geschickt oder Server crash).
exit 6
