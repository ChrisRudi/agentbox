# install.ps1 — agentbox Bootstrap (PS 5.1 kompatibel)
# CRLF-Selbstreparatur fuer den Fall dass die Datei lokal mit LF-Zeilenenden vorliegt.
if (-not $env:_AGENTBOX_CRLF) { $p = $MyInvocation.MyCommand.Path; if ($p -and (Test-Path $p)) { $t = [IO.File]::ReadAllText($p); if (-not $t.Contains("`r")) { [IO.File]::WriteAllText($p, $t.Replace("`n", "`r`n")); $env:_AGENTBOX_CRLF = '1'; & $p; return } } }
$env:_AGENTBOX_CRLF = $null

$ErrorActionPreference = "Stop"

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

        # Pruefen ob Neustart noetig
        try {
            $wslCheck = & wsl.exe --status 2>&1
            if ($LASTEXITCODE -ne 0) { throw "WSL noch nicht bereit" }
            Write-Host "[OK] WSL2 erfolgreich eingerichtet" -ForegroundColor Green
        } catch {
            Write-Host ""
            Write-Host "========================================" -ForegroundColor Yellow
            Write-Host " Neustart erforderlich!                 " -ForegroundColor Yellow
            Write-Host "========================================" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "WSL2-Features wurden aktiviert. Bitte den PC neu starten" -ForegroundColor Yellow
            Write-Host "und danach install.ps1 erneut ausfuehren:" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  irm https://raw.githubusercontent.com/ChrisRudi/agentbox/main/install.ps1 | iex" -ForegroundColor White
            Write-Host ""
            exit 0
        }
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
                    $userConfig | Out-File -FilePath $existingConfigPath -Encoding utf8NoBOM -NoNewline
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

& $setupScript
if ($LASTEXITCODE -ne 0) {
    Write-Host "WARNUNG: win-setup.ps1 meldete Fehler. Bitte manuell pruefen." -ForegroundColor Yellow
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
$conflictCheck = & wsl.exe bash -c "grep -E '$patternList' $bashrcPath 2>/dev/null | head -1" 2>&1
if ($conflictCheck -and "$conflictCheck".Trim() -ne "") {
    Write-Host "[WARN] Fremder AI-Tool-Starter in ~/.bashrc erkannt:" -ForegroundColor Yellow
    Write-Host "       $conflictCheck" -ForegroundColor Gray
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
    $tmpPy = Join-Path $env:TEMP "agentbox_bashrc_cleanup_$(Get-Random).py"
    $cleanupScript | Out-File -FilePath $tmpPy -Encoding utf8NoBOM -NoNewline
    $wslPy = & wsl.exe wslpath -u ($tmpPy -replace '\\', '/') 2>&1
    & wsl.exe bash -c "python3 '$($wslPy.Trim())' 2>&1" 2>&1 | Out-Host
    Remove-Item -Path $tmpPy -Force -ErrorAction SilentlyContinue
}

$checkResult = & wsl.exe bash -c "grep -c '$bashrcMarker' ~/.bashrc 2>/dev/null || echo 0" 2>&1
$alreadyPresent = ($checkResult.Trim() -ne "0")

if (-not $alreadyPresent) {
    $wslBasePath = & wsl.exe wslpath -u ($baseDir -replace '\\', '/') 2>&1
    $wslBasePath = $wslBasePath.Trim()

    $bashrcBlock = @"

$bashrcMarker
export AI_PROJECTS_ROOT="$wslBasePath"
if [ -f "`$AI_PROJECTS_ROOT/_control/wsl-ai-start.sh" ]; then
    alias agentbox='bash "`$AI_PROJECTS_ROOT/_control/wsl-ai-start.sh"'
    # Auto-Start: fragt 5s ob agentbox starten soll, Enter/Timeout = Ja, n = normales Terminal
    bash "`$AI_PROJECTS_ROOT/_control/wsl-ai-start.sh" --auto
fi
"@

    # Schreibe den Block sicher ueber eine temporaere Datei
    $tempBashrc = Join-Path $env:TEMP "agentbox_bashrc_$(Get-Random).tmp"
    $bashrcBlock | Out-File -FilePath $tempBashrc -Encoding ascii -NoNewline
    $wslTempPath = & wsl.exe wslpath -u ($tempBashrc -replace '\\', '/') 2>&1
    & wsl.exe bash -c "cat '$($wslTempPath.Trim())' >> ~/.bashrc" 2>&1
    Remove-Item -Path $tempBashrc -Force -ErrorAction SilentlyContinue

    Write-Host "[OK] .bashrc-Eintrag gesetzt" -ForegroundColor Green
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

# --- 9. Desktop-Shortcut erstellen ---
Write-Host ""
Write-Host "Erstelle Desktop-Shortcut..." -ForegroundColor Cyan

$desktopPath = [Environment]::GetFolderPath("Desktop")
$shortcutPath = Join-Path $desktopPath "agentbox.lnk"

try {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = "wsl.exe"
    $shortcut.Arguments = "-e bash -li -c agentbox"
    $shortcut.WorkingDirectory = "%USERPROFILE%"
    $shortcut.Description = "agentbox — Sandboxed AI Agent Runner"
    $shortcut.IconLocation = "wsl.exe,0"
    $shortcut.Save()
    [System.Runtime.Interopservices.Marshal]::ReleaseComObject($shell) | Out-Null
    Write-Host "[OK] Desktop-Shortcut erstellt: $shortcutPath" -ForegroundColor Green
} catch {
    Write-Host "WARNUNG: Desktop-Shortcut konnte nicht erstellt werden." -ForegroundColor Yellow
    Write-Host $_.Exception.Message -ForegroundColor Yellow
}

# --- 10. Erfolgsmeldung ---
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host " agentbox erfolgreich installiert!      " -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Starten:" -ForegroundColor Cyan
Write-Host "  - Doppelklick auf 'agentbox' am Desktop" -ForegroundColor White
Write-Host "  - Oder: WSL-Terminal oeffnen und 'agentbox' eingeben" -ForegroundColor White
Write-Host ""
