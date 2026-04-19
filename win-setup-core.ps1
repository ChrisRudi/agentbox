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
    [System.IO.Directory]::CreateDirectory($sandboxDir) | Out-Null
}
$templatePath = Join-Path $sandboxDir "template.tar.gz"
# agentbox 2.0: zusaetzlich ein vhdx-Template fuer den schnellen Session-
# Start (import-in-place statt tar.gz-Extract). Additiv: das tar.gz bleibt
# der authoritative Cache, das vhdx ist Best-Effort und wird beim Start
# bevorzugt, faellt aber auf tar.gz zurueck wenn WSL zu alt oder vhdx fehlt.
$templateVhdPath = Join-Path $sandboxDir "template.vhdx"
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
                    # .NET-API statt Remove-Item (PS 5.1 Tilde-Provider-Bug)
                    try { [System.IO.File]::Delete($legacyFile) } catch { }
                    Write-Host "          copied: $name" -ForegroundColor Gray
                } catch {
                    Write-Host "          WARN: $name — $($_.Exception.Message)" -ForegroundColor Yellow
                }
            }
        }
    }
    try { [System.IO.Directory]::Delete($legacySandboxDir, $true) } catch { }
}

# --- config.json laden ---
# Wenn die gemeinsame Helper-Lib mitgepullt wurde (2.0.7+), nutzen
# wir Read-AgentboxConfig; sonst faellt der Block auf das Inline-
# Muster zurueck. Test-Path-guarded + try/catch, damit eine defekte
# oder fehlende Lib den Template-Build nie blockiert.
$configPath = Join-Path $scriptDir "config.json"
if (-not (Get-Command Read-AgentboxConfig -ErrorAction SilentlyContinue)) {
    $agentboxLibConfig = Join-Path $scriptDir "lib\config.ps1"
    if (Test-Path -LiteralPath $agentboxLibConfig) {
        try { . $agentboxLibConfig } catch {
            Write-Host "[INFO] lib/config.ps1 konnte nicht geladen werden — nutze Inline-Fallback." -ForegroundColor Gray
        }
    }
}

$config = $null
if (Get-Command Read-AgentboxConfig -ErrorAction SilentlyContinue) {
    $config = Read-AgentboxConfig -ConfigPath $configPath
} else {
    try {
        if (Test-Path -LiteralPath $configPath) {
            $config = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop | ConvertFrom-Json
        }
    } catch {
        Write-Host "[INFO] config.json nicht lesbar — verwende Standardwerte." -ForegroundColor Gray
    }
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
    # Template-Schema-Version: hier hochzaehlen wenn sich am Template-Build-
    # Skript etwas aendert, das unabhaengig von config.json einen Rebuild
    # erzwingen soll (neue apt-Pakete, Agent-Install-Command-Patches etc.).
    # 2 = 2.0.0 (dnsmasq-base hinzugefuegt).
    # 3 = 2.0.1 (Build-Beschleunigung: force-unsafe-io, apt-Pipelining,
    #            parallele Agent-Installs; vhdx-Export primaer, tar.gz-
    #            Fallback nur bei vhdx-Fail).
    $parts += "template_schema=3"
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
    # Bestehenden Task ggf. stoppen + entfernen. Falls noch ein 2.2.1-Watch-
    # Daemon laeuft (oder ein -once Task haengt), ihn erst sauber beenden.
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        try { Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue } catch { }
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
    # Event-Trigger-Architektur (ab 2.2.5):
    # - Action: -once (kein Daemon; jede Trigger-Firing macht einen
    #   Process-AllTasks-Sweep, dann exit).
    # - Trigger A: AtLogon -> Sweep aller Tasks, die waehrend System-Off
    #   queued wurden.
    # - Trigger B: EventLog-Subscription auf Source='AIProjects',
    #   EventID=2000. wsl-ai-start.sh emittiert dieses Event nach einem
    #   Task-File-Write, Task Scheduler startet den Runner live.
    # Vorteile ggueber 2.2.1-Watch-Daemon: kein Long-Running-Process, keine
    # FileSystemWatcher-Probleme auf OneDrive/DrvFs, lazy Execution, sauber
    # via Event-Log-Audit nachvollziehbar.
    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$runnerScript`" -once" `
        -WorkingDirectory $ScriptDir

    $atLogon = New-ScheduledTaskTrigger -AtLogon

    # Event-Trigger via CIM (PS 5.1 kompatibel). MSFT_TaskEventTrigger
    # braucht eine gueltige XPath-Subscription.
    $eventTriggerClass = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
    $eventTrigger = New-CimInstance -CimClass $eventTriggerClass -ClientOnly
    $eventTrigger.Enabled = $true
    $eventTrigger.Subscription = "<QueryList><Query Id=""0"" Path=""Application""><Select Path=""Application"">*[System[Provider[@Name='$eventSource'] and (EventID=2000)]]</Select></Query></QueryList>"

    # MultipleInstances=Queue: zwei schnell hintereinander emittierte Events
    # fuehren zu zwei Runs nacheinander (nicht ignorieren), damit Task-Files
    # niemals uebersprungen werden, auch nicht bei Race-Conditions.
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -MultipleInstances Queue

    Register-ScheduledTask -TaskName $taskName -Action $action `
        -Trigger @($atLogon, $eventTrigger) -Settings $settings `
        -Description "agentbox Task Runner — triggered by EventLog (Source=$eventSource, EventID=2000) + AtLogon-Sweep" `
        -RunLevel Highest | Out-Null
    Write-Host "[OK] Scheduled Task '$taskName' angelegt (EventLog-Trigger + AtLogon-Sweep)" -ForegroundColor Green
}

# Seeded das Demo-Benchmark-Projekt aus <scriptDir>\tools\ nach
# <baseDir>\demo-benchmark\. Idempotent: kopiert eine Datei nur, wenn sie
# im Ziel noch nicht existiert — User-Modifikationen bleiben unberuehrt.
# Wird VOR Register-AgentboxTaskRunner aufgerufen, damit der Watch-Daemon
# demo-benchmark/ beim initialen Projekt-Enumerate sieht und einen
# FileSystemWatcher auf _tasks/ setzt. Bei umgekehrter Reihenfolge
# (Register-erst, Seed-spaeter) wuerde das Task-File aus dem
# Benchmark-Menu niemals aufgegriffen, weil der Daemon den neuen Ordner
# nicht dynamisch entdeckt.
function Seed-AgentboxDemoBenchmark {
    param(
        $cfg,
        [Parameter(Mandatory)][string]$ScriptDir,
        [Parameter(Mandatory)][string]$BaseDir
    )

    $toolsSrc = Join-Path $ScriptDir "tools"
    if (-not (Test-Path -LiteralPath $toolsSrc)) {
        Write-Host "[INFO] $toolsSrc nicht vorhanden — ueberspringe Demo-Seed" -ForegroundColor Gray
        return
    }
    if (-not (Test-Path -LiteralPath $BaseDir)) {
        Write-Host "[INFO] BaseDir '$BaseDir' existiert nicht — ueberspringe Demo-Seed" -ForegroundColor Gray
        return
    }

    Write-Host "Seede Demo-Benchmark-Projekt..." -ForegroundColor Cyan
    $demoDir = Join-Path $BaseDir "demo-benchmark"
    if (-not (Test-Path -LiteralPath $demoDir)) {
        [System.IO.Directory]::CreateDirectory($demoDir) | Out-Null
    }

    # Zwei Klassen von Dateien:
    # - SOURCE (bench.ps1, bench.sh, index.html): immer overwriten, damit
    #   User beim Install-Rerun die Fixes aus dem Repo bekommen.
    #   bench.ps1 + bench.sh sind Code, nicht Config. index.html wird eh
    #   bei jedem bench-Run ueberschrieben -- der initiale Placeholder aus
    #   dem Repo soll die aktuelle Version sein.
    # - CONFIG (project.json, CLAUDE.md): nur wenn fehlend, damit
    #   User-Modifikationen am Build-Command oder an der Agent-Doku
    #   unberuehrt bleiben.
    # - EXCLUDED (bench-results.json): nie seeden, ist Runtime-State.
    $sourceFiles = @("bench.ps1", "bench.sh", "index.html")
    $excluded = @("bench-results.json")
    $overwritten = 0; $created = 0; $kept = 0
    Get-ChildItem -LiteralPath $toolsSrc -File | ForEach-Object {
        if ($excluded -contains $_.Name) { return }
        $dest = Join-Path $demoDir $_.Name
        $exists = Test-Path -LiteralPath $dest
        if ($sourceFiles -contains $_.Name) {
            # Source file: always overwrite to propagate repo updates.
            Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
            if ($exists) { $overwritten++ } else { $created++ }
        } elseif (-not $exists) {
            # Config file: seed only if missing.
            Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
            $created++
        } else {
            $kept++
        }
    }
    Write-Host "[OK] demo-benchmark: $created neu, $overwritten aktualisiert (bench.*/index.html), $kept unberuehrt (User-Config)" -ForegroundColor Green
    Write-Host "     Pfad: $demoDir" -ForegroundColor Gray
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
        [System.IO.Directory]::CreateDirectory($dir) | Out-Null
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
        [System.IO.Directory]::CreateDirectory($dir) | Out-Null
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

$haveTarGz = Test-Path -LiteralPath $templatePath
$haveVhd   = Test-Path -LiteralPath $templateVhdPath
if (($haveTarGz -or $haveVhd) -and (Test-Path -LiteralPath $configHashFile)) {
    $savedHash = ""
    try { $savedHash = (Get-Content -LiteralPath $configHashFile -Raw -ErrorAction SilentlyContinue).Trim() } catch {}
    if ($savedHash -eq $currentHash) {
        # Welches Format aktuell im Cache? vhdx hat Vorrang (2.0-Fastpath).
        $shownPath = if ($haveVhd) { $templateVhdPath } else { $templatePath }
        $templateSize = [math]::Round((Get-Item $shownPath).Length / 1MB, 1)
        Write-Host ""
        Write-Host "[OK] Template bereits aktuell — ueberspringe Build" -ForegroundColor Green
        Write-Host "     Pfad: $shownPath ($templateSize MB)" -ForegroundColor Gray
        Write-Host "     Hash: $savedHash" -ForegroundColor Gray
        Write-Host "     Erzwinge Rebuild: loesche $configHashFile oder aendere config.json" -ForegroundColor Gray

        # --- Demo-Benchmark zuerst seeden, DANN Task-Runner starten ---
        # Reihenfolge ist kritisch: der Watch-Daemon enumeriert Projekte
        # einmalig beim Start und setzt FileSystemWatcher nur auf dann
        # existierende _tasks/-Ordner. Wenn demo-benchmark erst nach
        # Register-AgentboxTaskRunner angelegt wird, sieht der Daemon
        # ihn nie und Task-Files bleiben liegen.
        $demoBaseDir = $null
        if ($config -and $config.base_path_override -and $config.base_path_override -ne "") {
            $demoBaseDir = $config.base_path_override
        } elseif ($env:OneDrive) {
            $demoBaseName = if ($config -and $config.base_dir_name) { $config.base_dir_name } else { "AI_Projects_Source" }
            $demoBaseDir = Join-Path $env:OneDrive $demoBaseName
        }
        if ($demoBaseDir) {
            Seed-AgentboxDemoBenchmark -cfg $config -ScriptDir $scriptDir -BaseDir $demoBaseDir
        }

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
    [System.IO.Directory]::CreateDirectory($tempBase) | Out-Null
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

if ([System.IO.Directory]::Exists($tempSetup)) {
    # .NET-API statt Remove-Item: PS 5.1 hat einen Provider-Bug, bei dem
    # Remove-Item -LiteralPath bei Tilde-Pfaden ($env:TEMP unter Umlaut-User
    # → SCHLER~1) mit InvalidArgument crasht, obwohl Test-Path true returnt.
    try { [System.IO.Directory]::Delete($tempSetup, $true) } catch { }
}
# New-Item kennt in PS 5.1 kein -LiteralPath (erst ab PS 6) — .NET-API nutzen.
[System.IO.Directory]::CreateDirectory($tempSetup) | Out-Null

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
                "gemini" { "npm install -g @google/gemini-cli@latest" }
                "aider"  { "pip3 install aider-chat" }
                "goose"  { "pip3 install goose-ai" }
            }
        }

        if ($installCmd) {
            # _run_agent forkt den Install-Command als Background-Job
            # (siehe Install-Skript unten). Name und Command werden als
            # single-quote-geschuetzte Bash-Argumente uebergeben; Install-
            # Commands aus config.json duerfen darum keine einfachen
            # Anfuehrungszeichen enthalten.
            $safeName = $agentName -replace "'", "'\''"
            $safeCmd  = $installCmd -replace "'", "'\''"
            $agentInstallLines += "_run_agent '$safeName' '$safeCmd'"
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

# --- Build-Performance-Tuning ---
# dpkg-fsync-Sync nach jedem Paket-File ausschalten. dpkg ruft sonst
# pro installierter Datei fdatasync(), was bei Noble (~5000 Dateien nur
# fuer nodejs+python3) 30-50s pro Build kostet. Sicher weil das Template
# ohnehin verworfen wird wenn der Build stirbt — wir rebuilden dann.
mkdir -p /etc/dpkg/dpkg.cfg.d
echo 'force-unsafe-io' > /etc/dpkg/dpkg.cfg.d/99-agentbox-unsafe-io

# apt-Pipelining: parallel Downloads aus der Paketquelle. Default ist
# Pipeline-Depth=10; mit 20 + access-Queue-Mode werden mehrere Connections
# parallel aufgebaut. Rettet 20-30s wenn mehrere Gigabytes an apt-Paketen
# (nodejs+python3-Stack) gezogen werden.
mkdir -p /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/99-agentbox-fastbuild <<'APTCONF'
Acquire::http::Pipeline-Depth "20";
Acquire::Queue-Mode "access";
Acquire::Retries "3";
APTCONF

step "       [1/5] System-Update..."
apt-get update
# Alle Basis-Pakete in einem Call: apt-utils muss trotzdem VORHAND sein
# bevor debconf was anderes prompted, also nehmen wir apt-utils direkt in
# diesen Call. Spart ~5s gegenueber zwei separaten apt-get install-Calls.
apt-get install -y -qq --no-install-recommends \
    apt-utils bash curl wget git iptables ca-certificates dnsutils dnsmasq-base

step "       [2/5] Node.js installieren..."
curl -fsSL __NODEJS_URL__ -o /tmp/nodesource_setup.sh
bash /tmp/nodesource_setup.sh
apt-get install -y -qq --no-install-recommends nodejs
step "              node $(node --version), npm $(npm --version)"

step "       [3/5] Python3 installieren..."
apt-get install -y -qq --no-install-recommends python3 python3-pip python3-venv
step "              $(python3 --version)"

step "       [4/5] AI CLI-Tools installieren (parallel)..."
# Parallele Agent-Installs: npm/pip sind I/O- und netzwerkgebunden, eine
# einzelne Installation saturiert weder CPU noch Bandbreite. 3 parallele
# Calls (Claude, Codex, Gemini) kompensieren Latenz + Unpack-Phasen.
# Jeder Agent hat eigenes Logfile in /tmp/agent-*.log — Fehler-Messages
# werden nach Abschluss rausgedumpt, damit der Hauptlog nicht interleaved.
_run_agent() {
    local _name="$1"
    local _cmd="$2"
    local _slug
    _slug=$(echo "$_name" | tr ' /:.' '____')
    local _logfile="/tmp/agent-${_slug}.log"
    (
        step "         - $_name (starte)"
        if bash -c "$_cmd" > "$_logfile" 2>&1; then
            step "         - $_name (fertig)"
        else
            local _rc=$?
            step "       WARNUNG: $_name Installation fehlgeschlagen (rc=$_rc)" >&3
            # Logfile-Tail in Haupt-Install-Log spiegeln fuer Diagnose
            echo "=== $_name FAILED (rc=$_rc) ===" >&2
            tail -n 40 "$_logfile" >&2 || true
            echo "=== end $_name ===" >&2
        fi
    ) &
}

__AGENT_INSTALL_BLOCK__

# Auf alle parallelen Installs warten, bevor das Template exportiert wird.
# `wait` ohne Argumente wartet auf alle gespawnten Background-Jobs; wir
# kuemmern uns hier nicht um individuelle Exit-Codes, weil der spaetere
# "Agent-Binaries verifizieren"-Block (in PS) jeden erwarteten Agent
# haerter pruefen wird und bei Fehlen den Template-Export abbricht.
wait

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
    Write-Host ""
    # Install-Log dumpen BEVOR die Distro unregistriert wird — sonst rate-spielen
    # wir, ob npm/pip/Network/Prefix schuld war. Der installRc-Pfad oben dumpt
    # das Log auch, hier brauchen wir es zusaetzlich, weil installRc=0 sein kann
    # waehrend die Agent-Installs (mit `|| echo WARNUNG`-Fallback) heimlich
    # gescheitert sind.
    Write-Host "        Letzte 120 Zeilen aus /var/log/agentbox-install.log:" -ForegroundColor Yellow
    $logTail = @(& wsl.exe -d $distroName -- tail -n 120 /var/log/agentbox-install.log 2>&1 | ForEach-Object { "$_" })
    foreach ($line in $logTail) { Write-Host "        $line" -ForegroundColor DarkGray }
    Write-Host ""
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
# agentbox 2.0: vhdx ist der primaere Pfad (Session-Start ~5s via import-
# in-place). tar.gz bauen wir nur als Fallback, falls der vhdx-Export hier
# fehlschlaegt (alte WSL-Version, kein `--export --vhd`-Support). Das
# spart beim typischen Build 60-90s (gzip von ~3GB Template).
Write-Host ""
Write-Host "Exportiere Template..." -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $sandboxDir)) {
    [System.IO.Directory]::CreateDirectory($sandboxDir) | Out-Null
}

# Zielpfade vorab bereinigen — sonst gibt wsl --export die Fehlermeldung
# "Datei existiert" statt zu ueberschreiben.
foreach ($existing in @($templateVhdPath, $templatePath)) {
    if (Test-Path -LiteralPath $existing) {
        try { [System.IO.File]::Delete($existing) } catch { }
    }
}

# --- Schritt 1: vhdx-Export (primaer) ---
$vhdExportOut = @(& wsl.exe --export --vhd $distroName $templateVhdPath 2>&1 | ForEach-Object { "$_" })
$vhdOk = ($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $templateVhdPath)

if ($vhdOk) {
    $vhdSize = [math]::Round((Get-Item $templateVhdPath).Length / 1MB, 1)
    Write-Host "[OK] Template-VHDX exportiert: $templateVhdPath ($vhdSize MB)" -ForegroundColor Green
} else {
    Write-Host "[INFO] VHDX-Export nicht verfuegbar (WSL zu alt?) — Fallback auf tar.gz" -ForegroundColor Gray
    if ($vhdExportOut.Count -gt 0) {
        foreach ($line in $vhdExportOut) {
            $clean = ($line -replace "`0", "").Trim()
            if ($clean) { Write-Host "       $clean" -ForegroundColor DarkGray }
        }
    }
    # Halb-erzeugte Datei wegraeumen
    if (Test-Path -LiteralPath $templateVhdPath) {
        try { [System.IO.File]::Delete($templateVhdPath) } catch { }
    }
}

# --- Schritt 2: tar.gz-Export (nur wenn vhdx fehlschlug) ---
# Wenn vhdx sauber ist, sparen wir uns den tar.gz-Export. wsl-ai-start.sh
# nutzt die vhdx per import-in-place. Veraltete tar.gz aus frueheren Builds
# liegen hier ebenfalls schon geloescht (siehe oben) — wsl-ai-start.sh
# erkennt an fehlender tar.gz einfach "kein Fallback" und bleibt auf vhdx.
if (-not $vhdOk) {
    & wsl.exe --export $distroName $templatePath 2>&1 | ForEach-Object { "$_" } | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FEHLER: Weder vhdx- noch tar.gz-Export erfolgreich." -ForegroundColor Red
        & wsl.exe --unregister $distroName 2>&1 | Out-Null
        exit 1
    }
    $templateSize = [math]::Round((Get-Item $templatePath).Length / 1MB, 1)
    Write-Host "[OK] Template exportiert (tar.gz-Fallback): $templatePath ($templateSize MB)" -ForegroundColor Green
}

# Config-Hash speichern (fuer naechsten Skip-Check)
try {
    $currentHash | Out-File -LiteralPath $configHashFile -Encoding ascii -NoNewline
} catch { }

# --- Temporaere Distro entfernen ---
Write-Host "Entferne temporaere Build-Distro..." -ForegroundColor Cyan
& wsl.exe --unregister $distroName 2>&1 | Out-Null
if ([System.IO.Directory]::Exists($tempSetup)) {
    # .NET-API statt Remove-Item (PS 5.1 Tilde-Provider-Bug)
    try { [System.IO.Directory]::Delete($tempSetup, $true) } catch { }
}
Write-Host "[OK] Build-Distro entfernt" -ForegroundColor Green

# --- Demo-Benchmark-Projekt seeden VOR Task-Runner-Start ---
# Reihenfolge kritisch: der Watch-Daemon enumeriert Projekte einmalig
# beim Start. Seed muss vorher stehen, sonst sieht der Daemon das
# demo-benchmark/-Verzeichnis nicht und Task-Files bleiben unbemerkt.
$demoBaseDir = $null
if ($config -and $config.base_path_override -and $config.base_path_override -ne "") {
    $demoBaseDir = $config.base_path_override
} elseif ($env:OneDrive) {
    $demoBaseName = if ($config -and $config.base_dir_name) { $config.base_dir_name } else { "AI_Projects_Source" }
    $demoBaseDir = Join-Path $env:OneDrive $demoBaseName
}
if ($demoBaseDir) {
    Seed-AgentboxDemoBenchmark -cfg $config -ScriptDir $scriptDir -BaseDir $demoBaseDir
}

# --- Event-Source + Scheduled Task registrieren ---
Write-Host ""
Register-AgentboxTaskRunner -cfg $config -ScriptDir $scriptDir

# --- Fertig ---
Write-Host ""
Write-Host "=== Setup abgeschlossen ===" -ForegroundColor Green
Write-Host ""

} # end if (-not $agentboxSkipBuild)
