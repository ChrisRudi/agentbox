# install.ps1 — agentbox Bootstrap (PS 5.1 kompatibel)
# CRLF-Selbstreparatur fuer den Fall dass die Datei lokal mit LF-Zeilenenden vorliegt.
if (-not $env:_AGENTBOX_CRLF) { $p = $MyInvocation.MyCommand.Path; if ($p -and (Test-Path -LiteralPath $p)) { $t = [IO.File]::ReadAllText($p); if (-not $t.Contains("`r")) { [IO.File]::WriteAllText($p, $t.Replace("`n", "`r`n")); $env:_AGENTBOX_CRLF = '1'; & $p; return } } }
$env:_AGENTBOX_CRLF = $null

$ErrorActionPreference = "Stop"

# --- UTF-8 Ausgabe fuer wsl.exe erzwingen (sonst UTF-16LE → Mojibake in PS 5.1) ---
# WSL_UTF8=1 ab WSL 0.64.0 (Win10 2004+, Win11). Zusaetzlich Console-Encoding
# auf UTF-8 setzen, damit Ausgaben nativer Tools korrekt interpretiert werden.
$env:WSL_UTF8 = "1"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# --- Helper: Native-Tool-Calls gegen NativeCommandError schuetzen ---
# Hintergrund: PS 5.1 + $ErrorActionPreference='Stop' macht aus jeder stderr-
# Zeile eines nativen Tools (wsl.exe, git.exe, etc.) einen ErrorRecord, AUCH
# mit `2>&1`. Symptom war u.a. der "WSL beendet ein Upgrade..."-Crash beim
# `wsl --version` waehrend eines aktiven WSL-Updates (1.0.7), aber dieselbe
# Falle existiert latent fuer alle wsl-Calls.
#
# Nutzung:
#   $rc = Invoke-Native { & wsl.exe --import $name $dir $tar 2>&1 | ... }
# Der Block laeuft mit ErrorActionPreference='Continue', danach wird der
# vorherige Wert wiederhergestellt. Genuine Exceptions werden trotzdem
# gefangen (try/catch um das & block).
function Invoke-Native {
    param([Parameter(Mandatory)][scriptblock]$Block)
    $prevErr = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $Block
    } catch {
        # NativeCommandError swallow — der Caller prueft $LASTEXITCODE.
    } finally {
        $ErrorActionPreference = $prevErr
    }
}

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
    if (-not (Test-Path -LiteralPath $TemplatePath)) {
        Write-Host "FEHLER: Template nicht gefunden: $TemplatePath" -ForegroundColor Red
        return $false
    }
    $hostDir = Join-Path $env:LOCALAPPDATA "agentbox\host-distro"
    if (-not (Test-Path -LiteralPath $hostDir)) {
        New-Item -ItemType Directory -LiteralPath $hostDir -Force | Out-Null
    }
    # Falls eine alte $DistroName-Registrierung herumliegt (vorheriger Lauf),
    # zuerst abmelden — wsl --import scheitert sonst mit "already exists".
    # Alle wsl-Calls hier ueber Invoke-Native, weil sie unter Stop-Mode an
    # stderr-Output des nativen Tools crashen wuerden (siehe 1.0.7-Fix).
    $existing = @(Invoke-Native { & wsl.exe -l -q 2>&1 | ForEach-Object { ("$_" -replace "`0", "").Trim() } | Where-Object { $_ } })
    if ($existing -contains $DistroName) {
        Invoke-Native { & wsl.exe --unregister $DistroName 2>&1 | Out-Null }
    }
    Write-Host "Importiere Host-Distro '$DistroName' aus Template..." -ForegroundColor Cyan
    Write-Host "       Ziel: $hostDir" -ForegroundColor Gray
    $importOutput = @(Invoke-Native { & wsl.exe --import $DistroName $hostDir $TemplatePath 2>&1 | ForEach-Object { "$_" } })
    if ($LASTEXITCODE -ne 0) {
        foreach ($l in $importOutput) { Write-Host "       $l" -ForegroundColor DarkGray }
        Write-Host "FEHLER: Import der Host-Distro fehlgeschlagen." -ForegroundColor Red
        return $false
    }
    # KEIN expliziter `wsl --set-default`. Begruendung:
    # - Hatte der User vorher gar keine Distro, setzt WSL agentbox-host beim
    #   Import automatisch als Default. ✓
    # - Hatte der User schon eine Default (Ubuntu, Debian, docker-desktop —
    #   egal was), respektieren wir die. agentbox-Aufrufe gehen ueberall mit
    #   `-d agentbox-host` explizit, das funktioniert unabhaengig von der
    #   WSL-Default. Wir aendern nicht das WSL-Setup des Users.
    Write-Host "[OK] Host-Distro '$DistroName' importiert" -ForegroundColor Green
    return $true
}

Write-Host ""
Write-Host "=== agentbox Installer ===" -ForegroundColor Cyan
Write-Host "Sandboxed AI Agent Runner fuer Windows + WSL2" -ForegroundColor Gray
Write-Host ""

# --- Admin-Rechte pruefen ---
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdmin) {
    Write-Host "FEHLER: Bitte als Administrator ausfuehren." -ForegroundColor Red
    Write-Host "Rechtsklick auf PowerShell > 'Als Administrator ausfuehren'" -ForegroundColor Yellow
    exit 1
}
Write-Host "[OK] Admin-Rechte vorhanden" -ForegroundColor Green

# --- Windows-Version pruefen ---
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

# --- WSL2 pruefen und bei Bedarf installieren ---
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
        # Invoke-Native, weil wsl --install Status auf stderr schreibt — sonst
        # crasht der Installer am NativeCommandError unter Stop-Mode.
        Write-Host "Versuche: wsl --install --no-distribution ..." -ForegroundColor Cyan
        $installResult = Invoke-Native { & wsl.exe --install --no-distribution 2>&1 }
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

            # WSL2 als Standard setzen (Invoke-Native gegen stderr-NativeCommandError)
            Invoke-Native { & wsl.exe --set-default-version 2 2>&1 | Out-Null }

            # WSL-Kernel-Update herunterladen und installieren
            Write-Host "  Lade WSL2-Kernel-Update herunter..." -ForegroundColor Gray
            $kernelUrl = "https://wslstorestorage.blob.core.windows.net/wslblob/wsl_update_x64.msi"
            $kernelMsi = Join-Path $env:TEMP "wsl_update_x64.msi"
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $kernelUrl -OutFile $kernelMsi -UseBasicParsing
            Start-Process msiexec.exe -ArgumentList "/i", "`"$kernelMsi`"", "/quiet", "/norestart" -Wait -NoNewWindow
            if ($kernelMsi -and (Test-Path -LiteralPath $kernelMsi)) {
                Remove-Item -LiteralPath $kernelMsi -Force -ErrorAction SilentlyContinue
            }
            Write-Host "  [OK] WSL2-Kernel-Update installiert" -ForegroundColor Green

            Invoke-Native { & wsl.exe --set-default-version 2 2>&1 | Out-Null }
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
            if (Test-Path -LiteralPath $cbsPending) { $needsReboot = $true }
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

# --- WSL-Version-Pre-Flight + Auto-Update ---
# Inbox-WSL (vor Store-WSL ~2023) kann das Ubuntu-24.04-Cloud-Image NICHT
# importieren. Symptom waere ein generisches "Unbekannter Fehler" beim
# spaeteren Template-Build. Wir machen hier KEINEN reinen Detect-and-Tell-User
# mehr, sondern: erkennen, automatisch updaten, ggf. Reboot anbieten. Ein DAU
# soll den Installer doppelklicken und nicht selbst CLI-Befehle eintippen.

function Get-WslVersionLine {
    # Liefert die "WSL Version: X.Y.Z"-Zeile, oder $null wenn nicht verfuegbar.
    # PS 5.1 + $ErrorActionPreference='Stop' macht aus jedem nativen-Tool-
    # stderr einen NativeCommandError, auch mit `2>&1`. wsl.exe --version
    # schreibt Status-Meldungen wie "WSL beendet ein Upgrade..." auf stderr —
    # ohne lokales Continue + try/catch killt das den Installer mitten im
    # Pre-Flight-Loop, obwohl wsl.exe selbst sauber durchlaeuft.
    $prevErr = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = @(& wsl.exe --version 2>&1 | ForEach-Object { ("$_" -replace "`0", "").Trim() })
    } catch {
        $ErrorActionPreference = $prevErr
        return $null
    }
    $ErrorActionPreference = $prevErr
    if ($LASTEXITCODE -ne 0) { return $null }
    foreach ($line in @($out)) {
        if ($line -match 'WSL.*\d+\.\d+') { return $line }
    }
    return $null
}

function Test-WslVersionOk {
    return ($null -ne (Get-WslVersionLine))
}

function Invoke-WslUpdate {
    param([string]$Method = "")
    # NICHT $args verwenden — das ist eine automatische PS-Variable und in
    # einem Function-Scope read-only.
    $wslArgs = @("--update")
    if ($Method -eq "web") { $wslArgs += "--web-download" }
    Write-Host "  > wsl.exe $($wslArgs -join ' ')" -ForegroundColor DarkGray
    # Gleicher PS-5.1-stderr-Schutz wie in Test-WslVersionOk: wsl --update
    # streamt seinen Fortschritt teilweise ueber stderr, was unter
    # $ErrorActionPreference='Stop' den Installer killen wuerde.
    $prevErr = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & wsl.exe @wslArgs 2>&1 | ForEach-Object {
            $line = ("$_" -replace "`0", "").Trim()
            if ($line) { Write-Host "    $line" -ForegroundColor DarkGray }
        }
    } catch {
        Write-Host "    (Pipeline-Fehler beim wsl-Update-Aufruf: $($_.Exception.Message))" -ForegroundColor DarkGray
        $ErrorActionPreference = $prevErr
        return $false
    }
    $ErrorActionPreference = $prevErr
    return ($LASTEXITCODE -eq 0)
}

Write-Host ""
Write-Host "Pruefe WSL-Version..." -ForegroundColor Cyan
$wslVerLine = Get-WslVersionLine
if ($wslVerLine) {
    Write-Host "[OK] $wslVerLine" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "WSL ist veraltet — aktualisiere automatisch..." -ForegroundColor Yellow
    Write-Host "(Inbox-WSL kann das aktuelle Ubuntu-24.04-Image nicht importieren." -ForegroundColor Gray
    Write-Host " Das hier kann 1-3 Minuten dauern.)" -ForegroundColor Gray
    Write-Host ""

    # Versuch 1: Standard wsl --update (geht ueber Microsoft Store)
    [void](Invoke-WslUpdate)
    $wslUpdateOk = Test-WslVersionOk

    # Versuch 2: Web-Download (umgeht Store, falls Store geblockt/kaputt)
    if (-not $wslUpdateOk) {
        Write-Host ""
        Write-Host "Standard-Update ohne Erfolg — versuche Web-Download..." -ForegroundColor Yellow
        [void](Invoke-WslUpdate -Method "web")
        $wslUpdateOk = Test-WslVersionOk
    }

    if (-not $wslUpdateOk) {
        # Beide Versuche gescheitert — User muss manuell ran. Klare Anweisung,
        # keine "irgendwo in der CLI eintippen"-Aufgabe.
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Red
        Write-Host " WSL-Update fehlgeschlagen              " -ForegroundColor Red
        Write-Host "========================================" -ForegroundColor Red
        Write-Host ""
        Write-Host "agentbox konnte WSL nicht automatisch aktualisieren. Mach bitte:" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  1. Microsoft Store oeffnen" -ForegroundColor White
        Write-Host "  2. nach 'Windows Subsystem for Linux' suchen" -ForegroundColor White
        Write-Host "     (Herausgeber: Microsoft Corporation, kostenlos)" -ForegroundColor Gray
        Write-Host "  3. auf 'Installieren' klicken und warten" -ForegroundColor White
        Write-Host "  4. Windows EINMAL neu starten" -ForegroundColor White
        Write-Host "  5. agentbox-Installer erneut starten (Doppelklick auf den Shortcut," -ForegroundColor White
        Write-Host "     oder dieses Fenster nochmal aufrufen)" -ForegroundColor White
        Write-Host ""
        Write-Host "Hintergrund: Das in Windows eingebaute WSL ist von 2022 und kann das" -ForegroundColor DarkGray
        Write-Host "aktuelle Ubuntu-24.04-Cloud-Image nicht importieren." -ForegroundColor DarkGray
        Write-Host ""
        exit 1
    }

    Write-Host ""
    $wslVerLineAfter = Get-WslVersionLine
    if ($wslVerLineAfter) {
        Write-Host "[OK] WSL erfolgreich aktualisiert: $wslVerLineAfter" -ForegroundColor Green
    } else {
        Write-Host "[OK] WSL erfolgreich aktualisiert." -ForegroundColor Green
    }
    Write-Host ""

    # Reboot empfohlen: der neue WSL-Kernel/wslservice ist erst nach einem
    # Neustart sicher aktiv. Wir testen `Test-WslVersionOk` ist zwar erfolgreich,
    # aber `wsl --import` kann trotzdem in ERROR_HCS_E_HYPERV_NOT_INSTALLED
    # laufen, weil vmcompute noch die alte Kernel-Version sieht.
    Write-Host "Damit der neue WSL-Kernel sicher aktiv wird, sollte Windows einmal" -ForegroundColor Yellow
    Write-Host "neu gestartet werden. Soll ich Windows JETZT neu starten?" -ForegroundColor Yellow
    Write-Host "(Nach dem Reboot bitte den agentbox-Installer-Shortcut erneut ausfuehren," -ForegroundColor Gray
    Write-Host " oder dieses Fenster wieder aufrufen.)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  [J] Ja, jetzt neu starten" -ForegroundColor White
    Write-Host "  [N] Nein, ich starte spaeter selbst neu" -ForegroundColor White
    Write-Host ""
    $rebootChoice = Read-Host "Auswahl [J/n]"
    $rebootChoice = "$rebootChoice".Trim()
    if ($rebootChoice -eq "" -or $rebootChoice -match '^(j|J|ja|Ja|JA|y|Y|yes|Yes|YES)$') {
        Write-Host ""
        Write-Host "Starte Windows in 10 Sekunden neu..." -ForegroundColor Cyan
        Write-Host "(Ctrl+C zum Abbrechen)" -ForegroundColor Gray
        Start-Sleep -Seconds 10
        Restart-Computer -Force
        exit 0
    } else {
        Write-Host ""
        Write-Host "OK — bitte spaeter manuell neu starten und den Installer erneut ausfuehren." -ForegroundColor Yellow
        exit 0
    }
}

# --- Git pruefen (optional — wird fuer ZIP-Fallback nicht benoetigt) ---
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

# --- Zielordner bestimmen ---
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
    if (Test-Path -LiteralPath $tryConfig) {
        try {
            $existingConfig = Get-Content -LiteralPath $tryConfig -Raw -ErrorAction Stop | ConvertFrom-Json
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

if (-not (Test-Path -LiteralPath $baseDir)) {
    New-Item -ItemType Directory -LiteralPath $baseDir -Force | Out-Null
    Write-Host "[OK] Basisordner erstellt: $baseDir" -ForegroundColor Green
}

# --- Update oder Neuinstallation ---
$repoUrl = "https://github.com/chrisrudi/agentbox.git"
$zipUrl = "https://github.com/ChrisRudi/agentbox/archive/refs/heads/main.zip"
$versionUrl = "https://raw.githubusercontent.com/ChrisRudi/agentbox/main/.version"

$isInstalled = Test-Path -LiteralPath $controlDir
$isGitRepo = $isInstalled -and (Test-Path -LiteralPath (Join-Path $controlDir ".git"))

if ($isInstalled) {
    # --- Update ---
    Write-Host ""
    Write-Host "agentbox bereits installiert — pruefe Update..." -ForegroundColor Yellow

    # Versionsvergleich
    $localVersion = ""
    $localVersionFile = Join-Path $controlDir ".version"
    if (Test-Path -LiteralPath $localVersionFile) {
        $localVersion = (Get-Content -LiteralPath $localVersionFile -Raw -ErrorAction SilentlyContinue).Trim()
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
            # WICHTIG: ueberall -LiteralPath statt -Path, weil $env:TEMP bei
            # Usern mit Umlaut im Namen (z.B. "Schueler" → 8.3 "SCHLER~1")
            # einen Tilde im Pfad enthaelt, und PS 5.1 Remove-Item das im
            # -Path-Modus mit Wildcard-Glob-Resolution interpretiert. Resultat:
            # "Ein Objekt im angegebenen Pfad ist nicht vorhanden" trotz
            # existierender Datei. -LiteralPath umgeht jede Pattern-Interpretation.
            Write-Host "Lade neueste Version als ZIP..." -ForegroundColor Cyan
            $tempZip = Join-Path $env:TEMP "agentbox_update_$(Get-Random).zip"
            $tempExtract = Join-Path $env:TEMP "agentbox_extract_$(Get-Random)"
            try {
                $ProgressPreference = 'SilentlyContinue'
                Invoke-WebRequest -Uri $zipUrl -OutFile $tempZip -UseBasicParsing
                Expand-Archive -LiteralPath $tempZip -DestinationPath $tempExtract -Force

                # ZIP enthaelt agentbox-main/ Unterordner
                $extractedDir = Get-ChildItem -LiteralPath $tempExtract -Directory | Select-Object -First 1

                # Bestehende config.json sichern (User-Anpassungen)
                $userConfig = $null
                $existingConfigPath = Join-Path $controlDir "config.json"
                if (Test-Path -LiteralPath $existingConfigPath) {
                    $userConfig = Get-Content -LiteralPath $existingConfigPath -Raw -ErrorAction SilentlyContinue
                }

                # Dateien aktualisieren (nicht _control loeschen — cache/ und sandbox/ bleiben)
                Get-ChildItem -LiteralPath $extractedDir.FullName -Exclude "sandbox","cache" | ForEach-Object {
                    $destPath = Join-Path $controlDir $_.Name
                    if ($_.PSIsContainer) {
                        Copy-Item -LiteralPath $_.FullName -Destination $destPath -Recurse -Force
                    } else {
                        Copy-Item -LiteralPath $_.FullName -Destination $destPath -Force
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
                if ($tempZip -and (Test-Path -LiteralPath $tempZip)) {
                    Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
                }
                if ($tempExtract -and (Test-Path -LiteralPath $tempExtract)) {
                    Remove-Item -LiteralPath $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
                }
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

            Copy-Item -LiteralPath $tempClone -Destination $controlDir -Recurse -Force
            Write-Host "[OK] agentbox installiert nach: $controlDir" -ForegroundColor Green
        } catch {
            Write-Host "WARNUNG: git clone fehlgeschlagen, versuche ZIP-Fallback..." -ForegroundColor Yellow
            $hasGit = $false
        } finally {
            if ($tempClone -and (Test-Path -LiteralPath $tempClone)) {
                Remove-Item -LiteralPath $tempClone -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if (-not $hasGit -or -not (Test-Path -LiteralPath $controlDir)) {
        Write-Host "Lade agentbox als ZIP herunter..." -ForegroundColor Cyan
        $tempZip = Join-Path $env:TEMP "agentbox_install_$(Get-Random).zip"
        $tempExtract = Join-Path $env:TEMP "agentbox_extract_$(Get-Random)"

        try {
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $zipUrl -OutFile $tempZip -UseBasicParsing
            Expand-Archive -LiteralPath $tempZip -DestinationPath $tempExtract -Force

            $extractedDir = Get-ChildItem -LiteralPath $tempExtract -Directory | Select-Object -First 1
            Copy-Item -LiteralPath $extractedDir.FullName -Destination $controlDir -Recurse -Force
            Write-Host "[OK] agentbox installiert nach: $controlDir" -ForegroundColor Green
        } catch {
            Write-Host "FEHLER: Download fehlgeschlagen." -ForegroundColor Red
            Write-Host $_.Exception.Message -ForegroundColor Red
            exit 1
        } finally {
            if ($tempZip -and (Test-Path -LiteralPath $tempZip)) {
                Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
            }
            if ($tempExtract -and (Test-Path -LiteralPath $tempExtract)) {
                Remove-Item -LiteralPath $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# --- win-setup.ps1 ausfuehren ---
$setupScript = Join-Path $controlDir "win-setup.ps1"
if (-not (Test-Path -LiteralPath $setupScript)) {
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

# --- Host-Distro IMMER sicherstellen ---
# agentbox selbst laeuft ephemer (jede Session = eigene Sandbox-Distro, die
# hinterher verworfen wird). Fuer die `.bashrc`-Integration und den Desktop-
# Shortcut brauchen wir aber eine *persistente* Distro namens `agentbox-host`,
# die wir explizit per `-d agentbox-host` ansprechen.
#
# Frueher war der Code: nur erstellen, wenn KEINE Distros vorhanden. Das war
# falsch fuer User mit `docker-desktop` (oder anderen vorhandenen Distros) —
# der Code uebersprang die Host-Distro-Erstellung, und alle nachfolgenden
# `wsl bash -c ...`-Aufrufe (.bashrc-Write etc.) liefen gegen die zufaellige
# Default-Distro (z.B. `docker-desktop`, die als root laeuft und keine
# `.bashrc` hat). Symptom: 'grep: /root/.bashrc: No such file or directory'.
#
# Jetzt: agentbox-host wird IMMER importiert, idempotent. Wenn schon vorhanden,
# ueberspringen. Spaetere wsl.exe-Calls in der .bashrc-Phase nutzen explizit
# `-d agentbox-host`, statt sich auf die Default-Distro zu verlassen.
if ($setupOk) {
    $installedDistros = Get-WslRegisteredDistros
    if ("agentbox-host" -in $installedDistros) {
        Write-Host ""
        Write-Host "[OK] agentbox-host bereits registriert" -ForegroundColor Green
        if ($installedDistros.Count -gt 1) {
            $others = $installedDistros | Where-Object { $_ -ne "agentbox-host" }
            Write-Host "     Weitere Distros: $($others -join ', ')" -ForegroundColor Gray
        }
    } else {
        Write-Host ""
        if ($installedDistros.Count -eq 0) {
            Write-Host "Richte agentbox-host ein (keine bestehenden Distros)..." -ForegroundColor Yellow
        } else {
            Write-Host "Richte agentbox-host ein (neben: $($installedDistros -join ', '))..." -ForegroundColor Yellow
        }
        # Template liegt seit der LOCALAPPDATA-Migration unter
        # $env:LOCALAPPDATA\agentbox\sandbox\, nicht mehr unter $controlDir\sandbox\.
        $hostTemplate = Join-Path $env:LOCALAPPDATA "agentbox\sandbox\template.tar.gz"
        if (-not (Import-AgentboxHostDistro -TemplatePath $hostTemplate)) {
            $setupOk = $false
        }
    }
}

# --- Frueh-Abbruch bei fehlgeschlagenem Setup ---
# Wenn entweder win-setup.ps1 oder der Host-Distro-Rescue gefailt sind,
# darf die .bashrc-Integration NICHT laufen. Frueher lief sie trotzdem
# durch und produzierte Folgefehler wie 'grep: /root/.bashrc: No such
# file or directory' gegen eine zufaellige Default-Distro (z.B.
# docker-desktop), oder schlimmer: meldete still "[OK] .bashrc-Eintrag
# gesetzt", obwohl wsl.exe den Write nie ausgefuehrt hat.
if (-not $setupOk) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
    Write-Host " agentbox Installation UNVOLLSTAENDIG   " -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "Template-Build fehlgeschlagen — keine weiteren Integrationsschritte." -ForegroundColor Yellow
    Write-Host "Weder .bashrc-Eintrag noch .wslconfig noch Desktop-Shortcut wurden angelegt," -ForegroundColor Yellow
    Write-Host "weil ohne funktionierendes Template alles auf eine zufaellige Fremd-Distro" -ForegroundColor Yellow
    Write-Host "gelandet waere. Bitte die Fehlermeldung oben pruefen und install.ps1 erneut" -ForegroundColor Yellow
    Write-Host "ausfuehren. Falls ein Reboot verlangt wurde: zuerst neu starten." -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

# --- WSL .bashrc-Eintrag setzen ---
Write-Host ""
Write-Host "Konfiguriere WSL-Integration..." -ForegroundColor Cyan

# Die gesamte .bashrc-Phase ruft `wsl -d agentbox-host bash -c ...` mehrfach
# auf (grep, cp, python, base64-Append). Jeder dieser Calls KANN unter
# PS 5.1 + $ErrorActionPreference='Stop' an stderr-Output crashen — z.B. wenn
# bash eine Warning ausgibt oder grep auf ein nicht-existierendes File trifft.
# Statt 7 einzelne Invoke-Native-Wrapper schalten wir die ganze Phase auf
# 'Continue' um. Am Ende der Phase wird der vorherige Wert wiederhergestellt.
$prevErrBashrcPhase = $ErrorActionPreference
$ErrorActionPreference = "Continue"

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
& wsl.exe -d agentbox-host bash -c "grep -qE '$patternList' $bashrcPath" 2>$null
$conflictFound = ($LASTEXITCODE -eq 0)
$conflictLine = ""
if ($conflictFound) {
    $conflictLine = & wsl.exe -d agentbox-host bash -c "grep -m1 -E '$patternList' $bashrcPath" 2>$null
    $conflictLine = "$conflictLine".Trim()
}
if ($conflictFound) {
    Write-Host "[WARN] Fremder AI-Tool-Starter in ~/.bashrc erkannt:" -ForegroundColor Yellow
    if ($conflictLine) { Write-Host "       $conflictLine" -ForegroundColor Gray }
    Write-Host "[INFO] Entferne Konflikt-Block aus ~/.bashrc (Backup: ~/.bashrc.agentbox-backup)" -ForegroundColor Cyan
    # Backup anlegen und Python-Blockentfernung durchfuehren (robuster als sed)
    & wsl.exe -d agentbox-host bash -c "cp $bashrcPath ~/.bashrc.agentbox-backup" 2>&1 | Out-Null
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
    & wsl.exe -d agentbox-host bash -c $runCleanup 2>&1 | ForEach-Object { "$_" } | Out-Host
}

# --- Migration: alter agentbox-Block ohne AGENTBOX_AUTO_PROMPTED-Guard ---
# Bestandsinstalls aus 1.0.x haben einen .bashrc-Block ohne den neuen Auto-
# Prompt-Guard. Symptom: nach "n" beim 5s-Timer erscheint der Prompt sofort
# wieder, weil die Shell die .bashrc doppelt sourced. Hier detektieren wir
# den alten Block und entfernen ihn — der naechste Schritt schreibt dann den
# frischen Block mit Guard.
$migrateScript = @'
import os, sys, shutil
p = os.path.expanduser('~/.bashrc')
if not os.path.exists(p):
    sys.exit(0)
with open(p) as f: lines = f.readlines()
marker = '# agentbox'
guard = 'AGENTBOX_AUTO_PROMPTED'
start = None
for i, l in enumerate(lines):
    if marker in l:
        start = i
        break
if start is None:
    sys.exit(0)
# Block-Ende: erste alleinstehende `fi` nach start
end = None
for i in range(start, len(lines)):
    if lines[i].rstrip() == 'fi':
        end = i
        break
if end is None:
    sys.exit(0)
block = ''.join(lines[start:end+1])
if guard in block:
    # Schon migriert
    sys.exit(0)
shutil.copy(p, p + '.agentbox-pre-migrate')
del lines[start:end+1]
# Fuehrende Leerzeile vor dem entfernten Block auch loeschen
if start > 0 and start - 1 < len(lines) and lines[start-1].strip() == '':
    del lines[start-1]
with open(p, 'w') as f: f.writelines(lines)
print('[migrate] Alter agentbox-Block entfernt (Backup: ~/.bashrc.agentbox-pre-migrate)')
'@
$migrateScript = $migrateScript -replace "`r", ""
$migrateB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($migrateScript))
$runMigrate = "echo $migrateB64 | base64 -d > /tmp/agentbox_bashrc_migrate.py && python3 /tmp/agentbox_bashrc_migrate.py; rc=`$?; rm -f /tmp/agentbox_bashrc_migrate.py; exit `$rc"
& wsl.exe -d agentbox-host bash -c $runMigrate 2>&1 | ForEach-Object { "$_" } | Out-Host

# Exit-Code-basierte Pruefung: grep -q ist zuverlaessiger als Output-Capture,
# und faengt den Fall ab, dass wsl.exe selbst scheitert (keine Distros).
& wsl.exe -d agentbox-host bash -c "grep -qF '$bashrcMarker' ~/.bashrc" 2>$null
$alreadyPresent = ($LASTEXITCODE -eq 0)

if (-not $alreadyPresent) {
    $wslBasePath = ConvertTo-WslPath $baseDir

    $bashrcBlock = @"

$bashrcMarker
export AI_PROJECTS_ROOT="$wslBasePath"
if [ -f "`$AI_PROJECTS_ROOT/_control/wsl-ai-start.sh" ]; then
    alias agentbox='bash "`$AI_PROJECTS_ROOT/_control/wsl-ai-start.sh"'
    # Auto-Start: fragt 5s ob agentbox starten soll, Enter/Timeout = Ja, n = normales Terminal.
    # Zwei Guards verhindern, dass der Prompt doppelt erscheint:
    #   1. case-Match auf interaktive Shells, damit non-interactive Source-Aufrufe
    #      (z.B. aus Hilfs-Scripts) nicht ins Leere prompten.
    #   2. AGENTBOX_AUTO_PROMPTED-Env-Var: einmal gesetzt, bleibt sie in der
    #      Login-Shell und allen Sub-Shells. Wenn .bashrc doppelt gesourced wird
    #      (bash -li sourced .profile, das wiederum .bashrc, und danach noch
    #      interactive-init nochmal .bashrc) erscheint der Prompt trotzdem nur
    #      einmal pro Login-Shell. Nach n-Ablehnen kein erneuter Timer.
    case "`$-" in
        *i*)
            if [ -z "`$AGENTBOX_AUTO_PROMPTED" ]; then
                export AGENTBOX_AUTO_PROMPTED=1
                bash "`$AI_PROJECTS_ROOT/_control/wsl-ai-start.sh" --auto
            fi
            ;;
    esac
fi
"@

    # Block per base64 direkt an wsl.exe pipen — KEINE Temp-Datei auf /mnt/c.
    # Grund: WSL2 hat einen bekannten 9P-Sync-Bug, bei dem gerade mit Out-File
    # geschriebene Dateien von Linux-Seite aus ein paar Millisekunden unsichtbar
    # sind → "cat: /mnt/c/.../xxx.tmp: No such file or directory". base64 + stdin
    # umgeht das Windows-Filesystem komplett.
    $bashrcBlock = $bashrcBlock -replace "`r", ""
    $bashrcB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($bashrcBlock))
    & wsl.exe -d agentbox-host bash -c "echo $bashrcB64 | base64 -d >> ~/.bashrc" 2>&1 | ForEach-Object { "$_" } | Out-Null
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

# Ende der .bashrc-Phase — ErrorActionPreference wiederherstellen.
$ErrorActionPreference = $prevErrBashrcPhase

# --- WSL Ressourcen-Limits (.wslconfig) ---
Write-Host ""
Write-Host "Pruefe WSL Ressourcen-Limits..." -ForegroundColor Cyan

# Werte aus config.json lesen (nach Clone verfuegbar)
$installConfig = $null
$installConfigPath = Join-Path $controlDir "config.json"
try {
    if (Test-Path -LiteralPath $installConfigPath) {
        $installConfig = Get-Content -LiteralPath $installConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json
    }
} catch { }

$resMem  = if ($installConfig -and $installConfig.resources_memory)     { $installConfig.resources_memory }     else { "4GB" }
$resCpu  = if ($installConfig -and $installConfig.resources_processors) { $installConfig.resources_processors } else { 2 }
$resSwap = if ($installConfig -and $installConfig.resources_swap)       { $installConfig.resources_swap }       else { "1GB" }

$wslConfigPath = Join-Path $env:USERPROFILE ".wslconfig"
$wslConfigMarker = "# agentbox"

if (-not (Test-Path -LiteralPath $wslConfigPath)) {
    # .wslconfig existiert nicht — mit Werten aus config.json erstellen
    $wslConfigContent = @"
$wslConfigMarker — Ressourcen-Limits fuer Sandbox-Distros
[wsl2]
memory=$resMem
processors=$resCpu
swap=$resSwap
"@
    $wslConfigContent | Out-File -LiteralPath $wslConfigPath -Encoding ascii -NoNewline
    Write-Host "[OK] .wslconfig erstellt ($resMem RAM, $resCpu CPUs, $resSwap Swap)" -ForegroundColor Green
    Write-Host "     Anpassbar unter: $wslConfigPath oder in config.json" -ForegroundColor Gray
} else {
    # .wslconfig existiert — pruefen ob bereits konfiguriert
    $existingConfig = Get-Content -LiteralPath $wslConfigPath -Raw -ErrorAction SilentlyContinue
    if ($existingConfig -match [regex]::Escape($wslConfigMarker)) {
        Write-Host "[OK] .wslconfig bereits durch agentbox konfiguriert" -ForegroundColor Green
    } else {
        Write-Host "[INFO] .wslconfig existiert bereits mit eigenen Einstellungen." -ForegroundColor Yellow
        Write-Host "       Empfehlung: memory=4GB und processors=2 setzen," -ForegroundColor Yellow
        Write-Host "       damit ein Agent den Host nicht lahmlegen kann." -ForegroundColor Yellow
        Write-Host "       Datei: $wslConfigPath" -ForegroundColor Gray
    }
}

# --- Desktop-Shortcuts erstellen ---
# Hier sind wir nur, wenn $setupOk = $true (frueher Abbruch oben).
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
    # `-d agentbox-host` ist hier KRITISCH: ohne explizite Distro greift wsl.exe
    # die Default-Distro, und wenn der User docker-desktop hat, landet der Klick
    # in der docker-VM und nicht in der agentbox-Distro. Mit -d zeigt der
    # Shortcut immer in unsere eigene Distro.
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = "wsl.exe"
    $shortcut.Arguments = "-d agentbox-host -e bash -li -c agentbox"
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

# --- Erfolgsmeldung ---
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host " agentbox erfolgreich installiert!      " -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Starten:" -ForegroundColor Cyan
Write-Host "  - Doppelklick auf 'agentbox' am Desktop  (empfohlen)" -ForegroundColor White
Write-Host "  - Oder Konsole: wsl -d agentbox-host" -ForegroundColor White
Write-Host ""

# --- Direkt starten? ---
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
    # Invoke-Native, weil agentbox / wsl-ai-start.sh stderr schreiben kann
    # (Logs, Warnungen, Trap-Output) — sonst wuerde der Installer am Ende mit
    # NativeCommandError raus statt mit einem sauberen Exit.
    Invoke-Native { & wsl.exe -d agentbox-host -e bash -li -c "agentbox" }
} else {
    Write-Host "OK — manuell starten via Desktop-Shortcut oder 'wsl -d agentbox-host' + 'agentbox'." -ForegroundColor Gray
}
