# win-setup-core.ps1
# agentbox — Einmalige Einrichtung: Template bauen, Event-Source, Scheduled Task
# Wird von win-setup.ps1 per Invoke-Expression geladen ($scriptDir ist bereits gesetzt)

if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }

$ErrorActionPreference = "Continue"

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

& wsl.exe --import $distroName $tempSetup $downloadPath 2>&1 | Out-Host
if ($LASTEXITCODE -ne 0) {
    Write-Host "FEHLER: WSL-Import fehlgeschlagen." -ForegroundColor Red
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
            $agentInstallLines += ($installCmd + ' 2>/dev/null || echo "WARNUNG: ' + $agentName + ' Installation fehlgeschlagen"')
        }
    }
}

$agentInstallBlock = $agentInstallLines -join "`n"
$nodejsUrl = if ($config -and $config.nodejs_setup_url) { $config.nodejs_setup_url } else { "https://deb.nodesource.com/setup_20.x" }

$installScript = @'
#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive

echo "[1/5] System-Update..."
apt-get update -qq
apt-get install -y -qq bash curl wget git iptables > /dev/null 2>&1

echo "[2/5] Node.js installieren..."
curl -fsSL __NODEJS_URL__ | bash - > /dev/null 2>&1
apt-get install -y -qq nodejs > /dev/null 2>&1

echo "[3/5] Python3 installieren..."
apt-get install -y -qq python3 python3-pip python3-venv > /dev/null 2>&1

echo "[4/5] AI CLI-Tools installieren..."
__AGENT_INSTALL_BLOCK__

echo "[5/5] Aufraumen..."
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

echo "Pakete fertig installiert."
'@
$installScript = $installScript.Replace('__NODEJS_URL__', $nodejsUrl).Replace('__AGENT_INSTALL_BLOCK__', $agentInstallBlock)

& wsl.exe -d $distroName -- bash -c $installScript 2>&1 | Out-Host
if ($LASTEXITCODE -ne 0) {
    Write-Host "WARNUNG: Einige Pakete konnten nicht installiert werden." -ForegroundColor Yellow
}
Write-Host "[OK] Pakete installiert" -ForegroundColor Green

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

$setupFirewall = @'
mkdir -p /etc/agentbox
cat > /etc/agentbox/firewall.sh << 'FWEOF'
__FIREWALL_SCRIPT__
FWEOF
chmod +x /etc/agentbox/firewall.sh
'@
$setupFirewall = $setupFirewall.Replace('__FIREWALL_SCRIPT__', $firewallScript)

& wsl.exe -d $distroName -- bash -c $setupFirewall 2>&1 | Out-Host
Write-Host "[OK] Firewall-Regeln hinterlegt" -ForegroundColor Green

# --- 6. Sysctl-Hardening ---
Write-Host "Setze Sysctl-Hardening..." -ForegroundColor Cyan

$sysctlScript = @'
cat >> /etc/sysctl.conf << 'EOF'
# agentbox — Hardlink- und Symlink-Schutz
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
EOF
sysctl -p > /dev/null 2>&1 || true
'@

& wsl.exe -d $distroName -- bash -c $sysctlScript 2>&1 | Out-Host
Write-Host "[OK] Sysctl-Hardening gesetzt" -ForegroundColor Green

# --- 7. SYSTEM_META_PROMPT.md in Distro kopieren ---
Write-Host "Kopiere SYSTEM_META_PROMPT.md..." -ForegroundColor Cyan

$metaPromptSrc = Join-Path $scriptDir "SYSTEM_META_PROMPT.md"
if (Test-Path $metaPromptSrc) {
    $wslMetaPath = & wsl.exe -d $distroName -- wslpath -u ($metaPromptSrc -replace '\\', '/') 2>&1
    & wsl.exe -d $distroName -- bash -c "mkdir -p /etc/agentbox && cp '$($wslMetaPath.Trim())' /etc/agentbox/SYSTEM_META_PROMPT.md" 2>&1 | Out-Host
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

& wsl.exe --export $distroName $templatePath 2>&1 | Out-Host
if ($LASTEXITCODE -ne 0) {
    Write-Host "FEHLER: Template-Export fehlgeschlagen." -ForegroundColor Red
    & wsl.exe --unregister $distroName 2>&1 | Out-Null
    exit 1
}

# Config-Hash speichern (fuer Auto-Update Rebuild-Erkennung)
$configHashFile = Join-Path $sandboxDir ".config_hash"
try {
    if ($config) {
        $hashKeys = ($config.PSObject.Properties |
            Where-Object { $_.Name -match '^agent_' -or $_.Name -in @('ubuntu_image_url','nodejs_setup_url') } |
            Sort-Object Name |
            ForEach-Object { "$($_.Name)=$($_.Value)" }) -join "|"
        $md5 = [System.Security.Cryptography.MD5]::Create()
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($hashKeys)
        $hash = ($md5.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join ""
        $hash | Out-File -FilePath $configHashFile -Encoding ascii -NoNewline
    }
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

# --- 10. Windows Event-Source registrieren ---
Write-Host ""
Write-Host "Registriere Windows Event-Source..." -ForegroundColor Cyan

$eventSource = if ($config -and $config.event_log_source) { $config.event_log_source } else { "AIProjects" }
$eventLog = "Application"

if (-not [System.Diagnostics.EventLog]::SourceExists($eventSource)) {
    [System.Diagnostics.EventLog]::CreateEventSource($eventSource, $eventLog)
    Write-Host "[OK] Event-Source '$eventSource' registriert" -ForegroundColor Green
} else {
    Write-Host "[OK] Event-Source '$eventSource' bereits vorhanden" -ForegroundColor Green
}

# --- 11. Scheduled Task anlegen ---
Write-Host "Erstelle Scheduled Task..." -ForegroundColor Cyan

$taskName = if ($config -and $config.scheduled_task_name) { $config.scheduled_task_name } else { "agentbox-task-runner" }
$runnerScript = Join-Path $scriptDir "win-task-runner.ps1"

$existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existingTask) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$runnerScript`" -once" `
    -WorkingDirectory $scriptDir

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

# --- Fertig ---
Write-Host ""
Write-Host "=== Setup abgeschlossen ===" -ForegroundColor Green
Write-Host ""
