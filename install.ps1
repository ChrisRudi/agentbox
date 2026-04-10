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

# --- 2. WSL2 pruefen ---
try {
    $wslOutput = & wsl.exe --status 2>&1
    if ($LASTEXITCODE -ne 0) { throw "WSL nicht aktiv" }
} catch {
    Write-Host "FEHLER: WSL2 ist nicht installiert oder nicht aktiv." -ForegroundColor Red
    Write-Host "Installieren mit: wsl --install" -ForegroundColor Yellow
    exit 1
}
Write-Host "[OK] WSL2 erkannt" -ForegroundColor Green

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
if (-not $env:OneDrive) {
    Write-Host "FEHLER: OneDrive-Umgebungsvariable nicht gesetzt." -ForegroundColor Red
    Write-Host "OneDrive muss eingerichtet sein." -ForegroundColor Yellow
    exit 1
}

$baseDir = Join-Path $env:OneDrive "AI_Projects_Source"
$controlDir = Join-Path $baseDir "_control"

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

# --- 8. Desktop-Shortcut erstellen ---
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

# --- 9. Erfolgsmeldung ---
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host " agentbox erfolgreich installiert!      " -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Starten:" -ForegroundColor Cyan
Write-Host "  - Doppelklick auf 'agentbox' am Desktop" -ForegroundColor White
Write-Host "  - Oder: WSL-Terminal oeffnen und 'agentbox' eingeben" -ForegroundColor White
Write-Host ""
