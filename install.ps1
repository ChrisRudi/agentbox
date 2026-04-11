# install.ps1
# agentbox Bootstrap — Einziger Befehl: irm https://raw.githubusercontent.com/chrisrudi/agentbox/main/install.ps1 | iex
# Braucht: Admin-Rechte, WSL2, Git
# Version: 3.2

param()

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

# --- 3. Git pruefen ---
try {
    $gitVersion = & git.exe --version 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Git nicht gefunden" }
} catch {
    Write-Host "FEHLER: Git ist nicht installiert." -ForegroundColor Red
    Write-Host "Download: https://git-scm.com/download/win" -ForegroundColor Yellow
    exit 1
}
Write-Host "[OK] $gitVersion" -ForegroundColor Green

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

if (Test-Path (Join-Path $controlDir ".git")) {
    Write-Host ""
    Write-Host "agentbox bereits installiert — aktualisiere..." -ForegroundColor Yellow
    Push-Location $controlDir
    try {
        & git.exe pull origin main 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "git pull fehlgeschlagen" }
        Write-Host "[OK] Update abgeschlossen" -ForegroundColor Green
    } catch {
        Write-Host "WARNUNG: git pull fehlgeschlagen, fahre mit bestehender Version fort." -ForegroundColor Yellow
    } finally {
        Pop-Location
    }
} else {
    Write-Host ""
    Write-Host "Klone agentbox Repository..." -ForegroundColor Cyan
    $tempClone = Join-Path $env:TEMP "agentbox_clone_$(Get-Random)"

    try {
        & git.exe clone $repoUrl $tempClone 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "git clone fehlgeschlagen" }

        if (Test-Path $controlDir) {
            Remove-Item -Path $controlDir -Recurse -Force
        }

        Copy-Item -Path $tempClone -Destination $controlDir -Recurse -Force
        Write-Host "[OK] agentbox installiert nach: $controlDir" -ForegroundColor Green
    } catch {
        Write-Host "FEHLER: Repository konnte nicht geklont werden." -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        exit 1
    } finally {
        if (Test-Path $tempClone) {
            Remove-Item -Path $tempClone -Recurse -Force -ErrorAction SilentlyContinue
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
