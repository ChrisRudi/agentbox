# install.ps1 — agentbox Bootstrap (PS 5.1 kompatibel)
# CRLF-Selbstreparatur fuer den Fall dass die Datei lokal mit LF-Zeilenenden vorliegt.
if (-not $env:_AGENTBOX_CRLF) { $p = $MyInvocation.MyCommand.Path; if ($p -and (Test-Path $p)) { $t = [IO.File]::ReadAllText($p); if (-not $t.Contains("`r")) { [IO.File]::WriteAllText($p, $t.Replace("`n", "`r`n")); $env:_AGENTBOX_CRLF = '1'; & $p; return } } }
$env:_AGENTBOX_CRLF = $null

$ErrorActionPreference = "Stop"

# --- UTF-8 Ausgabe fuer wsl.exe erzwingen (sonst UTF-16LE → Mojibake in PS 5.1) ---
# WSL_UTF8=1 ab WSL 0.64.0 (Win10 2004+, Win11). Zusaetzlich Console-Encoding
# auf UTF-8 setzen, damit Ausgaben nativer Tools korrekt interpretiert werden.
$env:WSL_UTF8 = "1"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# --- Pure-PS Windows → WSL Pfad-Konvertierung ---
# Ersatz fuer `wsl.exe wslpath -u`. Laeuft OHNE laufende Default-Distro,
# was wichtig ist: nach dem Template-Build hat agentbox die
# `agentbox-template-build`-Distro wieder entfernt, und falls der User
# sonst keine Default-Distro hat, schlaegt `wsl wslpath` fehl. Ausserdem
# stolpert wslpath auf manchen Systemen ueber OneDrive-Reparse-Points
# (Files-On-Demand) und gibt dann eine fehlerhafte Stderr-Zeile aus, die
# PS 5.1 als NativeCommandError aufschnappt und — bei
# $ErrorActionPreference='Stop' — den Installer killt.
function ConvertTo-WslPath {
    param([Parameter(Mandatory)][string]$WindowsPath)
    $p = $WindowsPath -replace '\\', '/'
    if ($p -match '^([A-Za-z]):(/?.*)$') {
        $drive = $matches[1].ToLower()
        $rest  = $matches[2]
        if (-not $rest.StartsWith('/')) { $rest = '/' + $rest }
        return "/mnt/$drive$rest"
    }
    return $p
}

# --- WSL-Distro-Inventar ---
# Liefert die registrierten Distros als Array (ohne '*' Default-Marker und
# ohne die ephemere `agentbox-template-build`-Build-Distro). `wsl -l -q`
# schreibt je nach Windows-Version UTF-16LE mit BOM und fuegt NUL-Bytes ein;
# wir saeubern die Ausgabe rigoros, damit der String-Vergleich zuverlaessig ist.
# Liefert leeres Array, wenn WSL keine Distros kennt — damit wir sauber
# "es gibt keine Distro" erkennen koennen, statt im `bash -c`-Aufruf
# spaeter ins Leere zu greifen.
function Get-WslRegisteredDistros {
    # 2>&1 + Stringify + try/catch: PS 5.1 unter $ErrorActionPreference='Stop'
    # wirft bei stderr-Ausgaben nativer Tools sonst NativeCommandError-Records.
    $raw = $null
    try {
        $raw = & wsl.exe -l -q 2>&1 | ForEach-Object { "$_" }
    } catch {
        return @()
    }
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return @() }
    $distros = @()
    foreach ($line in @($raw)) {
        $clean = ("$line" -replace "`0", "").Trim()
        if (-not $clean) { continue }
        # "Windows-Subsystem fuer Linux verfuegt ueber keine installierten
        # Distributionen" ist Stderr-Text, kein Distro-Name — ignorieren.
        if ($clean -match 'installierten Distributionen' -or
            $clean -match 'no installed distributions' -or
            $clean -match 'keine installierten') { continue }
        # agentbox-template-build ist die ephemere Build-Distro aus win-setup-core.ps1
        # und zaehlt fuer uns nicht als "installierte Distro".
        if ($clean -eq "agentbox-template-build") { continue }
        $distros += $clean
    }
    return ,$distros
}

# Import einer persistenten agentbox-host-Distro aus dem frisch gebauten
# Template. Wird nur aufgerufen, wenn sonst KEINE Distro registriert ist:
# ohne Default-Distro scheitern alle spaeteren `wsl.exe bash -c`-Aufrufe
# (inkl. .bashrc-Eintrag) und auch der Desktop-Shortcut `wsl.exe -e bash -li -c agentbox`.
# Das Template enthaelt bereits bash/python3/git/curl sowie die Agent-CLIs
# und kann deshalb 1:1 als Host-Distro verwendet werden.
function Import-AgentboxHostDistro {
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [string]$DistroName = "agentbox-host"
    )
    if (-not (Test-Path $TemplatePath)) {
        Write-Host "FEHLER: Template nicht gefunden: $TemplatePath" -ForegroundColor Red
        return $false
    }
    $hostDir = Join-Path $env:LOCALAPPDATA "agentbox\host-distro"
    if (-not (Test-Path $hostDir)) {
        New-Item -ItemType Directory -Path $hostDir -Force | Out-Null
    }
    # Falls eine alte $DistroName-Registrierung herumliegt (vorheriger Lauf),
    # zuerst abmelden — wsl --import scheitert sonst mit "already exists".
    $existing = & wsl.exe -l -q 2>&1 | ForEach-Object { ("$_" -replace "`0", "").Trim() }
    if ($existing -contains $DistroName) {
        & wsl.exe --unregister $DistroName 2>&1 | Out-Null
    }
    Write-Host "Importiere Host-Distro '$DistroName' aus Template..." -ForegroundColor Cyan
    Write-Host "       Ziel: $hostDir" -ForegroundColor Gray
    $importOutput = @(& wsl.exe --import $DistroName $hostDir $TemplatePath 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) {
        foreach ($l in $importOutput) { Write-Host "       $l" -ForegroundColor DarkGray }
        Write-Host "FEHLER: Import der Host-Distro fehlgeschlagen." -ForegroundColor Red
        return $false
    }
    # Als Default setzen — damit funktionieren `wsl.exe bash -c ...` und der
    # Desktop-Shortcut `wsl.exe -e bash -li -c agentbox` ohne explizites `-d`.
    & wsl.exe --set-default $DistroName 2>&1 | Out-Null
    Write-Host "[OK] Host-Distro '$DistroName' importiert und als Default gesetzt" -ForegroundColor Green
    return $true
}

Write-Host ""
Write-Host "=== agentbox Installer ===" -ForegroundColor Cyan
Write-Host "Sandboxed AI Agent Runner fuer Windows + WSL2" -ForegroundColor Gray
Write-Host ""

# --- 1. Admin-Rechte pruefen ---
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdmin) {
    Write-Host "FEHLER: Bitte als Administrator ausfuehren." -ForegroundColor Red
    Write-Host "Rechtsklick auf PowerShell > 'Als Administrator ausfuehren'" -ForegroundColor Yellow
    exit 1
}
Write-Host "[OK] Admin-Rechte vorhanden" -ForegroundColor Green

# --- 2. Windows-Version pruefen ---
$osVersion = [System.Environment]::OSVersion.Version
$osBuild = $osVersion.Build
$osName = (Get-CimInstance Win32_OperatingSystem).Caption

# Windows 10 Build 19041+ (2004) oder Windows 11 (Build 22000+)
if ($osBuild -lt 19041) {
    Write-Host "FEHLER: Windows 10 Version 2004 (Build 19041) oder hoeher benoetigt." -ForegroundColor Red
    Write-Host "Aktuell: $osName (Build $osBuild)" -ForegroundColor Yellow
    Write-Host "Bitte Windows aktualisieren." -ForegroundColor Yellow
    exit 1
}
Write-Host "[OK] $osName (Build $osBuild)" -ForegroundColor Green

# --- 2b. WSL2 pruefen und bei Bedarf installieren ---
$wslReady = $false
try {
    $wslOutput = & wsl.exe --status 2>&1
    if ($LASTEXITCODE -eq 0) { $wslReady = $true }
} catch { }

if (-not $wslReady) {
    Write-Host ""
    Write-Host "WSL2 ist nicht installiert — richte es automatisch ein..." -ForegroundColor Yellow

    if ($osBuild -ge 19041) {
        # Methode 1: wsl --install (funktioniert ab Win10 2004 mit neueren Updates + Win11)
        Write-Host "Versuche: wsl --install --no-distribution ..." -ForegroundColor Cyan
        $installResult = & wsl.exe --install --no-distribution 2>&1
        $installSuccess = ($LASTEXITCODE -eq 0)

        if (-not $installSuccess) {
            # Methode 2: Features manuell aktivieren (aeltere Win10 Builds)
            Write-Host "Fallback: Aktiviere WSL- und VM-Features manuell..." -ForegroundColor Cyan

            $features = @(
                @{ Name = "Microsoft-Windows-Subsystem-Linux"; Display = "Windows Subsystem for Linux" },
                @{ Name = "VirtualMachinePlatform";           Display = "Virtual Machine Platform" }
            )

            foreach ($feat in $features) {
                $state = (Get-WindowsOptionalFeature -Online -FeatureName $feat.Name).State
                if ($state -ne "Enabled") {
                    Write-Host "  Aktiviere $($feat.Display)..." -ForegroundColor Gray
                    Enable-WindowsOptionalFeature -Online -FeatureName $feat.Name -NoRestart -ErrorAction Stop | Out-Null
                    Write-Host "  [OK] $($feat.Display) aktiviert" -ForegroundColor Green
                } else {
                    Write-Host "  [OK] $($feat.Display) bereits aktiv" -ForegroundColor Green
                }
            }

            # WSL2 als Standard setzen
            & wsl.exe --set-default-version 2 2>&1 | Out-Null

            # WSL-Kernel-Update herunterladen und installieren
            Write-Host "  Lade WSL2-Kernel-Update herunter..." -ForegroundColor Gray
            $kernelUrl = "https://wslstorestorage.blob.core.windows.net/wslblob/wsl_update_x64.msi"
            $kernelMsi = Join-Path $env:TEMP "wsl_update_x64.msi"
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $kernelUrl -OutFile $kernelMsi -UseBasicParsing
            Start-Process msiexec.exe -ArgumentList "/i", "`"$kernelMsi`"", "/quiet", "/norestart" -Wait -NoNewWindow
            Remove-Item -Path $kernelMsi -Force -ErrorAction SilentlyContinue
            Write-Host "  [OK] WSL2-Kernel-Update installiert" -ForegroundColor Green

            & wsl.exe --set-default-version 2 2>&1 | Out-Null
        }

        # Pruefen ob Neustart noetig.
        # `wsl --status` sagt nichts darueber aus, ob der Hyper-V Host Compute
        # Service (vmcompute) wirklich laeuft — auf frischen Systemen ist das
        # Feature aktiviert, der Dienst startet aber erst nach einem Reboot.
        # Ohne diesen Dienst schlaegt spaeter `wsl --import` mit
        # HCS_E_SERVICE_NOT_AVAILABLE fehl. Daher hier explizit pruefen.
        $needsReboot = $false

        try {
            $wslCheck = & wsl.exe --status 2>&1
            if ($LASTEXITCODE -ne 0) { $needsReboot = $true }
        } catch { $needsReboot = $true }

        if (-not $needsReboot) {
            $vmcompute = Get-Service -Name vmcompute -ErrorAction SilentlyContinue
            if (-not $vmcompute) {
                # Dienst existiert noch nicht — Feature ist erst nach Reboot aktiv
                $needsReboot = $true
            } elseif ($vmcompute.Status -ne 'Running') {
                try {
                    Start-Service -Name vmcompute -ErrorAction Stop
                } catch {
                    $needsReboot = $true
                }
            }
        }

        # Zusaetzlich CBS Pending-Reboot Flag pruefen (gesetzt wenn ein Feature
        # aktiviert wurde, dessen Aktivierung einen Reboot verlangt).
        if (-not $needsReboot) {
            $cbsPending = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"
            if (Test-Path $cbsPending) { $needsReboot = $true }
        }

        if ($needsReboot) {
            Write-Host ""
            Write-Host "========================================" -ForegroundColor Yellow
            Write-Host " Neustart erforderlich!                 " -ForegroundColor Yellow
            Write-Host "========================================" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "WSL2-Features wurden aktiviert, aber der Hyper-V Host" -ForegroundColor Yellow
            Write-Host "Compute Service (vmcompute) laeuft erst nach einem Reboot." -ForegroundColor Yellow
            Write-Host "Bitte den PC neu starten und install.ps1 erneut ausfuehren:" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  irm https://raw.githubusercontent.com/ChrisRudi/agentbox/main/install.ps1 | iex" -ForegroundColor White
            Write-Host ""
            exit 0
        }

        Write-Host "[OK] WSL2 erfolgreich eingerichtet" -ForegroundColor Green
    }
} else {
    Write-Host "[OK] WSL2 aktiv" -ForegroundColor Green
}

# --- 3. Git pruefen (optional — wird fuer ZIP-Fallback nicht benoetigt) ---
$hasGit = $false
try {
    $gitVersion = & git.exe --version 2>&1
    if ($LASTEXITCODE -eq 0) {
        $hasGit = $true
        Write-Host "[OK] $gitVersion (wird fuer Updates genutzt)" -ForegroundColor Green
    }
} catch { }
if (-not $hasGit) {
    Write-Host "[INFO] Git nicht gefunden — Installation per ZIP-Download." -ForegroundColor Gray
}

# --- 4. Zielordner bestimmen ---
# Default: OneDrive\AI_Projects_Source (kann per config.json ueberschrieben werden)
$baseDir = $null
$controlDir = $null

# Pruefen ob bereits installiert — dann config.json lesen fuer base_path_override
$possibleControlDirs = @()
if ($env:OneDrive) {
    $possibleControlDirs += Join-Path (Join-Path $env:OneDrive "AI_Projects_Source") "_control"
}

foreach ($tryDir in $possibleControlDirs) {
    $tryConfig = Join-Path $tryDir "config.json"
    if (Test-Path $tryConfig) {
        try {
            $existingConfig = Get-Content -Path $tryConfig -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($existingConfig.base_path_override -and $existingConfig.base_path_override -ne "") {
                $baseDir = $existingConfig.base_path_override
                $controlDirName = if ($existingConfig.control_dir_name) { $existingConfig.control_dir_name } else { "_control" }
                $controlDir = Join-Path $baseDir $controlDirName
                Write-Host "[INFO] base_path_override aus config.json: $baseDir" -ForegroundColor Cyan
            }
        } catch { }
    }
}

# Fallback auf OneDrive-Standard
if (-not $baseDir) {
    if (-not $env:OneDrive) {
        Write-Host "FEHLER: OneDrive-Umgebungsvariable nicht gesetzt." -ForegroundColor Red
        Write-Host "OneDrive muss eingerichtet sein, oder setze 'base_path_override' in config.json." -ForegroundColor Yellow
        exit 1
    }
    $baseDir = Join-Path $env:OneDrive "AI_Projects_Source"
    $controlDir = Join-Path $baseDir "_control"
}

if (-not (Test-Path $baseDir)) {
    New-Item -ItemType Directory -Path $baseDir -Force | Out-Null
    Write-Host "[OK] Basisordner erstellt: $baseDir" -ForegroundColor Green
}

# --- 5. Update oder Neuinstallation ---
$repoUrl = "https://github.com/chrisrudi/agentbox.git"
$zipUrl = "https://github.com/ChrisRudi/agentbox/archive/refs/heads/main.zip"
$versionUrl = "https://raw.githubusercontent.com/ChrisRudi/agentbox/main/.version"

$isInstalled = Test-Path $controlDir
$isGitRepo = $isInstalled -and (Test-Path (Join-Path $controlDir ".git"))

if ($isInstalled) {
    # --- Update ---
    Write-Host ""
    Write-Host "agentbox bereits installiert — pruefe Update..." -ForegroundColor Yellow

    # Versionsvergleich
    $localVersion = ""
    $localVersionFile = Join-Path $controlDir ".version"
    if (Test-Path $localVersionFile) {
        $localVersion = (Get-Content -Path $localVersionFile -Raw -ErrorAction SilentlyContinue).Trim()
    }

    $remoteVersion = ""
    try {
        $ProgressPreference = 'SilentlyContinue'
        $remoteVersion = (Invoke-WebRequest -Uri $versionUrl -UseBasicParsing -TimeoutSec 5).Content.Trim()
    } catch {
        Write-Host "[INFO] Versions-Check fehlgeschlagen — pruefe trotzdem." -ForegroundColor Gray
    }

    $needsUpdate = $true
    if ($localVersion -and $remoteVersion -and ($localVersion -eq $remoteVersion)) {
        Write-Host "[OK] Bereits auf Version $localVersion — kein Update noetig." -ForegroundColor Green
        $needsUpdate = $false
    } elseif ($remoteVersion) {
        Write-Host "[INFO] Lokale Version: $localVersion → Remote: $remoteVersion" -ForegroundColor Cyan
    }

    if ($needsUpdate) {
        if ($isGitRepo -and $hasGit) {
            # Bevorzugt: git pull (schneller, inkrementell)
            Push-Location $controlDir
            try {
                & git.exe pull origin main 2>&1 | Out-Host
                if ($LASTEXITCODE -ne 0) { throw "git pull fehlgeschlagen" }
                Write-Host "[OK] Update per git pull abgeschlossen" -ForegroundColor Green
            } catch {
                Write-Host "WARNUNG: git pull fehlgeschlagen, versuche ZIP-Fallback..." -ForegroundColor Yellow
                Pop-Location
                $needsUpdate = $true
                $isGitRepo = $false
            }
            if ($isGitRepo) { Pop-Location; $needsUpdate = $false }
        }

        if ($needsUpdate) {
            # Fallback: ZIP-Download
            Write-Host "Lade neueste Version als ZIP..." -ForegroundColor Cyan
            $tempZip = Join-Path $env:TEMP "agentbox_update_$(Get-Random).zip"
            $tempExtract = Join-Path $env:TEMP "agentbox_extract_$(Get-Random)"
            try {
                $ProgressPreference = 'SilentlyContinue'
                Invoke-WebRequest -Uri $zipUrl -OutFile $tempZip -UseBasicParsing
                Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force

                # ZIP enthaelt agentbox-main/ Unterordner
                $extractedDir = Get-ChildItem -Path $tempExtract -Directory | Select-Object -First 1

                # Bestehende config.json sichern (User-Anpassungen)
                $userConfig = $null
                $existingConfigPath = Join-Path $controlDir "config.json"
                if (Test-Path $existingConfigPath) {
                    $userConfig = Get-Content -Path $existingConfigPath -Raw -ErrorAction SilentlyContinue
                }

                # Dateien aktualisieren (nicht _control loeschen — cache/ und sandbox/ bleiben)
                Get-ChildItem -Path $extractedDir.FullName -Exclude "sandbox","cache" | ForEach-Object {
                    $destPath = Join-Path $controlDir $_.Name
                    if ($_.PSIsContainer) {
                        Copy-Item -Path $_.FullName -Destination $destPath -Recurse -Force
                    } else {
                        Copy-Item -Path $_.FullName -Destination $destPath -Force
                    }
                }

                # User-config.json wiederherstellen falls vorhanden
                if ($userConfig) {
                    [System.IO.File]::WriteAllText($existingConfigPath, $userConfig, (New-Object System.Text.UTF8Encoding $false))
                }

                Write-Host "[OK] Update per ZIP abgeschlossen" -ForegroundColor Green
            } catch {
                Write-Host "WARNUNG: ZIP-Update fehlgeschlagen, fahre mit bestehender Version fort." -ForegroundColor Yellow
                Write-Host $_.Exception.Message -ForegroundColor Yellow
            } finally {
                Remove-Item -Path $tempZip -Force -ErrorAction SilentlyContinue
                Remove-Item -Path $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
} else {
    # --- Neuinstallation ---
    Write-Host ""

    if ($hasGit) {
        Write-Host "Klone agentbox Repository..." -ForegroundColor Cyan
        $tempClone = Join-Path $env:TEMP "agentbox_clone_$(Get-Random)"

        try {
            & git.exe clone $repoUrl $tempClone 2>&1 | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "git clone fehlgeschlagen" }

            Copy-Item -Path $tempClone -Destination $controlDir -Recurse -Force
            Write-Host "[OK] agentbox installiert nach: $controlDir" -ForegroundColor Green
        } catch {
            Write-Host "WARNUNG: git clone fehlgeschlagen, versuche ZIP-Fallback..." -ForegroundColor Yellow
            $hasGit = $false
        } finally {
            if (Test-Path $tempClone) {
                Remove-Item -Path $tempClone -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if (-not $hasGit -or -not (Test-Path $controlDir)) {
        Write-Host "Lade agentbox als ZIP herunter..." -ForegroundColor Cyan
        $tempZip = Join-Path $env:TEMP "agentbox_install_$(Get-Random).zip"
        $tempExtract = Join-Path $env:TEMP "agentbox_extract_$(Get-Random)"

        try {
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $zipUrl -OutFile $tempZip -UseBasicParsing
            Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force

            $extractedDir = Get-ChildItem -Path $tempExtract -Directory | Select-Object -First 1
            Copy-Item -Path $extractedDir.FullName -Destination $controlDir -Recurse -Force
            Write-Host "[OK] agentbox installiert nach: $controlDir" -ForegroundColor Green
        } catch {
            Write-Host "FEHLER: Download fehlgeschlagen." -ForegroundColor Red
            Write-Host $_.Exception.Message -ForegroundColor Red
            exit 1
        } finally {
            Remove-Item -Path $tempZip -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- 6. win-setup.ps1 ausfuehren ---
$setupScript = Join-Path $controlDir "win-setup.ps1"
if (-not (Test-Path $setupScript)) {
    Write-Host "FEHLER: win-setup.ps1 nicht gefunden in $controlDir" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Fuehre win-setup.ps1 aus (Template, Event-Source, Task)..." -ForegroundColor Cyan
Write-Host ""

$setupOk = $true
& $setupScript
if ($LASTEXITCODE -ne 0) {
    $setupOk = $false
    Write-Host "WARNUNG: win-setup.ps1 meldete Fehler. Bitte manuell pruefen." -ForegroundColor Yellow
}

# --- 6b. Host-Distro sicherstellen ---
# agentbox selbst laeuft ephemer (jede Session = eigene Sandbox-Distro, die
# hinterher verworfen wird). Fuer die `.bashrc`-Integration und den Desktop-
# Shortcut brauchen wir aber eine *persistente* Default-Distro, in der
# `wsl.exe bash -c ...` und `wsl.exe -e bash -li -c agentbox` laufen koennen.
#
# Vorher war der Ablauf: win-setup.ps1 baut das Template in einer temporaeren
# `agentbox-template-build`-Distro, meldet sie wieder ab — und wenn der User
# sonst keine Distro hat, stehen danach 0 registrierte Distros da. Die
# folgenden `wsl.exe bash -c`-Aufrufe scheitern dann still (Stderr ist
# 2>$null unterdrueckt), der Installer schreibt trotzdem "[OK] .bashrc-
# Eintrag gesetzt", und am Ende zeigt `wsl` nur noch "keine installierten
# Distributionen". Genau dieses "wsl laesst sich nach dem Installer nicht
# mehr oeffnen"-Symptom wollen wir hier verhindern.
if ($setupOk) {
    $installedDistros = Get-WslRegisteredDistros
    if ($installedDistros.Count -eq 0) {
        Write-Host ""
        Write-Host "Keine WSL-Distro registriert — richte Host-Distro ein..." -ForegroundColor Yellow
        $hostTemplate = Join-Path $controlDir "sandbox\template.tar.gz"
        if (-not (Import-AgentboxHostDistro -TemplatePath $hostTemplate)) {
            $setupOk = $false
        }
    } else {
        Write-Host ""
        Write-Host "[OK] WSL-Distro(s) vorhanden: $($installedDistros -join ', ')" -ForegroundColor Green
    }
}

# --- 7. WSL .bashrc-Eintrag setzen ---
Write-Host ""
Write-Host "Konfiguriere WSL-Integration..." -ForegroundColor Cyan

$bashrcMarker = "# agentbox — AI Agent Sandbox Runner"

# Alte/fremde AI-Tool-Starter in .bashrc erkennen und Backup anbieten.
# Bekannte Konflikt-Marker die einen Agent direkt (nicht-sandboxed) starten:
$conflictPatterns = @(
    'Verfuegbare AI-Tools',
    'Welches Tool moechten Sie verwenden',
    'Gewaehltes Tool: Claude Code',
    'Starte Claude Code\\.\\.\\.',
    'Claude Code wird gestartet'
)
$bashrcPath = "~/.bashrc"
$patternList = $conflictPatterns -join '|'
# Exit-Code-basierte Pruefung statt Output-Capture:
# - grep -q: exit 0 bei Treffer, 1 sonst
# - Wenn wsl.exe selbst scheitert (z.B. keine Distros installiert), liefert
#   es einen Nicht-Null Exit-Code und wir ueberspringen den Cleanup korrekt.
& wsl.exe bash -c "grep -qE '$patternList' $bashrcPath" 2>$null
$conflictFound = ($LASTEXITCODE -eq 0)
$conflictLine = ""
if ($conflictFound) {
    $conflictLine = & wsl.exe bash -c "grep -m1 -E '$patternList' $bashrcPath" 2>$null
    $conflictLine = "$conflictLine".Trim()
}
if ($conflictFound) {
    Write-Host "[WARN] Fremder AI-Tool-Starter in ~/.bashrc erkannt:" -ForegroundColor Yellow
    if ($conflictLine) { Write-Host "       $conflictLine" -ForegroundColor Gray }
    Write-Host "[INFO] Entferne Konflikt-Block aus ~/.bashrc (Backup: ~/.bashrc.agentbox-backup)" -ForegroundColor Cyan
    # Backup anlegen und Python-Blockentfernung durchfuehren (robuster als sed)
    & wsl.exe bash -c "cp $bashrcPath ~/.bashrc.agentbox-backup" 2>&1 | Out-Null
    $cleanupScript = @"
import re, os
p = os.path.expanduser('~/.bashrc')
with open(p) as f: lines = f.readlines()
# Konflikt-Patterns finden
patterns = [r'Verfuegbare AI-Tools', r'Welches Tool moechten Sie', r'Gewaehltes Tool: Claude', r'Starte Claude Code\.\.\.', r'Claude Code wird gestartet']
rx = re.compile('|'.join(patterns))
# Zeilen entfernen die zu einem Konflikt-Block gehoeren:
# Strategie: finde die erste Konfliktzeile, gehe rueckwaerts bis leer/Kommentar,
# gehe vorwaerts bis leer/naechster Marker. Entferne den Bereich.
conflict_lines = [i for i, l in enumerate(lines) if rx.search(l)]
if conflict_lines:
    start = min(conflict_lines)
    end = max(conflict_lines)
    # Rueckwaerts bis leere Zeile oder agentbox-Marker
    while start > 0 and lines[start-1].strip() != '' and '# agentbox' not in lines[start-1]:
        start -= 1
    # Vorwaerts bis leere Zeile oder agentbox-Marker
    while end < len(lines) - 1 and lines[end+1].strip() != '' and '# agentbox' not in lines[end+1]:
        end += 1
    del lines[start:end+1]
    with open(p, 'w') as f: f.writelines(lines)
    print(f'[OK] Konflikt-Block entfernt (Zeilen {start+1}-{end+1})')
else:
    print('[OK] Kein Konflikt gefunden')
"@
    # Content per base64 + stdin in /tmp/ der Distro schreiben — vermeidet
    # den /mnt/c-Roundtrip, bei dem WSL2 gerade frisch geschriebene Dateien
    # wegen 9P-Sync-Verzoegerung kurzzeitig nicht sieht.
    $cleanupScript = $cleanupScript -replace "`r", ""
    $cleanupB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($cleanupScript))
    $runCleanup = "echo $cleanupB64 | base64 -d > /tmp/agentbox_bashrc_cleanup.py && python3 /tmp/agentbox_bashrc_cleanup.py; rc=`$?; rm -f /tmp/agentbox_bashrc_cleanup.py; exit `$rc"
    & wsl.exe bash -c $runCleanup 2>&1 | ForEach-Object { "$_" } | Out-Host
}

# Exit-Code-basierte Pruefung: grep -q ist zuverlaessiger als Output-Capture,
# und faengt den Fall ab, dass wsl.exe selbst scheitert (keine Distros).
& wsl.exe bash -c "grep -qF '$bashrcMarker' ~/.bashrc" 2>$null
$alreadyPresent = ($LASTEXITCODE -eq 0)

if (-not $alreadyPresent) {
    $wslBasePath = ConvertTo-WslPath $baseDir

    $bashrcBlock = @"

$bashrcMarker
export AI_PROJECTS_ROOT="$wslBasePath"
if [ -f "`$AI_PROJECTS_ROOT/_control/wsl-ai-start.sh" ]; then
    alias agentbox='bash "`$AI_PROJECTS_ROOT/_control/wsl-ai-start.sh"'
    # Auto-Start: fragt 5s ob agentbox starten soll, Enter/Timeout = Ja, n = normales Terminal
    bash "`$AI_PROJECTS_ROOT/_control/wsl-ai-start.sh" --auto
fi
"@

    # Block per base64 direkt an wsl.exe pipen — KEINE Temp-Datei auf /mnt/c.
    # Grund: WSL2 hat einen bekannten 9P-Sync-Bug, bei dem gerade mit Out-File
    # geschriebene Dateien von Linux-Seite aus ein paar Millisekunden unsichtbar
    # sind → "cat: /mnt/c/.../xxx.tmp: No such file or directory". base64 + stdin
    # umgeht das Windows-Filesystem komplett.
    $bashrcBlock = $bashrcBlock -replace "`r", ""
    $bashrcB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($bashrcBlock))
    & wsl.exe bash -c "echo $bashrcB64 | base64 -d >> ~/.bashrc" 2>&1 | ForEach-Object { "$_" } | Out-Null
    $bashrcWriteRc = $LASTEXITCODE

    if ($bashrcWriteRc -ne 0) {
        # Kein stilles "[OK]" mehr, wenn wsl.exe den Write nicht ausfuehren
        # konnte (z.B. weil doch keine Default-Distro da ist). Frueher hat
        # der Installer hier gelogen und der User stand danach vor einem
        # nicht mehr oeffenbaren WSL.
        Write-Host "FEHLER: .bashrc-Eintrag konnte nicht geschrieben werden (wsl exit $bashrcWriteRc)." -ForegroundColor Red
        Write-Host "        Pruefe 'wsl -l -v' — vermutlich ist keine Default-Distro registriert." -ForegroundColor Yellow
        $setupOk = $false
    } else {
        Write-Host "[OK] .bashrc-Eintrag gesetzt" -ForegroundColor Green
    }
} else {
    Write-Host "[OK] .bashrc-Eintrag bereits vorhanden" -ForegroundColor Green
}

# --- 8. WSL Ressourcen-Limits (.wslconfig) ---
Write-Host ""
Write-Host "Pruefe WSL Ressourcen-Limits..." -ForegroundColor Cyan

# Werte aus config.json lesen (nach Clone verfuegbar)
$installConfig = $null
$installConfigPath = Join-Path $controlDir "config.json"
try {
    if (Test-Path $installConfigPath) {
        $installConfig = Get-Content -Path $installConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json
    }
} catch { }

$resMem  = if ($installConfig -and $installConfig.resources_memory)     { $installConfig.resources_memory }     else { "4GB" }
$resCpu  = if ($installConfig -and $installConfig.resources_processors) { $installConfig.resources_processors } else { 2 }
$resSwap = if ($installConfig -and $installConfig.resources_swap)       { $installConfig.resources_swap }       else { "1GB" }

$wslConfigPath = Join-Path $env:USERPROFILE ".wslconfig"
$wslConfigMarker = "# agentbox"

if (-not (Test-Path $wslConfigPath)) {
    # .wslconfig existiert nicht — mit Werten aus config.json erstellen
    $wslConfigContent = @"
$wslConfigMarker — Ressourcen-Limits fuer Sandbox-Distros
[wsl2]
memory=$resMem
processors=$resCpu
swap=$resSwap
"@
    $wslConfigContent | Out-File -FilePath $wslConfigPath -Encoding ascii -NoNewline
    Write-Host "[OK] .wslconfig erstellt ($resMem RAM, $resCpu CPUs, $resSwap Swap)" -ForegroundColor Green
    Write-Host "     Anpassbar unter: $wslConfigPath oder in config.json" -ForegroundColor Gray
} else {
    # .wslconfig existiert — pruefen ob bereits konfiguriert
    $existingConfig = Get-Content -Path $wslConfigPath -Raw -ErrorAction SilentlyContinue
    if ($existingConfig -match [regex]::Escape($wslConfigMarker)) {
        Write-Host "[OK] .wslconfig bereits durch agentbox konfiguriert" -ForegroundColor Green
    } else {
        Write-Host "[INFO] .wslconfig existiert bereits mit eigenen Einstellungen." -ForegroundColor Yellow
        Write-Host "       Empfehlung: memory=4GB und processors=2 setzen," -ForegroundColor Yellow
        Write-Host "       damit ein Agent den Host nicht lahmlegen kann." -ForegroundColor Yellow
        Write-Host "       Datei: $wslConfigPath" -ForegroundColor Gray
    }
}

# --- 9. Bei fehlgeschlagenem Setup: hier abbrechen, BEVOR Shortcut erstellt wird ---
# Ein Shortcut auf 'wsl.exe -e bash -li -c agentbox' ohne funktionierende
# Sandbox-Template waere irrefuehrend — der Doppelklick wuerde nur Fehler zeigen.
if (-not $setupOk) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
    Write-Host " agentbox Installation UNVOLLSTAENDIG   " -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "win-setup.ps1 ist fehlgeschlagen — Template wurde nicht gebaut." -ForegroundColor Yellow
    Write-Host "Desktop-Shortcut wurde NICHT erstellt (waere ohne Ziel)." -ForegroundColor Yellow
    Write-Host "Bitte die Fehlermeldung oben pruefen und install.ps1 erneut ausfuehren." -ForegroundColor Yellow
    Write-Host "Falls ein Reboot verlangt wurde: zuerst neu starten." -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

# --- 10. Desktop-Shortcuts erstellen (nur bei erfolgreichem Setup) ---
Write-Host ""
Write-Host "Erstelle Desktop-Shortcuts..." -ForegroundColor Cyan

$desktopPath = [Environment]::GetFolderPath("Desktop")
$shortcutPath = Join-Path $desktopPath "agentbox.lnk"
$updateShortcutPath = Join-Path $desktopPath "agentbox-installer.lnk"

# Helper: setzt das "Run as administrator"-Flag in einer .lnk-Datei.
# Offset 0x15 ist das Link-Flags-Byte, Bit 0x20 = RunAsAdministrator.
# (Quelle: [MS-SHLLINK] Shell Link Binary File Format, LinkFlags)
function Set-ShortcutRunAsAdmin {
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $bytes[0x15] = $bytes[0x15] -bor 0x20
    [System.IO.File]::WriteAllBytes($Path, $bytes)
}

try {
    $shell = New-Object -ComObject WScript.Shell

    # 1) Agentbox-Start-Shortcut (laeuft im Normal-User-Kontext, kein UAC).
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = "wsl.exe"
    $shortcut.Arguments = "-e bash -li -c agentbox"
    $shortcut.WorkingDirectory = "%USERPROFILE%"
    $shortcut.Description = "agentbox — Sandboxed AI Agent Runner"
    $shortcut.IconLocation = "wsl.exe,0"
    $shortcut.Save()
    Write-Host "[OK] Desktop-Shortcut erstellt: $shortcutPath" -ForegroundColor Green

    # 2) Installer/Update-Shortcut: 'irm ... | iex' als Admin (UAC-Prompt).
    # Verwendung: Doppelklick → UAC → PS laedt frische install.ps1 von GitHub
    # und fuehrt sie aus (idempotent, macht Update wenn schon installiert).
    $updater = $shell.CreateShortcut($updateShortcutPath)
    $updater.TargetPath = "powershell.exe"
    $updater.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command `"irm https://raw.githubusercontent.com/ChrisRudi/agentbox/main/install.ps1 | iex`""
    $updater.WorkingDirectory = "%USERPROFILE%"
    $updater.Description = "agentbox installieren/aktualisieren (als Administrator)"
    $updater.IconLocation = "powershell.exe,0"
    $updater.Save()
    Set-ShortcutRunAsAdmin -Path $updateShortcutPath
    Write-Host "[OK] Installer-Shortcut erstellt: $updateShortcutPath" -ForegroundColor Green
    Write-Host "     (Doppelklick fuer Update/Neuinstall — UAC-Prompt)" -ForegroundColor Gray

    [System.Runtime.Interopservices.Marshal]::ReleaseComObject($shell) | Out-Null
} catch {
    Write-Host "WARNUNG: Desktop-Shortcuts konnten nicht erstellt werden." -ForegroundColor Yellow
    Write-Host $_.Exception.Message -ForegroundColor Yellow
}

# --- 10b. Erfolgsmeldung ---
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host " agentbox erfolgreich installiert!      " -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Starten:" -ForegroundColor Cyan
Write-Host "  - Doppelklick auf 'agentbox' am Desktop" -ForegroundColor White
Write-Host "  - Oder: WSL-Terminal oeffnen und 'agentbox' eingeben" -ForegroundColor White
Write-Host ""

# --- 11. Direkt starten? ---
Write-Host "Jetzt agentbox starten? [J/n] (5s Timeout = ja)" -ForegroundColor Cyan -NoNewline
$startNow = $true
$timeoutSec = 5
$startTime = Get-Date
while (((Get-Date) - $startTime).TotalSeconds -lt $timeoutSec) {
    if ([Console]::KeyAvailable) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq 'N') { $startNow = $false; break }
        if ($key.Key -eq 'Enter' -or $key.Key -eq 'J' -or $key.Key -eq 'Y') { break }
    }
    Start-Sleep -Milliseconds 100
}
Write-Host ""

if ($startNow) {
    Write-Host ""
    Write-Host "Starte agentbox in WSL..." -ForegroundColor Green
    Write-Host ""
    & wsl.exe -e bash -li -c "agentbox"
} else {
    Write-Host "OK — manuell starten via Desktop-Shortcut oder 'wsl' + 'agentbox'." -ForegroundColor Gray
}
