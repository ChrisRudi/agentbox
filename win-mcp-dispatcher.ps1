# win-mcp-dispatcher.ps1
# agentbox -- MCP handler daemon dispatcher
#
# Laeuft als Scheduled Task "agentbox-mcp-dispatcher" (AtLogon +
# RestartOnFailure). Liest config.json mcp_servers, startet fuer jeden
# aktivierten Eintrag den Handler-Daemon (build.command aus project.json)
# als Child-Prozess, ueberwacht die Child-PIDs und restartet bei Crashes.
#
# Warum kein Task pro MCP-Server: eine einzelne dispatcher-Task skaliert
# einfacher, ein Install/Uninstall eines MCPs benoetigt keinen erneuten
# Task-Registry-Call, Lifecycle bleibt zentral.
#
# Warum nicht Scheduled-Task-pro-Handler: Scheduled Tasks sind
# schwergewichtig (Registry-writes, XML-Definitionen), und der
# RestartOnFailure-Logic im TS ist tricky (delay, max retry count).
# Ein einfacher PowerShell-Supervisor mit Start-Process + Polling ist
# transparent und debuggbar.
#
# Der Dispatcher selbst ist stumm bei fehlender Config und exitet clean
# — so bricht nichts, wenn ein User mcp_servers leer laesst (Default).

param(
    [int]$HeartbeatInterval = 5,
    [switch]$RunOnce
)

$ErrorActionPreference = "Continue"

# --- baseDir / controlDir auflosen (selbe Logik wie win-task-runner.ps1) ---
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
    Write-Host "[WARN] config.json nicht lesbar — dispatcher exitet." -ForegroundColor Yellow
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
function Write-DispatcherLog {
    param([string]$Message, [string]$Level = "INFO")
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Level -- $Message"
    try { Add-Content -LiteralPath $dispatcherLog -Value $line -Encoding utf8 } catch { }
    Write-Host $line
}

# --- MCP-Server aus config.json extrahieren ---
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
        $proj = if ($s.PSObject.Properties['project']) { [string]$s.project } else { "" }
        if ([string]::IsNullOrWhiteSpace($sid) -or [string]::IsNullOrWhiteSpace($proj)) { continue }
        $out += [PSCustomObject]@{ Id = $sid.Trim(); Project = $proj.Trim() }
    }
    return $out
}

# --- Handler-Daemon starten ---
# Whitelist-check wie win-task-runner: build.command muss in
# project.json.build_whitelist stehen. build_whitelist ist hier
# die Projekt-lokale Liste (nicht die globale aus config.json) —
# jeder MCP-Handler definiert seine erlaubten Commands selbst.
function Start-McpHandler {
    param(
        [Parameter(Mandatory)][string]$McpId,
        [Parameter(Mandatory)][string]$ProjectName
    )

    $projectDir = Join-Path $baseDir $ProjectName
    if (-not (Test-Path -LiteralPath $projectDir)) {
        Write-DispatcherLog "MCP '$McpId': Projekt '$ProjectName' nicht gefunden unter $baseDir" "WARN"
        return $null
    }

    $projectJsonPath = Join-Path $projectDir "project.json"
    if (-not (Test-Path -LiteralPath $projectJsonPath)) {
        Write-DispatcherLog "MCP '$McpId': project.json fehlt in $projectDir" "WARN"
        return $null
    }

    $projectConfig = $null
    try {
        $projectConfig = Get-Content -LiteralPath $projectJsonPath -Raw | ConvertFrom-Json
    } catch {
        Write-DispatcherLog "MCP '$McpId': project.json nicht parsbar — $($_.Exception.Message)" "ERROR"
        return $null
    }

    if (-not $projectConfig.build -or -not $projectConfig.build.command) {
        Write-DispatcherLog "MCP '$McpId': build.command fehlt in project.json" "WARN"
        return $null
    }
    $buildCmd = [string]$projectConfig.build.command

    # Lokale Whitelist pruefen (Projekt-eigenes build_whitelist).
    $whitelist = @()
    if ($projectConfig.PSObject.Properties['build_whitelist'] -and $projectConfig.build_whitelist) {
        $whitelist = @($projectConfig.build_whitelist)
    }
    if ($whitelist.Count -eq 0) {
        Write-DispatcherLog "MCP '$McpId': build_whitelist in project.json ist leer — Handler nicht gestartet (security)" "ERROR"
        return $null
    }
    if ($whitelist -notcontains $buildCmd) {
        Write-DispatcherLog "MCP '$McpId': build.command nicht in build_whitelist — Handler nicht gestartet" "ERROR"
        return $null
    }

    # Runtime-Ordner anlegen
    $runtimeDir = Join-Path $runtimeBase $McpId
    [System.IO.Directory]::CreateDirectory((Join-Path $runtimeDir "requests")) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $runtimeDir "responses")) | Out-Null

    Write-DispatcherLog "MCP '$McpId': starte Handler — $buildCmd (cwd=$projectDir)"

    # Env-Vars fuer den Handler setzen und via cmd.exe starten.
    # Start-Process mit -PassThru gibt das Process-Objekt zurueck,
    # damit wir PID/HasExited beobachten koennen.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "cmd.exe"
    $psi.Arguments = "/c $buildCmd"
    $psi.WorkingDirectory = $projectDir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $false
    $psi.RedirectStandardError = $false
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables["AGENTBOX_MCP_ID"] = $McpId
    $psi.EnvironmentVariables["AGENTBOX_MCP_RUNTIME"] = $runtimeDir

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        Write-DispatcherLog "MCP '$McpId': Handler gestartet (pid=$($proc.Id))" "OK"
        return $proc
    } catch {
        Write-DispatcherLog "MCP '$McpId': Handler-Start fehlgeschlagen — $($_.Exception.Message)" "ERROR"
        return $null
    }
}

# --- Hauptschleife ---
Write-DispatcherLog "=== agentbox MCP Dispatcher gestartet (pid=$PID) ==="

$servers = Get-McpServers -Cfg $config
if ($servers.Count -eq 0) {
    Write-DispatcherLog "mcp_servers leer — nichts zu tun, dispatcher exitet clean."
    exit 0
}

# Map mcpId -> [System.Diagnostics.Process]
$running = @{}

foreach ($s in $servers) {
    $proc = Start-McpHandler -McpId $s.Id -ProjectName $s.Project
    if ($proc) { $running[$s.Id] = $proc }
}

if ($RunOnce) {
    Write-DispatcherLog "RunOnce-Mode — dispatcher exitet nach initialem Start."
    exit 0
}

# Supervisor-Loop: Handler-Crashes erkennen und neu starten.
try {
    while ($true) {
        Start-Sleep -Seconds $HeartbeatInterval

        foreach ($s in $servers) {
            $proc = $running[$s.Id]
            $alive = $proc -and -not $proc.HasExited
            if (-not $alive) {
                Write-DispatcherLog "MCP '$($s.Id)': Handler tot — restart" "WARN"
                $newProc = Start-McpHandler -McpId $s.Id -ProjectName $s.Project
                if ($newProc) { $running[$s.Id] = $newProc }
                else {
                    # Start fehlgeschlagen — raus aus der Map, sonst endlose
                    # Restart-Versuche auf einem kaputten Projekt.
                    $running.Remove($s.Id)
                }
            }
        }

        # Alles tot → dispatcher beenden, Scheduled Task RestartOnFailure
        # uebernimmt.
        if ($running.Count -eq 0) {
            Write-DispatcherLog "Alle Handler tot und nicht neustartbar — dispatcher exitet (Scheduled Task wird neu starten)."
            exit 1
        }
    }
} finally {
    Write-DispatcherLog "dispatcher shutting down — beende $($running.Count) Handler"
    foreach ($kv in $running.GetEnumerator()) {
        try {
            if (-not $kv.Value.HasExited) {
                $kv.Value.Kill()
            }
        } catch { }
    }
}
