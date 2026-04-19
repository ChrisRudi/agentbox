# setup-kicad-mcp.ps1
# agentbox -- One-shot Setup fuer den KiCad 10 MCP-Server.
#
# Laeuft alles in einem Rutsch durch:
#  1. Python 3.10+ + KiCad 10 vorhanden? Auto-Detect oder Prompt.
#  2. KiCad_MCP-Ordner finden (Parameter, cwd, oder Prompt).
#  3. `pip install -e ".[dev]"` in Windows-Python.
#  4. agentbox _control-Ordner finden (OneDrive-Default oder Prompt).
#  5. config.json smart-mergen: kicad-Eintrag hinzufuegen, vorhandene
#     mcp_servers-Eintraege bleiben unangetastet.
#  6. agentbox-mcp-dispatcher Scheduled Task stoppen + neu starten.
#  7. Logs tailen und Status-Ampel ausgeben.
#
# Aufruf (z.B.):
#   # Default-Detect (interaktive Prompts fuer Unklares)
#   .\setup-kicad-mcp.ps1
#
#   # Vollautomatisch mit allen Parametern
#   .\setup-kicad-mcp.ps1 `
#       -KicadMcpPath "C:\Users\chris\OneDrive\AI_Projects_Source\KiCad_MCP" `
#       -KicadCliPath "C:\Program Files\KiCad\10.0\bin\kicad-cli.exe" `
#       -PythonPath "C:\Python312\python.exe" `
#       -SearchPaths "C:\Users\chris\Documents\KiCad","C:\Users\chris\OneDrive\AI_Projects_Source"
#
#   # Per One-Liner aus GitHub
#   irm https://raw.githubusercontent.com/ChrisRudi/agentbox/main/setup-kicad-mcp.ps1 | iex
#
# Anforderungen:
#  - Windows PowerShell 5.1+ (PS 7 auch ok)
#  - Keine Admin-Rechte (wenn der Scheduled Task 'agentbox-mcp-dispatcher'
#    bereits existiert -- den registriert install.ps1 einmalig als Admin
#    und muss beim Erst-Setup gelaufen sein).
#
# Idempotent: mehrfacher Aufruf ueberschreibt den kicad-Eintrag in
# config.json ohne Schaden, laesst andere MCPs unangetastet.

[CmdletBinding()]
param(
    [string]$KicadMcpPath = "",
    [string]$KicadCliPath = "",
    [string]$PythonPath = "",
    [string[]]$SearchPaths = @(),
    [string]$AgentboxControlDir = "",
    [string]$McpId = "kicad",
    [switch]$SkipPipInstall,
    [switch]$NonInteractive
)

$ErrorActionPreference = "Stop"

# --- Farb-Helper ---
function Write-Step   { param($msg) Write-Host ""; Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok     { param($msg) Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Warn   { param($msg) Write-Host "    [WARN] $msg" -ForegroundColor Yellow }
function Write-Err    { param($msg) Write-Host "    [FEHLER] $msg" -ForegroundColor Red }
function Write-Info   { param($msg) Write-Host "    $msg" -ForegroundColor Gray }

function Read-RequiredPath {
    param([string]$Prompt, [string]$Default = "", [switch]$MustExist)
    if ($NonInteractive) {
        throw "NonInteractive-Modus: $Prompt ist Pflicht."
    }
    while ($true) {
        $hint = if ($Default) { " [$Default]" } else { "" }
        $in = Read-Host "$Prompt$hint"
        if ([string]::IsNullOrWhiteSpace($in) -and $Default) { $in = $Default }
        if ([string]::IsNullOrWhiteSpace($in)) {
            Write-Warn "Leere Eingabe. Nochmal."
            continue
        }
        if ($MustExist -and -not (Test-Path -LiteralPath $in)) {
            Write-Warn "Pfad existiert nicht: $in"
            continue
        }
        return $in
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " agentbox <- KiCad 10 MCP Setup" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# --- 1. Python-Pfad bestimmen ---
Write-Step "1/7 Python auf Windows-Host suchen"

if (-not $PythonPath) {
    $cands = @()
    try {
        $cmd = Get-Command python.exe -ErrorAction SilentlyContinue
        if ($cmd) { $cands += $cmd.Source }
    } catch { }
    try {
        $cmd = Get-Command py.exe -ErrorAction SilentlyContinue
        if ($cmd) {
            $out = & py -3 -c "import sys; print(sys.executable)" 2>$null
            if ($out) { $cands += $out.Trim() }
        }
    } catch { }
    $cands = $cands | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
    if ($cands.Count -eq 0) {
        Write-Warn "Keine python.exe auf PATH gefunden."
        $PythonPath = Read-RequiredPath -Prompt "Absoluter Pfad zu python.exe (3.10+)" -MustExist
    } elseif ($cands.Count -eq 1) {
        $PythonPath = $cands[0]
    } else {
        Write-Info "Mehrere Python-Interpreter gefunden:"
        for ($i = 0; $i -lt $cands.Count; $i++) {
            Write-Info "  [$($i+1)] $($cands[$i])"
        }
        if ($NonInteractive) { $PythonPath = $cands[0] }
        else {
            $pick = Read-Host "Auswahl [1]"
            if ([string]::IsNullOrWhiteSpace($pick)) { $pick = "1" }
            $idx = [int]$pick - 1
            if ($idx -lt 0 -or $idx -ge $cands.Count) { $idx = 0 }
            $PythonPath = $cands[$idx]
        }
    }
}

# Version pruefen
try {
    $verRaw = & $PythonPath --version 2>&1
    if ($verRaw -match 'Python\s+(\d+)\.(\d+)') {
        $major = [int]$Matches[1]; $minor = [int]$Matches[2]
        if ($major -lt 3 -or ($major -eq 3 -and $minor -lt 10)) {
            Write-Err "Python zu alt: $verRaw (KiCad_MCP braucht 3.10+)."
            exit 1
        }
        Write-Ok "$verRaw -> $PythonPath"
    } else {
        Write-Warn "Version unklar: $verRaw"
    }
} catch {
    Write-Err "python --version fehlgeschlagen: $($_.Exception.Message)"
    exit 1
}

# --- 2. KiCad 10 CLI-Pfad ---
Write-Step "2/7 KiCad 10 CLI finden"

if (-not $KicadCliPath) {
    $cands = @(
        "C:\Program Files\KiCad\10.0\bin\kicad-cli.exe",
        "C:\Program Files (x86)\KiCad\10.0\bin\kicad-cli.exe",
        "C:\Program Files\KiCad\9.0\bin\kicad-cli.exe",
        "C:\Program Files (x86)\KiCad\9.0\bin\kicad-cli.exe"
    )
    foreach ($c in $cands) {
        if (Test-Path -LiteralPath $c) { $KicadCliPath = $c; break }
    }
    if (-not $KicadCliPath) {
        $KicadCliPath = Read-RequiredPath -Prompt "Pfad zu kicad-cli.exe" -MustExist
    }
}
if (-not (Test-Path -LiteralPath $KicadCliPath)) {
    Write-Err "KiCad CLI nicht gefunden: $KicadCliPath"
    exit 1
}
Write-Ok "KiCad CLI: $KicadCliPath"

if ($KicadCliPath -notmatch '\\10\.') {
    Write-Warn "Pfad zeigt nicht auf KiCad 10 -- KiCad_MCP empfiehlt explizit v10.0. Setup laeuft weiter, aber teste gleich manuell."
}

# --- 3. KiCad_MCP-Ordner + pip install ---
Write-Step "3/7 KiCad_MCP-Ordner + Dependencies"

if (-not $KicadMcpPath) {
    # Versuch 1: script wurde aus dem KiCad_MCP-Ordner heraus aufgerufen
    $here = (Get-Location).Path
    if ((Test-Path -LiteralPath (Join-Path $here "main.py")) -and
        (Test-Path -LiteralPath (Join-Path $here "pyproject.toml"))) {
        $KicadMcpPath = $here
        Write-Info "Auto-detected (cwd): $KicadMcpPath"
    }
}
if (-not $KicadMcpPath) {
    $KicadMcpPath = Read-RequiredPath -Prompt "Pfad zum KiCad_MCP-Repo (enthaelt main.py)" -MustExist
}
if (-not (Test-Path -LiteralPath (Join-Path $KicadMcpPath "main.py"))) {
    Write-Err "main.py nicht gefunden in $KicadMcpPath -- ist das wirklich der KiCad_MCP-Ordner?"
    exit 1
}
Write-Ok "KiCad_MCP-Repo: $KicadMcpPath"

if ($SkipPipInstall) {
    Write-Info "SkipPipInstall gesetzt -- ueberspringe pip install."
} else {
    Write-Info "Installiere Deps (pip install -e `".[dev]`") -- kann 1-2 min dauern..."
    Push-Location $KicadMcpPath
    try {
        & $PythonPath -m pip install -e ".[dev]" 2>&1 | ForEach-Object {
            if ($_ -match "^(ERROR|error:)") { Write-Host "      $_" -ForegroundColor Red }
            elseif ($_ -match "^(WARNING|warning:)") { Write-Host "      $_" -ForegroundColor Yellow }
            else { Write-Host "      $_" -ForegroundColor DarkGray }
        }
        $pipRc = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($pipRc -ne 0) {
        Write-Err "pip install fehlgeschlagen (rc=$pipRc). Siehe Output oben."
        exit 1
    }
    Write-Ok "Dependencies installiert."
}

# Smoke-Test: kann der Server ueberhaupt importiert werden?
Write-Info "Import-Smoke-Test..."
$smoke = & $PythonPath -c "import sys; sys.path.insert(0, r'$KicadMcpPath'); import kicad_mcp; print('ok')" 2>&1
if ($smoke -notmatch "^ok$") {
    Write-Warn "Import-Smoke-Test unauffaellig positiv, aber Output war: $smoke"
} else {
    Write-Ok "kicad_mcp importierbar."
}

# --- 4. agentbox _control finden ---
Write-Step "4/7 agentbox _control-Ordner finden"

if (-not $AgentboxControlDir) {
    $cands = @()
    if ($env:OneDrive) {
        $cands += Join-Path $env:OneDrive "AI_Projects_Source\_control"
        $cands += Join-Path $env:OneDrive "AI_Projects\_control"
    }
    $cands += "D:\AI_Projects_Source\_control"
    $cands += "$env:USERPROFILE\AI_Projects_Source\_control"
    foreach ($c in $cands) {
        if ((Test-Path -LiteralPath $c) -and (Test-Path -LiteralPath (Join-Path $c "config.json"))) {
            $AgentboxControlDir = $c
            break
        }
    }
    if (-not $AgentboxControlDir) {
        Write-Warn "_control\config.json nicht in Default-Pfaden gefunden."
        $AgentboxControlDir = Read-RequiredPath -Prompt "Pfad zum agentbox _control-Ordner" -MustExist
    }
}

$configPath = Join-Path $AgentboxControlDir "config.json"
if (-not (Test-Path -LiteralPath $configPath)) {
    Write-Err "config.json fehlt: $configPath"
    exit 1
}
Write-Ok "agentbox _control: $AgentboxControlDir"

# --- 5. Search-Paths default ---
if ($SearchPaths.Count -eq 0) {
    $defaultSearches = @()
    # Standard: Parent von _control + ~/Documents/KiCad
    $projectsRoot = Split-Path -Parent $AgentboxControlDir
    if (Test-Path -LiteralPath $projectsRoot) { $defaultSearches += $projectsRoot }
    $docsKicad = Join-Path $env:USERPROFILE "Documents\KiCad"
    if (Test-Path -LiteralPath $docsKicad) { $defaultSearches += $docsKicad }
    $SearchPaths = $defaultSearches
}
$searchCsv = $SearchPaths -join ';'
Write-Info "KICAD_SEARCH_PATHS: $searchCsv"

# --- 6. config.json smart-mergen ---
Write-Step "5/7 config.json aktualisieren"

$configJson = Get-Content -LiteralPath $configPath -Raw
$config = $configJson | ConvertFrom-Json

if (-not $config.PSObject.Properties['mcp_servers']) {
    $config | Add-Member -NotePropertyName 'mcp_servers' -NotePropertyValue @()
}

# Vorhandenen Eintrag mit derselben ID entfernen (idempotent)
$existing = @($config.mcp_servers | Where-Object { $_.id -ne $McpId })

# Neuen Eintrag bauen
$newEntry = [PSCustomObject]@{
    id      = $McpId
    command = $PythonPath
    args    = @("main.py")
    cwd     = $KicadMcpPath
    env     = [PSCustomObject]@{
        KICAD_CLI_PATH      = $KicadCliPath
        KICAD_SEARCH_PATHS  = $searchCsv
    }
}

$config.mcp_servers = @($existing) + @($newEntry)

# Backup + Schreiben
$backupPath = "$configPath.backup.$(Get-Date -Format 'yyyyMMdd_HHmmss')"
Copy-Item -LiteralPath $configPath -Destination $backupPath
Write-Info "Backup: $backupPath"

$newJson = $config | ConvertTo-Json -Depth 20
# CRLF -> LF fuer WSL-Kompatibilitaet
$newJson = $newJson -replace "`r`n", "`n" -replace "`r", "`n"
if (-not $newJson.EndsWith("`n")) { $newJson += "`n" }
[System.IO.File]::WriteAllText($configPath, $newJson, (New-Object System.Text.UTF8Encoding $false))
Write-Ok "config.json geschrieben. $($existing.Count) andere mcp_servers erhalten, kicad neu gesetzt."

# --- 7. Dispatcher stoppen + starten ---
Write-Step "6/7 agentbox-mcp-dispatcher neuladen"

$taskName = "agentbox-mcp-dispatcher"
$taskExists = $false
try {
    $null = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    $taskExists = $true
} catch {
    $taskExists = $false
}

if (-not $taskExists) {
    Write-Warn "Scheduled Task '$taskName' existiert nicht."
    Write-Info "Einmaliger Fix: install.ps1 als Admin rerunnen -- registriert den Task."
    Write-Info "Auto-Fix-Versuch: install.ps1 aufrufen? (wird Admin-UAC-Prompt triggern)"
    if (-not $NonInteractive) {
        $yn = Read-Host "install.ps1 jetzt starten? [j/N]"
        if ($yn -match '^[jJyY]') {
            $installPs1 = Join-Path $AgentboxControlDir "install.ps1"
            if (Test-Path -LiteralPath $installPs1) {
                Start-Process -FilePath "powershell.exe" `
                    -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-File",$installPs1 `
                    -Verb RunAs -Wait
                Start-Sleep -Seconds 2
                try {
                    $null = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
                    $taskExists = $true
                    Write-Ok "Task nach install.ps1 jetzt vorhanden."
                } catch {
                    Write-Err "install.ps1 ist durch, aber Task immer noch nicht da. Bitte dispatcher-Registrierung in install.ps1-Output pruefen."
                    exit 1
                }
            } else {
                Write-Err "install.ps1 nicht gefunden in $AgentboxControlDir"
                exit 1
            }
        } else {
            Write-Info "OK, Task wird spaeter benoetigt. Abbruch ohne Reload."
            exit 2
        }
    } else {
        Write-Err "NonInteractive + Task fehlt: abort."
        exit 1
    }
}

try {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Write-Ok "Dispatcher gestoppt."
} catch {
    Write-Info "Dispatcher war nicht aktiv (ok)."
}
Start-Sleep -Seconds 1
try {
    Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
    Write-Ok "Dispatcher gestartet."
} catch {
    Write-Err "Dispatcher-Start fehlgeschlagen: $($_.Exception.Message)"
    exit 1
}

# --- 8. Logs tailen ---
Write-Step "7/7 Logs pruefen (3s Wartezeit fuer Handler-Start)"

Start-Sleep -Seconds 3

$runtimeBase = Join-Path $env:LOCALAPPDATA "agentbox\mcp-runtime"
$dispatcherLog = Join-Path $runtimeBase "dispatcher.log"
$handlerLog = Join-Path $runtimeBase "$McpId\handler.log"
$heartbeatFile = Join-Path $runtimeBase "$McpId\daemon.heartbeat"

Write-Info ""
Write-Info "--- dispatcher.log (letzte 10 Zeilen) ---"
if (Test-Path -LiteralPath $dispatcherLog) {
    Get-Content -LiteralPath $dispatcherLog -Tail 10 | ForEach-Object {
        Write-Host "      $_" -ForegroundColor DarkGray
    }
} else {
    Write-Warn "dispatcher.log existiert noch nicht ($dispatcherLog)"
}

Write-Info ""
Write-Info "--- $McpId handler.log (letzte 20 Zeilen) ---"
if (Test-Path -LiteralPath $handlerLog) {
    Get-Content -LiteralPath $handlerLog -Tail 20 | ForEach-Object {
        if ($_ -match "ERROR|FEHLER") { Write-Host "      $_" -ForegroundColor Red }
        elseif ($_ -match "WARN") { Write-Host "      $_" -ForegroundColor Yellow }
        elseif ($_ -match "\[OK\]|ok -- | gestartet") { Write-Host "      $_" -ForegroundColor Green }
        else { Write-Host "      $_" -ForegroundColor DarkGray }
    }
} else {
    Write-Warn "handler.log existiert noch nicht ($handlerLog)"
    Write-Info "Typisch: Handler ist gerade noch am Hochfahren. Warte 5s und rerun: Get-Content '$handlerLog' -Tail 20"
}

# Heartbeat-Check als finale Status-Ampel
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
if (Test-Path -LiteralPath $heartbeatFile) {
    $hbAge = ((Get-Date) - (Get-Item -LiteralPath $heartbeatFile).LastWriteTime).TotalSeconds
    if ($hbAge -lt 30) {
        Write-Host " [OK] KiCad MCP-Handler laeuft (heartbeat $([int]$hbAge)s alt)" -ForegroundColor Green
        Write-Host " Naechste agentbox-Session -> /mcp zeigt 'kicad' mit 43 Tools." -ForegroundColor Green
    } else {
        Write-Host " [WARN] Heartbeat zu alt ($([int]$hbAge)s). Handler evtl. haengt." -ForegroundColor Yellow
        Write-Host " Pruefe handler.log oben fuer den letzten Fehler." -ForegroundColor Yellow
    }
} else {
    Write-Host " [WARN] Kein Heartbeat bis jetzt -- Handler konnte nicht starten." -ForegroundColor Yellow
    Write-Host " Log pruefen: Get-Content '$handlerLog' -Tail 30" -ForegroundColor Yellow
    Write-Host " Typische Ursachen:" -ForegroundColor Yellow
    Write-Host "   - python nicht im PATH (nutze -PythonPath mit absolutem exe-Pfad)" -ForegroundColor Yellow
    Write-Host "   - 'pip install' hat Dependencies-Fehler (Setup rerunnen)" -ForegroundColor Yellow
    Write-Host "   - KiCad_MCP selbst crasht (manuell starten: cd '$KicadMcpPath'; & '$PythonPath' main.py)" -ForegroundColor Yellow
}
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
