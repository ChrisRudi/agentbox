# win-setup-core.ps1
# agentbox — Einmalige Einrichtung: Template bauen, Event-Source, Scheduled Task
# Wird von win-setup.ps1 per Invoke-Expression geladen ($scriptDir ist bereits gesetzt)

if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }

$ErrorActionPreference = "Continue"

# --- UTF-8 Ausgabe fuer wsl.exe erzwingen (sonst UTF-16LE → Mojibake in PS 5.1) ---
# Wirkt auch wenn dieses Script direkt (ohne install.ps1) ausgefuehrt wird.
$env:WSL_UTF8 = "1"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

Write-Host ""
Write-Host "=== agentbox Setup ===" -ForegroundColor Cyan
Write-Host ""

# --- Pfade bestimmen ---
# Template + Config-Hash leben unter %LOCALAPPDATA%\agentbox\sandbox\ —
# bewusst nicht unter $scriptDir\sandbox\, weil der Script-Dir ueblicherweise
# in OneDrive liegt und ein ~1 GB Template dort nichts zu suchen hat
# (Sync-Kosten, Files-On-Demand-Placeholder, ERROR_PATH_NOT_FOUND bei wsl
# --import). Gleiche Regel wie fuer auth\ und host-distro\.
$sandboxDir = Join-Path $env:LOCALAPPDATA "agentbox\sandbox"
if (-not (Test-Path -LiteralPath $sandboxDir)) {
    New-Item -ItemType Directory -LiteralPath $sandboxDir -Force | Out-Null
}
$templatePath = Join-Path $sandboxDir "template.tar.gz"
$tempBase = Join-Path $env:TEMP "agentbox"
$tempSetup = Join-Path $tempBase "setup"
$distroName = "agentbox-template-build"

# --- Migration: altes Template aus $scriptDir\sandbox\ raus ---
# Wer von einer aelteren Version kommt, hat template.tar.gz + .config_hash
# noch unter $scriptDir\sandbox\. Einmalig ruebermoven und den alten
# Ordner entsorgen, damit kein verwaister Cloud-Sync-Verkehr mehr entsteht.
# MUSS hier laufen — sonst greift gleich der Cache-Check unten ins Leere
# und Import-AgentboxHostDistro findet das Template nicht am neuen Ort.
$legacySandboxDir = Join-Path $scriptDir "sandbox"
if (Test-Path -LiteralPath $legacySandboxDir) {
    Write-Host "[MIGRATE] Altes sandbox/ unter $legacySandboxDir gefunden — verschiebe nach $sandboxDir" -ForegroundColor Yellow
    foreach ($name in @("template.tar.gz", ".config_hash")) {
        $legacyFile = Join-Path $legacySandboxDir $name
        $targetFile = Join-Path $sandboxDir $name
        if ((Test-Path -LiteralPath $legacyFile) -and -not (Test-Path -LiteralPath $targetFile)) {
            try {
                Move-Item -LiteralPath $legacyFile -Destination $targetFile -Force -ErrorAction Stop
                Write-Host "          moved: $name" -ForegroundColor Gray
            } catch {
                # Move-Item kann an OneDrive-Files-On-Demand-Placeholdern oder
                # cross-volume Sync-Aussetzern scheitern (Template ist ~1.2 GB).
                # Copy + Remove als Fallback — erzwingt Hydration via Read.
                try {
                    Copy-Item -LiteralPath $legacyFile -Destination $targetFile -Force -ErrorAction Stop
                    Remove-Item -LiteralPath $legacyFile -Force -ErrorAction SilentlyContinue
                    Write-Host "          copied: $name" -ForegroundColor Gray
                } catch {
                    Write-Host "          WARN: $name — $($_.Exception.Message)" -ForegroundColor Yellow
                }
            }
        }
    }
    try { Remove-Item -LiteralPath $legacySandboxDir -Recurse -Force -ErrorAction Stop } catch { }
}

# --- config.json laden ---
$configPath = Join-Path $scriptDir "config.json"
$config = $null
try {
    if (Test-Path -LiteralPath $configPath) {
        $config = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop | ConvertFrom-Json
    }
} catch {
    Write-Host "[INFO] config.json nicht lesbar — verwende Standardwerte." -ForegroundColor Gray
}

# --- WSL2 pruefen ---
try {
    $wslOutput = & wsl.exe --status 2>&1
    if ($LASTEXITCODE -ne 0) { throw "WSL nicht aktiv" }
} catch {
    Write-Host "FEHLER: WSL2 ist nicht installiert oder nicht aktiv." -ForegroundColor Red
    exit 1
}
Write-Host "[OK] WSL2 aktiv" -ForegroundColor Green

# --- Template-Rebuild noetig? ---
# Hash aus config.json (agent_*, *_url). Version absichtlich NICHT enthalten,
# damit code-only Updates (z.B. wsl-sandbox-init.sh, install.ps1) keinen
# teuren Template-Rebuild ausloesen. Template muss nur neu wenn sich Pakete
# oder Agent-Install-Commands aendern → das steht in config.json.
function Get-AgentboxConfigHash {
    param($cfg)
    $parts = @()
    if ($cfg) {
        $parts += ($cfg.PSObject.Properties |
            Where-Object { $_.Name -match '^agent_' -or $_.Name -in @('ubuntu_image_url','nodejs_setup_url') } |
            Sort-Object Name |
            ForEach-Object { "$($_.Name)=$($_.Value)" })
    }
    $combined = $parts -join "|"
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($combined)
    return ($md5.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join ""
}

# Registriert Event-Source + Scheduled Task. Wird aus Skip-Build- und Full-
# Build-Pfad aufgerufen (vorher an beiden Stellen kopiert, mit Drift).
function Register-AgentboxTaskRunner {
    param($cfg, [Parameter(Mandatory)][string]$ScriptDir)

    Write-Host "Registriere Windows Event-Source..." -ForegroundColor Cyan
    $eventSource = if ($cfg -and $cfg.event_log_source) { $cfg.event_log_source } else { "AIProjects" }
    if (-not [System.Diagnostics.EventLog]::SourceExists($eventSource)) {
        [System.Diagnostics.EventLog]::CreateEventSource($eventSource, "Application")
        Write-Host "[OK] Event-Source '$eventSource' registriert" -ForegroundColor Green
    } else {
        Write-Host "[OK] Event-Source '$eventSource' bereits vorhanden" -ForegroundColor Green
    }

    Write-Host "Erstelle Scheduled Task..." -ForegroundColor Cyan
    $taskName = if ($cfg -and $cfg.scheduled_task_name) { $cfg.scheduled_task_name } else { "agentbox-task-runner" }
    $runnerScript = Join-Path $ScriptDir "win-task-runner.ps1"
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$runnerScript`" -once" `
        -WorkingDirectory $ScriptDir
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName $taskName -Action $action `
        -Trigger (New-ScheduledTaskTrigger -AtLogon) -Settings $settings `
        -Description "agentbox Task Runner — verarbeitet Build/Deploy-Tasks von AI-Agenten" `
        -RunLevel Highest | Out-Null
    Write-Host "[OK] Scheduled Task '$taskName' angelegt" -ForegroundColor Green
}

# Seed-Helper: schreibt Datei nur wenn sie fehlt ODER leer/whitespace-only ist.
# Letzteres ist wichtig, weil manche Agents beim ersten Start ihre Config-Datei
# selbst als leere Huelle anlegen (z.B. Claude Code legt ein leeres {} an) —
# ein naives Test-Path reicht dann nicht mehr, wir wuerden beim naechsten Start
# die leere Datei sehen und skippen. UTF8-noBOM + LF, PS-5.1-kompatibel.
# Rueckgabe (als String ueber Write-Output): "created"/"replaced-empty"/"kept".
function Write-AgentboxSeedIfEmpty {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string[]]$Lines
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -LiteralPath $dir -Force | Out-Null
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $content = ($Lines -join "`n") + "`n"

    if (-not (Test-Path -LiteralPath $Path)) {
        [IO.File]::WriteAllText($Path, $content, $utf8NoBom)
        return "created"
    }

    $raw = ""
    try { $raw = [IO.File]::ReadAllText($Path) } catch { return "read-error" }
    if ([string]::IsNullOrWhiteSpace($raw)) {
        [IO.File]::WriteAllText($Path, $content, $utf8NoBom)
        return "replaced-empty"
    }
    return "kept"
}

# Claude-spezifischer Smart-Merge: JSON parsen und nur permissions.defaultMode
# ergaenzen wenn fehlend. User-eigene Keys bleiben unberuehrt. Deckt den
# Haeufigkeitsfall ab, dass Claude Code beim ersten Launch ein leeres {}
# anlegt (dann wollen wir den Default schreiben), und ebenso den Fall,
# dass der User schon eigene Allow/Deny-Regeln hat (dann nur mergen).
function Merge-AgentboxClaudeSettings {
    param([Parameter(Mandatory=$true)][string]$Path)

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $defaultLines = @(
        '{',
        '  "permissions": {',
        '    "defaultMode": "bypassPermissions"',
        '  }',
        '}'
    )
    $defaultContent = ($defaultLines -join "`n") + "`n"

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -LiteralPath $dir -Force | Out-Null
    }

    # Fehlt oder leer/whitespace → Default schreiben
    if (-not (Test-Path -LiteralPath $Path)) {
        [IO.File]::WriteAllText($Path, $defaultContent, $utf8NoBom)
        return "created"
    }
    $raw = ""
    try { $raw = [IO.File]::ReadAllText($Path) } catch { return "read-error" }
    if ([string]::IsNullOrWhiteSpace($raw)) {
        [IO.File]::WriteAllText($Path, $defaultContent, $utf8NoBom)
        return "replaced-empty"
    }
    # Trivial {} (genau das, was Claude Code initial schreibt)
    if ($raw.Trim() -eq "{}") {
        [IO.File]::WriteAllText($Path, $defaultContent, $utf8NoBom)
        return "replaced-empty"
    }

    # Content existiert — JSON parsen und mergen
    $parsed = $null
    try {
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Host "[WARN] $Path ist kein valides JSON — bleibt unberuehrt" -ForegroundColor Yellow
        return "invalid-json"
    }

    # ConvertFrom-Json liefert PSCustomObject. Rekursiv pruefen ob
    # permissions.defaultMode schon gesetzt ist.
    if ($parsed -and $parsed.PSObject.Properties['permissions']) {
        $perms = $parsed.permissions
        if ($perms -and ($perms -is [PSCustomObject]) -and $perms.PSObject.Properties['defaultMode']) {
            return "already-set"
        }
        # permissions-Objekt existiert, defaultMode fehlt
        if ($null -eq $perms -or -not ($perms -is [PSCustomObject])) {
            $newPerms = New-Object PSObject
            $newPerms | Add-Member -NotePropertyName defaultMode -NotePropertyValue "bypassPermissions"
            $parsed.permissions = $newPerms
        } else {
            $perms | Add-Member -NotePropertyName defaultMode -NotePropertyValue "bypassPermissions" -Force
        }
    } else {
        $newPerms = New-Object PSObject
        $newPerms | Add-Member -NotePropertyName defaultMode -NotePropertyValue "bypassPermissions"
        if ($null -eq $parsed) {
            $parsed = New-Object PSObject
        }
        $parsed | Add-Member -NotePropertyName permissions -NotePropertyValue $newPerms -Force
    }

    # Zurueck als JSON, CRLF -> LF, abschliessender Newline
    $newJson = $parsed | ConvertTo-Json -Depth 20
    $newJson = $newJson -replace "`r`n", "`n" -replace "`r", "`n"
    if (-not $newJson.EndsWith("`n")) { $newJson += "`n" }
    [IO.File]::WriteAllText($Path, $newJson, $utf8NoBom)
    return "merged"
}

# Auto-Approve-Defaults fuer alle fuenf Agents in %LOCALAPPDATA%\agentbox\auth\
# anlegen. wsl-ai-start.sh macht beim Session-Start dasselbe nochmal — das ist
# eine defensive Doppelung fuer User, die agentbox per git pull aktualisieren
# statt per install.ps1. Beide Aufrufe sind durch Smart-Merge + Empty-Check
# idempotent und respektieren existierende User-Edits.
#
# Warum hier im Installer *zusaetzlich* zum Session-Start-Seeding: nach einer
# frischen Installation will man die Config-Dateien sofort unter
# %LOCALAPPDATA%\agentbox\auth\<agent>\ sehen koennen — vor dem ersten Session-
# Start, damit man eigene Policies setzen kann bevor der erste Agent hochfaehrt.
#
# Drei Agents koennen ueber ihre Config-Datei voll entsperrt werden. Gemini
# und Aider brauchen CLI-Flags — die setzt wsl-sandbox-init.sh beim Launch.
function Initialize-AgentboxAutoApproveDefaults {
    $authBase = Join-Path $env:LOCALAPPDATA "agentbox\auth"

    # Claude Code — Smart-Merge (JSON), weil Claude Code selbst ein leeres
    # {} anlegt und naives if-not-exists dann wirkungslos ist.
    $claudeStatus = Merge-AgentboxClaudeSettings `
        -Path (Join-Path $authBase "claude\settings.json")

    # OpenAI Codex CLI — Empty-Check reicht. TOML/YAML-Parsing in PS 5.1
    # waere scope creep; wenn User bewusst was reingeschrieben hat, respektieren.
    $codexStatus = Write-AgentboxSeedIfEmpty `
        -Path (Join-Path $authBase "codex\config.toml") `
        -Lines @(
            '# agentbox-Default: Sandbox ist die Vertrauensgrenze, kein Approval-Prompting.',
            'approval_policy = "never"',
            'sandbox_mode    = "danger-full-access"'
        )

    # Goose — ebenso Empty-Check.
    $gooseStatus = Write-AgentboxSeedIfEmpty `
        -Path (Join-Path $authBase "goose\config.yaml") `
        -Lines @(
            '# agentbox-Default: fully autonomous mode, keine Tool-/File-/Extension-Approvals.',
            'GOOSE_MODE: auto'
        )

    Write-Host "[OK] Auto-Approve-Seeds: claude=$claudeStatus codex=$codexStatus goose=$gooseStatus" -ForegroundColor Green
}

# Unbedingt VOR dem Skip-Build-Check aufrufen, damit Updates ohne Template-
# Rebuild (gleicher Config-Hash) trotzdem neue Seeds nachziehen koennen.
Initialize-AgentboxAutoApproveDefaults

$configHashFile = Join-Path $sandboxDir ".config_hash"
$currentHash = Get-AgentboxConfigHash -cfg $config

if ((Test-Path -LiteralPath $templatePath) -and (Test-Path -LiteralPath $configHashFile)) {
    $savedHash = ""
    try { $savedHash = (Get-Content -LiteralPath $configHashFile -Raw -ErrorAction SilentlyContinue).Trim() } catch {}
    if ($savedHash -eq $currentHash) {
        $templateSize = [math]::Round((Get-Item $templatePath).Length / 1MB, 1)
        Write-Host ""
        Write-Host "[OK] Template bereits aktuell — ueberspringe Build" -ForegroundColor Green
        Write-Host "     Pfad: $templatePath ($templateSize MB)" -ForegroundColor Gray
        Write-Host "     Hash: $savedHash" -ForegroundColor Gray
        Write-Host "     Erzwinge Rebuild: loesche $configHashFile oder aendere config.json" -ForegroundColor Gray

        # --- Direkt zu Event-Source + Scheduled Task springen ---
        Write-Host ""
        Register-AgentboxTaskRunner -cfg $config -ScriptDir $scriptDir

        Write-Host ""
        Write-Host "=== Setup abgeschlossen (Template aus Cache) ===" -ForegroundColor Green
        Write-Host ""
        $agentboxSkipBuild = $true
    } else {
        Write-Host "[INFO] Config/Version geaendert — Template wird neu gebaut" -ForegroundColor Yellow
        Write-Host "       Gespeichert: $savedHash" -ForegroundColor Gray
        Write-Host "       Aktuell:     $currentHash" -ForegroundColor Gray
    }
}

if (-not $agentboxSkipBuild) {

# --- Ubuntu-Minimal herunterladen ---
Write-Host ""
Write-Host "Lade Ubuntu-Minimal herunter..." -ForegroundColor Cyan

$ubuntuUrl = if ($config -and $config.ubuntu_image_url) { $config.ubuntu_image_url } else {
    "https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-amd64-root.tar.xz"
}
$downloadPath = Join-Path $tempBase "ubuntu-minimal.tar.xz"

if (-not (Test-Path -LiteralPath $tempBase)) {
    New-Item -ItemType Directory -LiteralPath $tempBase -Force | Out-Null
}

if (-not (Test-Path -LiteralPath $downloadPath)) {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $ubuntuUrl -OutFile $downloadPath -UseBasicParsing
        Write-Host "[OK] Ubuntu-Minimal heruntergeladen" -ForegroundColor Green
    } catch {
        Write-Host "FEHLER: Download fehlgeschlagen." -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "[OK] Ubuntu-Minimal bereits vorhanden (Cache)" -ForegroundColor Green
}

# --- Temporaere Distro importieren ---
Write-Host ""
Write-Host "Importiere temporaere Distro fuer Template-Build..." -ForegroundColor Cyan

# Alte temporaere Distro entfernen falls vorhanden
$existingDistros = & wsl.exe -l -q 2>&1
if ($existingDistros -match $distroName) {
    Write-Host "Entferne alte temporaere Distro..." -ForegroundColor Yellow
    & wsl.exe --unregister $distroName 2>&1 | Out-Null
}

if (Test-Path -LiteralPath $tempSetup) {
    Remove-Item -LiteralPath $tempSetup -Recurse -Force
}
New-Item -ItemType Directory -LiteralPath $tempSetup -Force | Out-Null

# Output als String-Array einsammeln (nicht live ausgeben):
# - Stderr-Zeilen werden stringifiziert → kein NativeCommandError
# - Success-Zeile 'Der Vorgang wurde erfolgreich beendet.' wird nicht gezeigt
# - Fehler-Output bleibt fuer HCS-Detection + Log-Anzeige erhalten
# Wichtig: NUL-Bytes strippen, BEVOR irgendeine Regex laeuft. Alte wsl.exe-
# Versionen ignorieren $env:WSL_UTF8 und schreiben UTF-16LE auf stderr/stdout
# — durchgeschleust wird das als string mit "\0" zwischen jedem Zeichen, und
# unsere `match 'HCS_E_*'`-Detection fand danach nichts, weil "H\0C\0S\0..."
# nie auf "HCS" matcht. Wir saeubern hier rigoros: NUL raus, dann Trim().
$importOutputRaw = @(& wsl.exe --import $distroName $tempSetup $downloadPath 2>&1 | ForEach-Object { "$_" })
$importExit = $LASTEXITCODE
$importOutput = @($importOutputRaw | ForEach-Object { ($_ -replace "`0", "").Trim() } | Where-Object { $_ -ne "" })
if ($importExit -ne 0) {
    $importText = ($importOutput -join "`n")
    Write-Host ""
    Write-Host "FEHLER: WSL-Import fehlgeschlagen (Exit $importExit)." -ForegroundColor Red
    Write-Host "        Rohausgabe von wsl.exe:" -ForegroundColor Yellow
    if ($importOutput.Count -gt 0) {
        foreach ($line in $importOutput) { Write-Host "          $line" -ForegroundColor DarkGray }
    } else {
        Write-Host "          (leer)" -ForegroundColor DarkGray
    }
    Write-Host ""
    if ($importText -match 'HCS_E_SERVICE_NOT_AVAILABLE' -or $importText -match 'HCS/HCS_') {
        Write-Host "Diagnose: Hyper-V Host Compute Service (vmcompute) nicht verfuegbar." -ForegroundColor Yellow
        Write-Host "          Das passiert typischerweise direkt nach 'wsl --install' auf" -ForegroundColor Yellow
        Write-Host "          einem frischen System: Die VM-Features sind aktiviert, aber" -ForegroundColor Yellow
        Write-Host "          der Dienst startet erst nach einem Neustart." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "          Bitte den PC neu starten und install.ps1 erneut ausfuehren:" -ForegroundColor Yellow
        Write-Host "            irm https://raw.githubusercontent.com/ChrisRudi/agentbox/main/install.ps1 | iex" -ForegroundColor White
    } elseif ($importText -match 'Unbekannter Fehler' -or $importText -match 'Unspecified error') {
        Write-Host "Diagnose: Generischer wsl.exe-Fehler. Haeufigste Ursache: WSL ist zu" -ForegroundColor Yellow
        Write-Host "          alt fuer das Ubuntu-24.04-Cloud-Image. Bitte WSL aktualisieren:" -ForegroundColor Yellow
        Write-Host "            wsl --update" -ForegroundColor White
        Write-Host "            wsl --update --web-download   # Fallback" -ForegroundColor White
        Write-Host "          und anschliessend Windows einmal neu starten." -ForegroundColor Yellow
    } else {
        Write-Host "Diagnose: Bitte die Rohausgabe oben pruefen — kein bekanntes Fehlermuster." -ForegroundColor Yellow
    }
    exit 1
}
Write-Host "[OK] Temporaere Distro importiert" -ForegroundColor Green

# --- Pakete installieren ---
Write-Host ""
Write-Host "Installiere Pakete in der Template-Distro..." -ForegroundColor Cyan

# Agent-Install-Commands aus Config zusammenstellen (nur aktivierte Agents)
$agentInstallLines = @()
$agentIds = @("claude", "codex", "gemini", "aider", "goose")
foreach ($aid in $agentIds) {
    $enabledProp = "agent_${aid}_enabled"
    $installProp = "agent_${aid}_install"
    $nameProp = "agent_${aid}_name"

    $isEnabled = $false
    if ($config -and (Get-Member -InputObject $config -Name $enabledProp -MemberType NoteProperty)) {
        $isEnabled = $config.$enabledProp
    } elseif ($aid -in @("claude", "codex", "gemini")) {
        $isEnabled = $true
    }

    if ($isEnabled) {
        $installCmd = $null
        $agentName = $aid
        if ($config -and (Get-Member -InputObject $config -Name $installProp -MemberType NoteProperty)) {
            $installCmd = $config.$installProp
        }
        if ($config -and (Get-Member -InputObject $config -Name $nameProp -MemberType NoteProperty)) {
            $agentName = $config.$nameProp
        }

        if (-not $installCmd) {
            $installCmd = switch ($aid) {
                "claude" { "npm install -g @anthropic-ai/claude-code@latest" }
                "codex"  { "npm install -g @openai/codex@latest" }
                "gemini" { "pip3 install google-gemini-cli" }
                "aider"  { "pip3 install aider-chat" }
                "goose"  { "pip3 install goose-ai" }
            }
        }

        if ($installCmd) {
            # Jede Agent-Install-Zeile: erst Step-Marker auf fd 3 (Konsole),
            # dann der Install-Command (stdout/stderr → Log-Datei), Fallback
            # als Warning ebenfalls auf fd 3.
            $agentInstallLines += "step '       - $agentName'"
            $agentInstallLines += "$installCmd || echo 'WARNUNG: $agentName Installation fehlgeschlagen' >&3"
        }
    }
}

$agentInstallBlock = $agentInstallLines -join "`n"
$nodejsUrl = if ($config -and $config.nodejs_setup_url) { $config.nodejs_setup_url } else { "https://deb.nodesource.com/setup_20.x" }

# Install-Skript: alle verbose apt/npm/pip-Ausgaben gehen in eine Log-Datei
# innerhalb der Sandbox. Nur saubere Step-Marker werden ueber fd 3 auf die
# Host-Konsole durchgereicht. Damit verschwinden sowohl die endlosen Reading-
# database-Zeilen als auch der 'debconf: delaying package configuration'-
# NativeCommandError, den PS 5.1 aus dem Stderr baut.
$installScript = @'
#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive

LOG=/var/log/agentbox-install.log
mkdir -p /var/log
: > "$LOG"

# fd 3 = original stdout (Host-Konsole), 1/2 -> Log
exec 3>&1
exec >>"$LOG" 2>&1
step() { echo "$1" >&3; }

step "       [1/5] System-Update..."
apt-get update
# apt-utils zuerst, damit debconf keine 'delaying package configuration'-
# Warnung mehr auf stderr schreibt (die PS 5.1 als Fehler interpretiert).
apt-get install -y -qq --no-install-recommends apt-utils
apt-get install -y -qq --no-install-recommends bash curl wget git iptables ca-certificates dnsutils

step "       [2/5] Node.js installieren..."
curl -fsSL __NODEJS_URL__ -o /tmp/nodesource_setup.sh
bash /tmp/nodesource_setup.sh
apt-get install -y -qq --no-install-recommends nodejs
step "              node $(node --version), npm $(npm --version)"

step "       [3/5] Python3 installieren..."
apt-get install -y -qq --no-install-recommends python3 python3-pip python3-venv
step "              $(python3 --version)"

step "       [4/5] AI CLI-Tools installieren..."
__AGENT_INSTALL_BLOCK__

step "       [5/5] Aufraumen..."
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

step "       Pakete fertig installiert."
'@
$installScript = $installScript.Replace('__NODEJS_URL__', $nodejsUrl).Replace('__AGENT_INSTALL_BLOCK__', $agentInstallBlock)
$installScript = $installScript.Replace("`r", "")

# Als Base64 ueber Datei in die Distro schieben (umgeht bash -c Quoting-Probleme)
# Exit-Code in /tmp/install.rc schreiben, weil PS 5.1's 2>&1 | Out-Host $LASTEXITCODE verwaschen kann
$installB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($installScript))
$runInstall = "echo $installB64 | base64 -d > /tmp/install.sh; bash /tmp/install.sh; echo `$? > /tmp/install.rc; rm -f /tmp/install.sh"

# Streaming statt Buffer: Output direkt durch ForEach nach Write-Host pipen,
# damit der User die Step-Marker ('[1/5] System-Update...', '[2/5] Node.js...')
# LIVE waehrend des Installs sieht. Vorher wurde mit @(...) alles in ein Array
# geschrieben und erst nach Exit des wsl-Calls angezeigt — das sah 3-5 Minuten
# lang wie ein Hang aus, obwohl intern fleissig installiert wurde.
# Die "$_"-Stringifizierung bleibt wichtig: verhindert dass PS Stderr-Zeilen
# als ErrorRecord-Objekte in den Pipe-Stream wirft (rote Error-Kaestchen).
& wsl.exe -d $distroName -- bash -c $runInstall 2>&1 | ForEach-Object { Write-Host "$_" -ForegroundColor Gray }

# Exit-Code aus der Sandbox lesen (zuverlaessiger als $LASTEXITCODE nach Pipe)
$installRc = & wsl.exe -d $distroName -- cat /tmp/install.rc 2>&1
$installRc = "$installRc".Trim() -replace '\D',''
& wsl.exe -d $distroName -- rm -f /tmp/install.rc 2>&1 | Out-Null
if ([string]::IsNullOrEmpty($installRc) -or $installRc -ne "0") {
    Write-Host "FEHLER: Paket-Installation fehlgeschlagen (Exit $installRc)." -ForegroundColor Red
    Write-Host "        Letzte 80 Zeilen aus /var/log/agentbox-install.log:" -ForegroundColor Yellow
    $logTail = @(& wsl.exe -d $distroName -- tail -n 80 /var/log/agentbox-install.log 2>&1 | ForEach-Object { "$_" })
    foreach ($line in $logTail) { Write-Host "        $line" -ForegroundColor DarkGray }
    & wsl.exe --unregister $distroName 2>&1 | Out-Null
    exit 1
}
Write-Host "[OK] Pakete installiert" -ForegroundColor Green

# --- Agent-Binaries verifizieren (HART: Abbruch bei fehlenden Agents) ---
Write-Host ""
Write-Host "Verifiziere Agent-Binaries..." -ForegroundColor Cyan
$missingAgents = @()
foreach ($aid in $agentIds) {
    $enabledProp = "agent_${aid}_enabled"
    $cmdProp = "agent_${aid}_command"
    $isEnabled = $false
    if ($config -and (Get-Member -InputObject $config -Name $enabledProp -MemberType NoteProperty)) {
        $isEnabled = $config.$enabledProp
    } elseif ($aid -in @("claude", "codex", "gemini")) { # muss zu Install-Block passen
        $isEnabled = $true
    }
    if (-not $isEnabled) { continue }
    $agentCmd = $aid
    if ($config -and (Get-Member -InputObject $config -Name $cmdProp -MemberType NoteProperty)) {
        $agentCmd = $config.$cmdProp
    }
    $check = & wsl.exe -d $distroName -- bash -lc "command -v $agentCmd >/dev/null 2>&1 && echo OK || echo MISSING" 2>&1
    $check = "$check".Trim()
    if ($check -eq "OK") {
        Write-Host "  [OK] $agentCmd" -ForegroundColor Green
    } else {
        Write-Host "  [FEHLT] $agentCmd" -ForegroundColor Red
        $missingAgents += $agentCmd
    }
}
if ($missingAgents.Count -gt 0) {
    Write-Host ""
    Write-Host "FEHLER: Folgende aktivierte Agents wurden nicht installiert:" -ForegroundColor Red
    Write-Host "        $($missingAgents -join ', ')" -ForegroundColor Red
    Write-Host "        Template wird NICHT exportiert — Installation abgebrochen." -ForegroundColor Red
    Write-Host "        Deaktiviere die Agents in config.json oder pruefe die Install-Commands." -ForegroundColor Yellow
    & wsl.exe --unregister $distroName 2>&1 | Out-Null
    exit 1
}

# --- Sysctl-Hardening ---
# (Kein Template-Firewall mehr: die iptables-Regeln baut wsl-sandbox-init.sh
# fresh pro Session aus den Config-Parametern.)
Write-Host "Setze Sysctl-Hardening..." -ForegroundColor Cyan

$sysctlContent = "# agentbox — Hardlink- und Symlink-Schutz`nfs.protected_hardlinks = 1`nfs.protected_symlinks = 1"
$sysctlB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($sysctlContent))
$sysctlCmd = "echo $sysctlB64 | base64 -d >> /etc/sysctl.conf && sysctl -p > /dev/null 2>&1 || true"
& wsl.exe -d $distroName -- bash -c $sysctlCmd 2>&1 | ForEach-Object { "$_" } | Out-Null
Write-Host "[OK] Sysctl-Hardening gesetzt" -ForegroundColor Green

# --- SYSTEM_META_PROMPT.md in Distro kopieren ---
Write-Host "Kopiere SYSTEM_META_PROMPT.md..." -ForegroundColor Cyan

$metaPromptSrc = Join-Path $scriptDir "SYSTEM_META_PROMPT.md"
if (Test-Path -LiteralPath $metaPromptSrc) {
    # wslpath hier im Template-Distro-Kontext ist OK (die Distro existiert),
    # Stderr trotzdem stringifizieren fuer einheitliches Verhalten.
    $wslMetaPath = (& wsl.exe -d $distroName -- wslpath -u ($metaPromptSrc -replace '\\', '/') 2>&1 | ForEach-Object { "$_" }) -join ""
    & wsl.exe -d $distroName -- bash -c "mkdir -p /etc/agentbox && cp '$($wslMetaPath.Trim())' /etc/agentbox/SYSTEM_META_PROMPT.md" 2>&1 | ForEach-Object { "$_" } | Out-Null
    Write-Host "[OK] SYSTEM_META_PROMPT.md kopiert" -ForegroundColor Green
} else {
    Write-Host "WARNUNG: SYSTEM_META_PROMPT.md nicht gefunden in $scriptDir" -ForegroundColor Yellow
}

# --- Template exportieren ---
Write-Host ""
Write-Host "Exportiere Template..." -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $sandboxDir)) {
    New-Item -ItemType Directory -LiteralPath $sandboxDir -Force | Out-Null
}

# Export-Output schlucken (wsl schreibt "Der Vorgang wurde erfolgreich beendet."
# auf stderr — fuer sich harmlos, aber inkonsistent im Installer-Feed).
& wsl.exe --export $distroName $templatePath 2>&1 | ForEach-Object { "$_" } | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "FEHLER: Template-Export fehlgeschlagen." -ForegroundColor Red
    & wsl.exe --unregister $distroName 2>&1 | Out-Null
    exit 1
}

# Config-Hash speichern (fuer naechsten Skip-Check)
try {
    $currentHash | Out-File -LiteralPath $configHashFile -Encoding ascii -NoNewline
} catch { }

$templateSize = [math]::Round((Get-Item $templatePath).Length / 1MB, 1)
Write-Host "[OK] Template exportiert: $templatePath ($templateSize MB)" -ForegroundColor Green

# --- Temporaere Distro entfernen ---
Write-Host "Entferne temporaere Build-Distro..." -ForegroundColor Cyan
& wsl.exe --unregister $distroName 2>&1 | Out-Null
if (Test-Path -LiteralPath $tempSetup) {
    Remove-Item -LiteralPath $tempSetup -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "[OK] Build-Distro entfernt" -ForegroundColor Green

# --- Event-Source + Scheduled Task registrieren ---
Write-Host ""
Register-AgentboxTaskRunner -cfg $config -ScriptDir $scriptDir

# --- Fertig ---
Write-Host ""
Write-Host "=== Setup abgeschlossen ===" -ForegroundColor Green
Write-Host ""

} # end if (-not $agentboxSkipBuild)
