# config.ps1 — agentbox gemeinsame PowerShell-Helper
# Einbinden: . (Join-Path $PSScriptRoot "lib\config.ps1")
#           bzw. . (Join-Path $controlDir "lib\config.ps1")
#
# Bewusst minimal. Drei Helper, deren inline-Implementierungen aktuell
# in install.ps1 / win-setup-core.ps1 / win-task-runner.ps1 parallel
# existieren (mit leichten Drifts). Siehe refactor.md Befund D+E.
#
# PS-5.1-Kompatibilitaet: keine Here-Strings, keine PS-6-Only-Parameter
# (insbesondere kein `New-Item -LiteralPath`), UTF8-ohne-BOM bei
# Datei-Writes via [System.Text.UTF8Encoding]::new($false). Tilde-/
# Umlaut-Pfade: wo moeglich -LiteralPath verwenden (erlaubt in
# Get-Content/Test-Path/Remove-Item in PS 5.1).
#
# Additiv gedacht: dieses File ersetzt noch KEINE Call-Site. Step 3B+
# schalten install.ps1 / win-setup-core.ps1 / win-task-runner.ps1
# nacheinander um, damit Installer-Regression-Risiko pro Step klein
# bleibt.

# --- Read-AgentboxConfig -------------------------------------------
# Liest config.json und gibt das geparste PSCustomObject zurueck. Bei
# fehlender Datei, I/O-Fehler oder kaputtem JSON: leise $null
# zurueckgeben und optional eine INFO-Zeile schreiben. Match zur
# existierenden Semantik in allen drei Scripts (Test-Path + try/catch).
function Read-AgentboxConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [switch]$Quiet
    )

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        if (-not $Quiet) {
            Write-Host "[INFO] config.json nicht gefunden: $ConfigPath — verwende Standardwerte." -ForegroundColor Gray
        }
        return $null
    }

    try {
        return Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        if (-not $Quiet) {
            Write-Host "[INFO] config.json nicht lesbar ($($_.Exception.Message)) — verwende Standardwerte." -ForegroundColor Gray
        }
        return $null
    }
}

# --- Invoke-Native -------------------------------------------------
# Fuehrt einen ScriptBlock mit Native-Calls (wsl.exe, git.exe, etc.)
# unter $ErrorActionPreference='Continue' aus und stellt den vorherigen
# Wert wieder her. Grund: unter PS 5.1 + $ErrorActionPreference='Stop'
# werfen stderr-Ausgaben nativer Tools als NativeCommandError ab — der
# Caller kommt nicht mehr an $LASTEXITCODE ran.
#
# Verbatim aus install.ps1 extrahiert, damit Verhalten byte-identisch
# bleibt. win-setup-core.ps1 und win-task-runner.ps1 bekommen die
# gleiche Routine wenn sie in Step 3C/3D sourcen.
function Invoke-Native {
    [CmdletBinding()]
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

# --- Write-AgentboxLog ---------------------------------------------
# Timestamped [LEVEL] — message, farbcodiert auf Write-Host. Kompatibel
# zur bestehenden Write-Log in win-task-runner.ps1:77-87 (gleiche Level-
# Namen, gleiche Farben, gleiches Ausgabeformat). Andere Funktionsname,
# damit Step 3D beim Sourcen nicht mit der dortigen lokalen Definition
# kollidiert — Migration erfolgt dort gezielt, nicht by Namens-Aliasing.
function Write-AgentboxLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet("INFO","OK","WARN","ERROR","DEBUG")][string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "ERROR"   { "Red" }
        "WARN"    { "Yellow" }
        "OK"      { "Green" }
        "DEBUG"   { "Gray" }
        default   { "White" }
    }
    Write-Host "[$timestamp] $Level — $Message" -ForegroundColor $color
}
