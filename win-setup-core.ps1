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
$sandboxDir = Join-Path $scriptDir "sandbox"
$templatePath = Join-Path $sandboxDir "template.tar.gz"
$tempBase = Join-Path $env:TEMP "agentbox"
$tempSetup = Join-Path $tempBase "setup"
$distroName = "agentbox-template-build"

# --- config.json laden ---
$configPath = Join-Path $scriptDir "config.json"
$config = $null
try {
    if (Test-Path $configPath) {
        $config = Get-Content -Path $configPath -Raw -ErrorAction Stop | ConvertFrom-Json
    }
} catch {
    Write-Host "[INFO] config.json nicht lesbar — verwende Standardwerte." -ForegroundColor Gray
}

# --- 1. WSL2 pruefen ---
try {
    $wslOutput = & wsl.exe --status 2>&1
    if ($LASTEXITCODE -ne 0) { throw "WSL nicht aktiv" }
} catch {
    Write-Host "FEHLER: WSL2 ist nicht installiert oder nicht aktiv." -ForegroundColor Red
    exit 1
}
Write-Host "[OK] WSL2 aktiv" -ForegroundColor Green

# --- 1b. Template-Rebuild noetig? ---
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

# Registriert die Windows Event-Source und den Scheduled Task, den der
# win-task-runner.ps1 an jedem Login braucht. Wird aus zwei Stellen aufgerufen:
# 1) wenn der Template-Build uebersprungen wird (Config-Hash unveraendert), und
# 2) am Ende eines vollstaendigen Builds. Vorher war der Code an beiden Stellen
# kopiert — mit leicht abweichender Task-Description und damit Drift-Risiko.
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

    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existingTask) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false }

    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$runnerScript`" -once" `
        -WorkingDirectory $ScriptDir
    $trigger = New-ScheduledTaskTrigger -AtLogon
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable

    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Description "agentbox Task Runner — verarbeitet Build/Deploy-Tasks von AI-Agenten" `
        -RunLevel Highest | Out-Null

    Write-Host "[OK] Scheduled Task '$taskName' angelegt" -ForegroundColor Green
}

$configHashFile = Join-Path $sandboxDir ".config_hash"
$currentHash = Get-AgentboxConfigHash -cfg $config

if ((Test-Path $templatePath) -and (Test-Path $configHashFile)) {
    $savedHash = ""
    try { $savedHash = (Get-Content -Path $configHashFile -Raw -ErrorAction SilentlyContinue).Trim() } catch {}
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

# --- 2. Ubuntu-Minimal herunterladen ---
Write-Host ""
Write-Host "Lade Ubuntu-Minimal herunter..." -ForegroundColor Cyan

$ubuntuUrl = if ($config -and $config.ubuntu_image_url) { $config.ubuntu_image_url } else {
    "https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-amd64-root.tar.xz"
}
$downloadPath = Join-Path $tempBase "ubuntu-minimal.tar.xz"

if (-not (Test-Path $tempBase)) {
    New-Item -ItemType Directory -Path $tempBase -Force | Out-Null
}

if (-not (Test-Path $downloadPath)) {
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

# --- 3. Temporaere Distro importieren ---
Write-Host ""
Write-Host "Importiere temporaere Distro fuer Template-Build..." -ForegroundColor Cyan

# Alte temporaere Distro entfernen falls vorhanden
$existingDistros = & wsl.exe -l -q 2>&1
if ($existingDistros -match $distroName) {
    Write-Host "Entferne alte temporaere Distro..." -ForegroundColor Yellow
    & wsl.exe --unregister $distroName 2>&1 | Out-Null
}

if (Test-Path $tempSetup) {
    Remove-Item -Path $tempSetup -Recurse -Force
}
New-Item -ItemType Directory -Path $tempSetup -Force | Out-Null

# Output als String-Array einsammeln (nicht live ausgeben):
# - Stderr-Zeilen werden stringifiziert → kein NativeCommandError
# - Success-Zeile 'Der Vorgang wurde erfolgreich beendet.' wird nicht gezeigt
# - Fehler-Output bleibt fuer HCS-Detection + Log-Anzeige erhalten
$importOutput = @(& wsl.exe --import $distroName $tempSetup $downloadPath 2>&1 | ForEach-Object { "$_" })
$importExit = $LASTEXITCODE
if ($importExit -ne 0) {
    $importText = ($importOutput -join "`n")
    foreach ($line in $importOutput) { Write-Host "       $line" -ForegroundColor DarkGray }
    if ($importText -match 'HCS_E_SERVICE_NOT_AVAILABLE' -or $importText -match 'HCS/HCS_') {
        Write-Host ""
        Write-Host "FEHLER: Hyper-V Host Compute Service (vmcompute) nicht verfuegbar." -ForegroundColor Red
        Write-Host "        Das passiert typischerweise direkt nach 'wsl --install'" -ForegroundColor Yellow
        Write-Host "        auf einem frischen System: Die VM-Features sind aktiviert," -ForegroundColor Yellow
        Write-Host "        aber der Dienst startet erst nach einem Neustart." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "        Bitte den PC neu starten und install.ps1 erneut ausfuehren:" -ForegroundColor Yellow
        Write-Host "          irm https://raw.githubusercontent.com/ChrisRudi/agentbox/main/install.ps1 | iex" -ForegroundColor White
    } else {
        Write-Host "FEHLER: WSL-Import fehlgeschlagen." -ForegroundColor Red
    }
    exit 1
}
Write-Host "[OK] Temporaere Distro importiert" -ForegroundColor Green

# --- 4. Pakete installieren ---
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

# Output durch ForEach stringifizieren → verhindert dass PS Stderr-Zeilen
# als ErrorRecord-Objekte in den Pipe-Stream wirft (rote Error-Kaestchen).
$installOutput = @(& wsl.exe -d $distroName -- bash -c $runInstall 2>&1 | ForEach-Object { "$_" })
foreach ($line in $installOutput) { Write-Host $line -ForegroundColor Gray }

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

# --- 4b. Agent-Binaries verifizieren (HART: Abbruch bei fehlenden Agents) ---
Write-Host ""
Write-Host "Verifiziere Agent-Binaries..." -ForegroundColor Cyan
$missingAgents = @()
foreach ($aid in $agentIds) {
    $enabledProp = "agent_${aid}_enabled"
    $cmdProp = "agent_${aid}_command"
    $isEnabled = $false
    if ($config -and (Get-Member -InputObject $config -Name $enabledProp -MemberType NoteProperty)) {
        $isEnabled = $config.$enabledProp
    } elseif ($aid -in @("claude", "codex", "gemini")) {
        # Muss mit dem Install-Block oben uebereinstimmen — sonst wuerde ein
        # Default-enabled Agent zwar installiert, aber nicht verifiziert.
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

# --- 5. iptables-Regeln hinterlegen ---
Write-Host ""
Write-Host "Hinterlege Firewall-Regeln..." -ForegroundColor Cyan

$fwAiApis = if ($config -and $config.firewall_ai_apis) {
    ($config.firewall_ai_apis -join " ")
} else { "api.anthropic.com api.openai.com generativelanguage.googleapis.com" }

$fwRegistries = @()
if ($config -and $config.firewall_registries_node)   { $fwRegistries += $config.firewall_registries_node }
if ($config -and $config.firewall_registries_python)  { $fwRegistries += $config.firewall_registries_python }
$fwPkgDomains = if ($fwRegistries.Count -gt 0) { $fwRegistries -join " " } else { "registry.npmjs.org pypi.org files.pythonhosted.org" }

$firewallScript = @'
#!/bin/bash
# firewall.sh — agentbox Netzwerk-Isolation
set -e

iptables -F OUTPUT 2>/dev/null || true
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

for domain in __FW_AI_APIS__; do
    for ip in $(dig +short "$domain" 2>/dev/null); do
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            iptables -A OUTPUT -p tcp --dport 443 -d "$ip" -j ACCEPT
        fi
    done
done

for domain in __FW_PKG_DOMAINS__; do
    for ip in $(dig +short "$domain" 2>/dev/null); do
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            iptables -A OUTPUT -p tcp --dport 443 -d "$ip" -j ACCEPT
        fi
    done
done

iptables -A OUTPUT -j DROP
echo "Firewall-Regeln angewendet."
'@
$firewallScript = $firewallScript.Replace('__FW_AI_APIS__', $fwAiApis).Replace('__FW_PKG_DOMAINS__', $fwPkgDomains)

$firewallScript = $firewallScript.Replace("`r", "")
$fwB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($firewallScript))
$setupFirewall = "mkdir -p /etc/agentbox && echo $fwB64 | base64 -d > /etc/agentbox/firewall.sh && chmod +x /etc/agentbox/firewall.sh"
# Stringify + Out-Null: Commands die keine nuetzliche Ausgabe produzieren werden
# geschluckt, damit PS 5.1 nicht aus einer harmlosen stderr-Zeile einen
# NativeCommandError-Record macht (rote Error-Kaestchen im Log).
& wsl.exe -d $distroName -- bash -c $setupFirewall 2>&1 | ForEach-Object { "$_" } | Out-Null
Write-Host "[OK] Firewall-Regeln hinterlegt" -ForegroundColor Green

# --- 6. Sysctl-Hardening ---
Write-Host "Setze Sysctl-Hardening..." -ForegroundColor Cyan

$sysctlContent = "# agentbox — Hardlink- und Symlink-Schutz`nfs.protected_hardlinks = 1`nfs.protected_symlinks = 1"
$sysctlB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($sysctlContent))
$sysctlCmd = "echo $sysctlB64 | base64 -d >> /etc/sysctl.conf && sysctl -p > /dev/null 2>&1 || true"
& wsl.exe -d $distroName -- bash -c $sysctlCmd 2>&1 | ForEach-Object { "$_" } | Out-Null
Write-Host "[OK] Sysctl-Hardening gesetzt" -ForegroundColor Green

# --- 7. SYSTEM_META_PROMPT.md in Distro kopieren ---
Write-Host "Kopiere SYSTEM_META_PROMPT.md..." -ForegroundColor Cyan

$metaPromptSrc = Join-Path $scriptDir "SYSTEM_META_PROMPT.md"
if (Test-Path $metaPromptSrc) {
    # wslpath hier im Template-Distro-Kontext ist OK (die Distro existiert),
    # Stderr trotzdem stringifizieren fuer einheitliches Verhalten.
    $wslMetaPath = (& wsl.exe -d $distroName -- wslpath -u ($metaPromptSrc -replace '\\', '/') 2>&1 | ForEach-Object { "$_" }) -join ""
    & wsl.exe -d $distroName -- bash -c "mkdir -p /etc/agentbox && cp '$($wslMetaPath.Trim())' /etc/agentbox/SYSTEM_META_PROMPT.md" 2>&1 | ForEach-Object { "$_" } | Out-Null
    Write-Host "[OK] SYSTEM_META_PROMPT.md kopiert" -ForegroundColor Green
} else {
    Write-Host "WARNUNG: SYSTEM_META_PROMPT.md nicht gefunden in $scriptDir" -ForegroundColor Yellow
}

# --- 8. Template exportieren ---
Write-Host ""
Write-Host "Exportiere Template..." -ForegroundColor Cyan

if (-not (Test-Path $sandboxDir)) {
    New-Item -ItemType Directory -Path $sandboxDir -Force | Out-Null
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
    $currentHash | Out-File -FilePath $configHashFile -Encoding ascii -NoNewline
} catch { }

$templateSize = [math]::Round((Get-Item $templatePath).Length / 1MB, 1)
Write-Host "[OK] Template exportiert: $templatePath ($templateSize MB)" -ForegroundColor Green

# --- 9. Temporaere Distro entfernen ---
Write-Host "Entferne temporaere Build-Distro..." -ForegroundColor Cyan
& wsl.exe --unregister $distroName 2>&1 | Out-Null
if (Test-Path $tempSetup) {
    Remove-Item -Path $tempSetup -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "[OK] Build-Distro entfernt" -ForegroundColor Green

# --- 10. Event-Source + Scheduled Task registrieren ---
Write-Host ""
Register-AgentboxTaskRunner -cfg $config -ScriptDir $scriptDir

# --- Fertig ---
Write-Host ""
Write-Host "=== Setup abgeschlossen ===" -ForegroundColor Green
Write-Host ""

} # end if (-not $agentboxSkipBuild)
