# win-mcp-dispatcher.ps1
# agentbox -- MCP-Dispatcher (HTTP/SSE-Variante, 2.5.0)
#
# Laeuft als Scheduled Task "agentbox-mcp-dispatcher" (AtLogon +
# RestartOnFailure). Liest config.json mcp_servers, weist Ports zu,
# spawnt pro Eintrag `npx mcp-proxy --port N -- <command> [args]` und
# supervised die Prozesse (Restart-on-Crash). Schreibt die Port-
# Zuordnung nach %LOCALAPPDATA%\agentbox\mcp-runtime\ports.json.

param(
    [int]$HeartbeatInterval = 5,
    [switch]$RunOnce
)

$ErrorActionPreference = "Continue"

# --- baseDir / controlDir aufloesen ---
if ($env:OneDrive) {
    $baseDir = Join-Path $env:OneDrive "AI_Projects_Source"
} elseif ($PSScriptRoot -and $PSScriptRoot -match '(.+)[\\/]_control$') {
    $baseDir = $Matches[1]
} else {
    Write-Host "FEHLER: baseDir nicht ermittelbar." -ForegroundColor Red
    exit 1
}
$controlDir = Join-Path $baseDir "_control"
$configPath = Join-Path $controlDir "config.json"

$config = $null
try {
    if (Test-Path -LiteralPath $configPath) {
        $config = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop | ConvertFrom-Json
    }
} catch {
    Write-Host "[WARN] config.json nicht lesbar -- dispatcher exitet." -ForegroundColor Yellow
    exit 0
}

if ($config -and $config.base_path_override -and $config.base_path_override -ne "") {
    $baseDir = $config.base_path_override
    $controlSubdir = if ($config.control_dir_name) { $config.control_dir_name } else { "_control" }
    $controlDir = Join-Path $baseDir $controlSubdir
}

$runtimeBase = Join-Path $env:LOCALAPPDATA "agentbox\mcp-runtime"
[System.IO.Directory]::CreateDirectory($runtimeBase) | Out-Null

$dispatcherLog = Join-Path $runtimeBase "dispatcher.log"
$portsFile = Join-Path $runtimeBase "ports.json"

function Write-DispatcherLog {
    param([string]$Message, [string]$Level = "INFO")
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Level -- $Message"
    try { Add-Content -LiteralPath $dispatcherLog -Value $line -Encoding utf8 } catch { }
    Write-Host $line
}

# --- MCP-Server extrahieren ---
# Rueckgabe: Liste von PSCustomObject mit Feldern:
#   Id, Command, Args (string[]), McpEnv (Hashtable),
#   Cwd (string/leer), PinnedPort (int/0 wenn auto)
function Get-McpServers {
    param($Cfg)
    $out = @()
    if (-not $Cfg) { return $out }
    if (-not $Cfg.PSObject.Properties['mcp_servers']) { return $out }
    $list = $Cfg.mcp_servers
    if (-not $list) { return $out }
    foreach ($s in $list) {
        if (-not $s) { continue }
        $sid = if ($s.PSObject.Properties['id']) { [string]$s.id } else { "" }
        $cmd = if ($s.PSObject.Properties['command']) { [string]$s.command } else { "" }
        if ([string]::IsNullOrWhiteSpace($sid) -or [string]::IsNullOrWhiteSpace($cmd)) { continue }

        $argsList = @()
        if ($s.PSObject.Properties['args'] -and $s.args) {
            $argsList = @($s.args | ForEach-Object { [string]$_ })
        }
        $envHash = @{}
        if ($s.PSObject.Properties['env'] -and $s.env) {
            foreach ($p in $s.env.PSObject.Properties) {
                $envHash[$p.Name] = [string]$p.Value
            }
        }
        $cwd = if ($s.PSObject.Properties['cwd']) { [string]$s.cwd } else { "" }
        $pinned = 0
        if ($s.PSObject.Properties['port'] -and $s.port) {
            try { $pinned = [int]$s.port } catch { $pinned = 0 }
        }
        $out += [PSCustomObject]@{
            Id         = $sid.Trim()
            Command    = $cmd.Trim()
            Args       = $argsList
            McpEnv     = $envHash
            Cwd        = $cwd
            PinnedPort = $pinned
        }
    }
    return $out
}

# --- Port-frei-Check ---
function Test-PortFree {
    param([int]$Port)
    $listener = $null
    try {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $Port)
        $listener.Start()
        return $true
    } catch {
        return $false
    } finally {
        if ($listener) { try { $listener.Stop() } catch { } }
    }
}

# --- Port-Assign: Phase 1 (pinned) + Phase 2 (auto) ---
function Assign-Ports {
    param([array]$Servers)
    $assigned = @{}
    $usedPorts = @{}

    # Phase 1: pinned
    foreach ($s in $Servers) {
        if ($s.PinnedPort -gt 0) {
            if ($usedPorts.ContainsKey($s.PinnedPort)) {
                Write-DispatcherLog "MCP '$($s.Id)': Port $($s.PinnedPort) doppelt in config.json -- skipped" "ERROR"
                continue
            }
            if (-not (Test-PortFree -Port $s.PinnedPort)) {
                Write-DispatcherLog "MCP '$($s.Id)': Port $($s.PinnedPort) belegt -- skipped" "ERROR"
                continue
            }
            $assigned[$s.Id] = $s.PinnedPort
            $usedPorts[$s.PinnedPort] = $true
        }
    }

    # Phase 2: auto ab 9000
    $cursor = 9000
    foreach ($s in $Servers) {
        if ($assigned.ContainsKey($s.Id)) { continue }
        if ($s.PinnedPort -gt 0) { continue }  # pinned aber konflikt -> weggeworfen
        $tries = 0
        while ($tries -lt 100) {
            if (-not $usedPorts.ContainsKey($cursor) -and (Test-PortFree -Port $cursor)) {
                $assigned[$s.Id] = $cursor
                $usedPorts[$cursor] = $true
                $cursor++
                break
            }
            $cursor++
            $tries++
        }
        if (-not $assigned.ContainsKey($s.Id)) {
            Write-DispatcherLog "MCP '$($s.Id)': kein freier Port in 9000-$($cursor) -- skipped" "ERROR"
        }
    }
    return $assigned
}

# --- mcp-proxy per MCP starten ---
function Start-McpProxy {
    param(
        [Parameter(Mandatory)][PSCustomObject]$Spec,
        [Parameter(Mandatory)][int]$Port
    )

    $runtimeDir = Join-Path $runtimeBase $Spec.Id
    [System.IO.Directory]::CreateDirectory($runtimeDir) | Out-Null
    $bridgeLog = Join-Path $runtimeDir "bridge.log"

    # Argument-Liste fuer npx zusammenbauen. mcp-proxy akzeptiert:
    #   mcp-proxy --port <n> --shell -- <command> [args...]
    # Shell-Wrapping ist wichtig, weil 'python' auf Windows oft nur
    # ueber cmd.exe aufloesbar ist.
    $npxArgs = @(
        "-y",
        "mcp-proxy",
        "--port", $Port.ToString(),
        "--shell"
    )
    # nur --host wenn mcp-proxy das unterstuetzt -- neuere Versionen tun das.
    # Default ist 0.0.0.0 was wir brauchen. Wenn mcp-proxy default 127.0.0.1 hat,
    # explizit setzen.
    $npxArgs += @("--host", "0.0.0.0")
    $npxArgs += @("--")
    $npxArgs += $Spec.Command
    foreach ($a in $Spec.Args) { $npxArgs += $a }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "npx.cmd"
    foreach ($a in $npxArgs) {
        if ($a -match '\s|"') { $psi.Arguments += '"' + ($a -replace '"', '\"') + '" ' }
        else { $psi.Arguments += $a + " " }
    }
    $psi.Arguments = $psi.Arguments.TrimEnd()

    if (-not [string]::IsNullOrEmpty($Spec.Cwd)) {
        $psi.WorkingDirectory = $Spec.Cwd
    }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    foreach ($k in $Spec.McpEnv.Keys) {
        $psi.EnvironmentVariables[$k] = [string]$Spec.McpEnv[$k]
    }

    Write-DispatcherLog "MCP '$($Spec.Id)': starte mcp-proxy --port $Port -- $($Spec.Command) $($Spec.Args -join ' ')"

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)

        # Stdout/Stderr asynchron in bridge.log schreiben.
        $stdoutEvent = {
            param($sender, $e)
            if ($e.Data) {
                try { Add-Content -LiteralPath $Event.MessageData -Value $e.Data -Encoding utf8 } catch { }
            }
        }
        Register-ObjectEvent -InputObject $proc -EventName "OutputDataReceived" `
            -Action $stdoutEvent -MessageData $bridgeLog `
            -SourceIdentifier "mcp-proxy-stdout-$($Spec.Id)" | Out-Null
        Register-ObjectEvent -InputObject $proc -EventName "ErrorDataReceived" `
            -Action $stdoutEvent -MessageData $bridgeLog `
            -SourceIdentifier "mcp-proxy-stderr-$($Spec.Id)" | Out-Null
        $proc.BeginOutputReadLine()
        $proc.BeginErrorReadLine()

        Write-DispatcherLog "MCP '$($Spec.Id)': gestartet (pid=$($proc.Id), port=$Port)" "OK"
        return $proc
    } catch {
        Write-DispatcherLog "MCP '$($Spec.Id)': Start fehlgeschlagen -- $($_.Exception.Message)" "ERROR"
        return $null
    }
}

# --- Ports.json schreiben ---
function Write-PortsJson {
    param([hashtable]$Assigned)
    $obj = New-Object PSObject
    foreach ($k in ($Assigned.Keys | Sort-Object)) {
        $obj | Add-Member -NotePropertyName $k -NotePropertyValue $Assigned[$k]
    }
    $json = $obj | ConvertTo-Json
    [System.IO.File]::WriteAllText($portsFile, $json, (New-Object System.Text.UTF8Encoding $false))
}

# --- Hauptschleife ---
Write-DispatcherLog "=== agentbox MCP Dispatcher gestartet (pid=$PID) ==="

$servers = Get-McpServers -Cfg $config
if ($servers.Count -eq 0) {
    Write-DispatcherLog "mcp_servers leer -- dispatcher exitet clean."
    if (Test-Path -LiteralPath $portsFile) { try { [System.IO.File]::Delete($portsFile) } catch { } }
    exit 0
}

# npx pruefen
$npxCmd = Get-Command npx.cmd -ErrorAction SilentlyContinue
if (-not $npxCmd) {
    Write-DispatcherLog "npx.cmd nicht gefunden -- Node.js fehlt? install.ps1 als Admin rerunnen." "ERROR"
    exit 1
}

$ports = Assign-Ports -Servers $servers
Write-PortsJson -Assigned $ports

$running = @{}
foreach ($s in $servers) {
    if (-not $ports.ContainsKey($s.Id)) { continue }
    $proc = Start-McpProxy -Spec $s -Port $ports[$s.Id]
    if ($proc) { $running[$s.Id] = $proc }
}

if ($RunOnce) {
    Write-DispatcherLog "RunOnce-Mode -- dispatcher exitet nach initialem Start."
    exit 0
}

# Supervisor-Loop
try {
    while ($true) {
        Start-Sleep -Seconds $HeartbeatInterval
        foreach ($s in $servers) {
            if (-not $ports.ContainsKey($s.Id)) { continue }
            $proc = $running[$s.Id]
            $alive = $proc -and -not $proc.HasExited
            if (-not $alive) {
                Write-DispatcherLog "MCP '$($s.Id)': tot -- restart" "WARN"
                # Event-Subscribers aufraeumen
                Get-EventSubscriber -SourceIdentifier "mcp-proxy-*-$($s.Id)" -ErrorAction SilentlyContinue | Unregister-Event
                $newProc = Start-McpProxy -Spec $s -Port $ports[$s.Id]
                if ($newProc) { $running[$s.Id] = $newProc }
                else { $running.Remove($s.Id) }
            }
        }
        if ($running.Count -eq 0) {
            Write-DispatcherLog "Alle MCPs tot und nicht neustartbar -- dispatcher exitet." "WARN"
            exit 1
        }
    }
} finally {
    Write-DispatcherLog "dispatcher shutting down -- beende $($running.Count) Prozesse"
    foreach ($kv in $running.GetEnumerator()) {
        try { if (-not $kv.Value.HasExited) { $kv.Value.Kill() } } catch { }
    }
    Get-EventSubscriber -SourceIdentifier "mcp-proxy-*" -ErrorAction SilentlyContinue | Unregister-Event
}
