# handler.ps1 — agentbox MCP-Handler-Daemon (Template)
#
# Laeuft persistent auf der Windows-Host-Seite, gestartet vom Scheduled
# Task 'agentbox-mcp-dispatcher' bei Logon. Lauscht auf
# %LOCALAPPDATA%\agentbox\mcp-runtime\<id>\requests\ via FileSystemWatcher,
# verarbeitet jede .req.json und schreibt die Antwort in ../responses/.
#
# Der Daemon bekommt seine MCP-ID ueber $env:AGENTBOX_MCP_ID (vom
# Dispatcher gesetzt) und ermittelt daraus den Runtime-Pfad.
#
# WICHTIG:
# - Tools.json (im Projekt-Ordner) in den Runtime-Ordner spiegeln, damit
#   die Sandbox-Seite die Tool-Liste lesen kann.
# - daemon.heartbeat alle N Sekunden touchen (Sandbox-Proxy checkt das).
# - Antworten im MCP tools/call-Response-Schema schreiben:
#     { "content": [ { "type": "text", "text": "..." } ] }
#
# Dieses Template implementiert EIN Tool ("echo"). Austauschen durch
# eigene Logik und tools.json entsprechend erweitern.

$ErrorActionPreference = "Stop"

# --- Konfiguration ---
$mcpId = $env:AGENTBOX_MCP_ID
if ([string]::IsNullOrEmpty($mcpId)) {
    Write-Error "AGENTBOX_MCP_ID env var ist nicht gesetzt — Handler muss vom agentbox-mcp-dispatcher gestartet werden."
    exit 2
}

$runtimeBase = Join-Path $env:LOCALAPPDATA "agentbox\mcp-runtime\$mcpId"
$requestsDir = Join-Path $runtimeBase "requests"
$responsesDir = Join-Path $runtimeBase "responses"
$heartbeatFile = Join-Path $runtimeBase "daemon.heartbeat"
$pidFile = Join-Path $runtimeBase "daemon.pid"
$logFile = Join-Path $runtimeBase "handler.log"

[System.IO.Directory]::CreateDirectory($runtimeBase) | Out-Null
[System.IO.Directory]::CreateDirectory($requestsDir) | Out-Null
[System.IO.Directory]::CreateDirectory($responsesDir) | Out-Null

# --- Tools.json in Runtime-Ordner spiegeln ---
# Die Sandbox-Seite liest die Tool-Deklaration aus dem Runtime-Ordner
# (nicht aus dem Projekt-Ordner, der nicht in der Sandbox sichtbar ist).
$projectTools = Join-Path $PSScriptRoot "tools.json"
$runtimeTools = Join-Path $runtimeBase "tools.json"
if (Test-Path -LiteralPath $projectTools) {
    Copy-Item -LiteralPath $projectTools -Destination $runtimeTools -Force
}

# --- Logging ---
function Write-HandlerLog {
    param([string]$Message, [string]$Level = "INFO")
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Level -- $Message"
    try { Add-Content -LiteralPath $logFile -Value $line -Encoding utf8 } catch { }
}

# --- PID + Heartbeat ---
$PID | Out-File -LiteralPath $pidFile -Encoding ascii -NoNewline -Force
New-Item -ItemType File -Path $heartbeatFile -Force | Out-Null

Write-HandlerLog "handler.ps1 started (pid=$PID, runtime=$runtimeBase)"

# --- Tool-Implementation ---
# Fuer eigene MCPs: diese Funktion ersetzen. Parameter:
#   $Tool  — Tool-Name aus tools/call (string)
#   $McpArgs — arguments-Objekt aus dem MCP-Call (PSCustomObject)
# Rueckgabe: Hashtable im tools/call-Response-Schema:
#   @{ content = @(@{ type = "text"; text = "..." }) }
# Fehler: @{ error = "message" } zurueckgeben; der Proxy wandelt das
# automatisch in ein isError-Tool-Result um.
function Invoke-McpTool {
    param(
        [Parameter(Mandatory)][string]$Tool,
        [Parameter(Mandatory)][PSCustomObject]$McpArgs
    )

    switch ($Tool) {
        "echo" {
            $text = if ($null -ne $McpArgs.text) { [string]$McpArgs.text } else { "" }
            return @{
                content = @(
                    @{ type = "text"; text = $text }
                )
            }
        }
        default {
            return @{ error = "unknown tool: $Tool" }
        }
    }
}

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
    $reqArgs = if ($null -ne $reqJson.arguments) { $reqJson.arguments } else { New-Object PSObject }

    if ([string]::IsNullOrEmpty($reqId) -or [string]::IsNullOrEmpty($tool)) {
        Write-HandlerLog "invalid request (missing id or tool): $ReqPath" "WARN"
        try { [System.IO.File]::Delete($ReqPath) } catch { }
        return
    }

    Write-HandlerLog "request id=$reqId tool=$tool"

    $response = $null
    try {
        $response = Invoke-McpTool -Tool $tool -McpArgs $reqArgs
    } catch {
        $response = @{ error = "handler exception: $($_.Exception.Message)" }
        Write-HandlerLog "handler exception (tool=$tool): $($_.Exception.Message)" "ERROR"
    }

    $resPath = Join-Path $responsesDir "$reqId.res.json"
    $tmpPath = "$resPath.tmp"
    try {
        $responseJson = $response | ConvertTo-Json -Depth 20 -Compress
        [System.IO.File]::WriteAllText($tmpPath, $responseJson, (New-Object System.Text.UTF8Encoding $false))
        # Atomic rename, damit der Sandbox-Proxy keine halb-geschriebene
        # Datei liest.
        [System.IO.File]::Move($tmpPath, $resPath)
    } catch {
        Write-HandlerLog "response write fail (id=$reqId): $($_.Exception.Message)" "ERROR"
        try { [System.IO.File]::Delete($tmpPath) } catch { }
    }

    # Request-File hat sich erledigt — der Proxy entfernt es auch, aber
    # wir loeschen es defensiv mit, damit liegen gebliebene Requests
    # nicht doppelt verarbeitet werden.
    try { [System.IO.File]::Delete($ReqPath) } catch { }
}

# --- Initiale Sweeps: alle bestehenden Requests abarbeiten ---
# Nach einem Daemon-Restart koennen Requests liegen, die waehrend des
# Downtime-Fensters eingegangen sind. Erst Sweep, dann Watcher starten.
Get-ChildItem -LiteralPath $requestsDir -Filter "*.req.json" -ErrorAction SilentlyContinue |
    Sort-Object CreationTime |
    ForEach-Object { Process-Request -ReqPath $_.FullName }

# --- FileSystemWatcher ---
$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = $requestsDir
$watcher.Filter = "*.req.json"
$watcher.NotifyFilter = [System.IO.NotifyFilters]::FileName -bor [System.IO.NotifyFilters]::LastWrite
$watcher.IncludeSubdirectories = $false
$watcher.EnableRaisingEvents = $true

$srcCreated = "agentbox-mcp-$mcpId-created"
$srcRenamed = "agentbox-mcp-$mcpId-renamed"
Register-ObjectEvent -InputObject $watcher -EventName "Created" -SourceIdentifier $srcCreated -Action {
    $p = $Event.SourceEventArgs.FullPath
    try { Process-Request -ReqPath $p } catch {
        Write-HandlerLog "watcher handler crashed: $($_.Exception.Message)" "ERROR"
    }
} | Out-Null
Register-ObjectEvent -InputObject $watcher -EventName "Renamed" -SourceIdentifier $srcRenamed -Action {
    $p = $Event.SourceEventArgs.FullPath
    try { Process-Request -ReqPath $p } catch {
        Write-HandlerLog "watcher handler crashed: $($_.Exception.Message)" "ERROR"
    }
} | Out-Null

Write-HandlerLog "watcher active — entering heartbeat loop"

# --- Heartbeat-Loop ---
# Alle 10s `daemon.heartbeat` touchen — die Sandbox-Seite interpretiert
# eine aeltere Timestamp als "Daemon tot". Gleichzeitig nutzen wir das
# Sleep-Interval fuer Safety-Sweeps (fuer den Fall, dass der Watcher
# wegen DrvFs-9P-Events ein File nicht sieht — theoretisch nicht
# noetig, weil Runtime auf NTFS liegt, aber billige Paranoia-Massnahme).
try {
    while ($true) {
        try {
            (Get-Item -LiteralPath $heartbeatFile).LastWriteTime = Get-Date
        } catch {
            New-Item -ItemType File -Path $heartbeatFile -Force | Out-Null
        }

        # Safety-Sweep: falls ein Request-File sich in den letzten
        # 10s angesammelt hat und der Watcher ihn verpasst hat.
        Get-ChildItem -LiteralPath $requestsDir -Filter "*.req.json" -ErrorAction SilentlyContinue |
            ForEach-Object { Process-Request -ReqPath $_.FullName }

        Start-Sleep -Seconds 10
    }
} finally {
    Write-HandlerLog "handler shutting down"
    Unregister-Event -SourceIdentifier $srcCreated -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier $srcRenamed -ErrorAction SilentlyContinue
    $watcher.EnableRaisingEvents = $false
    $watcher.Dispose()
    try { [System.IO.File]::Delete($pidFile) } catch { }
}
