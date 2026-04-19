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
# Rueckgabe: Liste von PSCustomObject mit Feldern:
#   Id        : MCP-ID
#   Tier      : 1 (passthrough / standard import) oder 2 (agentbox-project)
#   Command   : Tier 1 only (z.B. "python")
#   Args      : Tier 1 only (string[])
#   McpEnv    : Tier 1 only (Hashtable)
#   Cwd       : Tier 1 only (optional string)
#   Project   : Tier 2 only (folder name)
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
        if ([string]::IsNullOrWhiteSpace($sid)) { continue }
        $sid = $sid.Trim()

        $cmd = if ($s.PSObject.Properties['command']) { [string]$s.command } else { "" }
        $proj = if ($s.PSObject.Properties['project']) { [string]$s.project } else { "" }

        if (-not [string]::IsNullOrWhiteSpace($cmd)) {
            # Tier 1: Standard-MCP-Import
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
            $out += [PSCustomObject]@{
                Id      = $sid
                Tier    = 1
                Command = $cmd.Trim()
                Args    = $argsList
                McpEnv  = $envHash
                Cwd     = $cwd
                Project = ""
            }
        }
        elseif (-not [string]::IsNullOrWhiteSpace($proj)) {
            # Tier 2: agentbox-project
            $out += [PSCustomObject]@{
                Id      = $sid
                Tier    = 2
                Command = ""
                Args    = @()
                McpEnv  = @{}
                Cwd     = ""
                Project = $proj.Trim()
            }
        }
        else {
            Write-DispatcherLog "MCP '$sid': weder command noch project gesetzt -- Eintrag uebersprungen" "WARN"
        }
    }
    return $out
}

# --- Tier 1: generischer Passthrough starten ---
function Start-McpTier1Handler {
    param([Parameter(Mandatory)][PSCustomObject]$Spec)

    $passthroughScript = Join-Path $scriptDir "proxy-mcp\passthrough-handler.ps1"
    if (-not (Test-Path -LiteralPath $passthroughScript)) {
        Write-DispatcherLog "MCP '$($Spec.Id)': passthrough-handler.ps1 fehlt unter $passthroughScript" "ERROR"
        return $null
    }

    # Runtime-Ordner anlegen
    $runtimeDir = Join-Path $runtimeBase $Spec.Id
    [System.IO.Directory]::CreateDirectory((Join-Path $runtimeDir "requests")) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $runtimeDir "responses")) | Out-Null

    # Args/Env als JSON an den Wrapper reichen (ENV-Vars sind strings only).
    $argsJson = (ConvertTo-Json -InputObject $Spec.Args -Compress -Depth 5)
    # ConvertTo-Json auf ein leeres Array gibt "[]" korrekt zurueck -- gut.
    if ([string]::IsNullOrEmpty($argsJson) -or $argsJson -eq 'null') { $argsJson = '[]' }

    $envJson = '{}'
    if ($Spec.McpEnv.Count -gt 0) {
        $envJson = (ConvertTo-Json -InputObject $Spec.McpEnv -Compress -Depth 5)
    }

    $cmdSummary = "$($Spec.Command) $($Spec.Args -join ' ')"
    Write-DispatcherLog "MCP '$($Spec.Id)' [Tier 1]: starte Passthrough-Wrapper -- $cmdSummary"

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$passthroughScript`""
    if (-not [string]::IsNullOrEmpty($Spec.Cwd)) {
        $psi.WorkingDirectory = $Spec.Cwd
    }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables["AGENTBOX_MCP_ID"] = $Spec.Id
    $psi.EnvironmentVariables["AGENTBOX_MCP_CMD"] = $Spec.Command
    $psi.EnvironmentVariables["AGENTBOX_MCP_ARGS_JSON"] = $argsJson
    $psi.EnvironmentVariables["AGENTBOX_MCP_ENV_JSON"] = $envJson
    if (-not [string]::IsNullOrEmpty($Spec.Cwd)) {
        $psi.EnvironmentVariables["AGENTBOX_MCP_CWD"] = $Spec.Cwd
    }

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        Write-DispatcherLog "MCP '$($Spec.Id)': Passthrough gestartet (pid=$($proc.Id))" "OK"
        return $proc
    } catch {
        Write-DispatcherLog "MCP '$($Spec.Id)': Passthrough-Start fehlgeschlagen -- $($_.Exception.Message)" "ERROR"
        return $null
    }
}

# --- Tier 2: agentbox-Projekt-Handler starten ---
# Whitelist-check wie win-task-runner: build.command muss in
# project.json.build_whitelist stehen. Tier 2 ist Opt-In-Pfad fuer
# User, die ihren MCP innerhalb von agentbox als eigenes Projekt
# entwickeln.
function Start-McpTier2Handler {
    param([Parameter(Mandatory)][PSCustomObject]$Spec)

    $projectDir = Join-Path $baseDir $Spec.Project
    if (-not (Test-Path -LiteralPath $projectDir)) {
        Write-DispatcherLog "MCP '$($Spec.Id)' [Tier 2]: Projekt '$($Spec.Project)' nicht gefunden unter $baseDir" "WARN"
        return $null
    }

    $projectJsonPath = Join-Path $projectDir "project.json"
    if (-not (Test-Path -LiteralPath $projectJsonPath)) {
        Write-DispatcherLog "MCP '$($Spec.Id)': project.json fehlt in $projectDir" "WARN"
        return $null
    }

    $projectConfig = $null
    try {
        $projectConfig = Get-Content -LiteralPath $projectJsonPath -Raw | ConvertFrom-Json
    } catch {
        Write-DispatcherLog "MCP '$($Spec.Id)': project.json nicht parsbar -- $($_.Exception.Message)" "ERROR"
        return $null
    }

    if (-not $projectConfig.build -or -not $projectConfig.build.command) {
        Write-DispatcherLog "MCP '$($Spec.Id)': build.command fehlt in project.json" "WARN"
        return $null
    }
    $buildCmd = [string]$projectConfig.build.command

    $whitelist = @()
    if ($projectConfig.PSObject.Properties['build_whitelist'] -and $projectConfig.build_whitelist) {
        $whitelist = @($projectConfig.build_whitelist)
    }
    if ($whitelist.Count -eq 0) {
        Write-DispatcherLog "MCP '$($Spec.Id)': build_whitelist in project.json ist leer -- Handler nicht gestartet (security)" "ERROR"
        return $null
    }
    if ($whitelist -notcontains $buildCmd) {
        Write-DispatcherLog "MCP '$($Spec.Id)': build.command nicht in build_whitelist -- Handler nicht gestartet" "ERROR"
        return $null
    }

    $runtimeDir = Join-Path $runtimeBase $Spec.Id
    [System.IO.Directory]::CreateDirectory((Join-Path $runtimeDir "requests")) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $runtimeDir "responses")) | Out-Null

    Write-DispatcherLog "MCP '$($Spec.Id)' [Tier 2]: starte Handler -- $buildCmd (cwd=$projectDir)"

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "cmd.exe"
    $psi.Arguments = "/c $buildCmd"
    $psi.WorkingDirectory = $projectDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables["AGENTBOX_MCP_ID"] = $Spec.Id
    $psi.EnvironmentVariables["AGENTBOX_MCP_RUNTIME"] = $runtimeDir

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        Write-DispatcherLog "MCP '$($Spec.Id)': Handler gestartet (pid=$($proc.Id))" "OK"
        return $proc
    } catch {
        Write-DispatcherLog "MCP '$($Spec.Id)': Handler-Start fehlgeschlagen -- $($_.Exception.Message)" "ERROR"
        return $null
    }
}

# Tier-Dispatcher.
function Start-McpHandler {
    param([Parameter(Mandatory)][PSCustomObject]$Spec)
    if ($Spec.Tier -eq 1) { return Start-McpTier1Handler -Spec $Spec }
    if ($Spec.Tier -eq 2) { return Start-McpTier2Handler -Spec $Spec }
    Write-DispatcherLog "MCP '$($Spec.Id)': unbekannter Tier=$($Spec.Tier)" "ERROR"
    return $null
}

# $scriptDir wird spaeter benutzt (Passthrough-Script-Pfad). Hier fuer
# Klarheit explizit gesetzt -- egal ob aus _control/ oder mitgeklontem
# Entwicklungs-Checkout gestartet.
$scriptDir = $PSScriptRoot
if (-not $scriptDir) {
    $scriptDir = $controlDir
}

# --- Hauptschleife ---
Write-DispatcherLog "=== agentbox MCP Dispatcher gestartet (pid=$PID) ==="

$servers = Get-McpServers -Cfg $config
if ($servers.Count -eq 0) {
    Write-DispatcherLog "mcp_servers leer -- dispatcher exitet clean."
    exit 0
}

# Map mcpId -> [System.Diagnostics.Process]
$running = @{}

foreach ($s in $servers) {
    $proc = Start-McpHandler -Spec $s
    if ($proc) { $running[$s.Id] = $proc }
}

if ($RunOnce) {
    Write-DispatcherLog "RunOnce-Mode -- dispatcher exitet nach initialem Start."
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
                Write-DispatcherLog "MCP '$($s.Id)': Handler tot -- restart" "WARN"
                $newProc = Start-McpHandler -Spec $s
                if ($newProc) { $running[$s.Id] = $newProc }
                else {
                    # Start fehlgeschlagen -- raus aus der Map, sonst endlose
                    # Restart-Versuche auf einem kaputten Eintrag.
                    $running.Remove($s.Id)
                }
            }
        }

        # Alles tot -> dispatcher beenden, Scheduled Task RestartOnFailure
        # uebernimmt.
        if ($running.Count -eq 0) {
            Write-DispatcherLog "Alle Handler tot und nicht neustartbar -- dispatcher exitet (Scheduled Task wird neu starten)."
            exit 1
        }
    }
} finally {
    Write-DispatcherLog "dispatcher shutting down -- beende $($running.Count) Handler"
    foreach ($kv in $running.GetEnumerator()) {
        try {
            if (-not $kv.Value.HasExited) {
                $kv.Value.Kill()
            }
        } catch { }
    }
}
