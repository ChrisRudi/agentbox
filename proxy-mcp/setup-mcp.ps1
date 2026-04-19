# setup-mcp.ps1
# agentbox -- Generischer MCP-Einbind-Wizard.
#
# Nimmt einen Ordner mit einem MCP-Server (Python oder Node) und bindet
# ihn in die agentbox-Konfiguration ein. Alles was ermittelt werden
# kann, wird ermittelt -- der User wird nur nach dem Ordner gefragt
# und nach Secrets (Tokens/API-Keys), die nirgends stehen koennen.
#
# Spezialfall KiCad: wenn der Wizard erkennt, dass es sich um einen
# KiCad-bezogenen MCP-Server handelt (Ordnername, pcbnew-Import in
# Source, KiCad-Referenzen im README), optimiert er automatisch im
# Hintergrund: nutzt KiCad's mitgeliefertes Python (statt System-
# Python, weil System-Python kein pcbnew hat) und setzt
# KICAD_CLI_PATH per Default. Keine Prompts dafuer.
#
# Aufruf:
#   irm https://raw.githubusercontent.com/ChrisRudi/agentbox/main/setup-mcp.ps1 | iex
#   # oder:
#   .\setup-mcp.ps1 -McpPath "C:\Pfad\zum\MCP"
#   # oder vollautomatisch:
#   .\setup-mcp.ps1 -McpPath "..." -McpId "mein-mcp" -NonInteractive

[CmdletBinding()]
param(
    [string]$McpPath = "",
    [string]$McpId = "",
    [string]$AgentboxControlDir = "",
    [hashtable]$ExtraEnv = @{},
    [switch]$SkipDepsInstall,
    [switch]$NonInteractive
)

$ErrorActionPreference = "Stop"

# --- Farb-Helper ---
function Write-Step { param($msg) Write-Host ""; Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok   { param($msg) Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Warn { param($msg) Write-Host "    [WARN] $msg" -ForegroundColor Yellow }
function Write-Err  { param($msg) Write-Host "    [FEHLER] $msg" -ForegroundColor Red }
function Write-Info { param($msg) Write-Host "    $msg" -ForegroundColor Gray }

function Read-Input {
    param([string]$Prompt, [string]$Default = "", [switch]$MustExist, [switch]$Secret)
    if ($NonInteractive) {
        if (-not $Default) { throw "NonInteractive: '$Prompt' ist Pflicht." }
        return $Default
    }
    while ($true) {
        $hint = if ($Default) { " [$Default]" } else { "" }
        if ($Secret) {
            $ss = Read-Host "$Prompt$hint" -AsSecureString
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
            $in = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        } else {
            $in = Read-Host "$Prompt$hint"
        }
        if ([string]::IsNullOrWhiteSpace($in) -and $Default) { $in = $Default }
        if ([string]::IsNullOrWhiteSpace($in)) {
            Write-Warn "Leere Eingabe."
            continue
        }
        if ($MustExist -and -not (Test-Path -LiteralPath $in)) {
            Write-Warn "Pfad existiert nicht: $in"
            continue
        }
        return $in
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " agentbox: MCP-Server einbinden" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# --- 1. MCP-Ordner ermitteln ---
Write-Step "1/6 MCP-Ordner finden"

if (-not $McpPath) {
    $here = (Get-Location).Path
    # Wenn der aktuelle Ordner schon ein MCP-Server ist, direkt nutzen.
    if ((Test-Path (Join-Path $here "pyproject.toml")) -or
        (Test-Path (Join-Path $here "package.json")) -or
        (Test-Path (Join-Path $here "main.py"))) {
        $McpPath = $here
        Write-Info "Aktuelles Verzeichnis erkannt als MCP-Ordner: $McpPath"
    }
}
if (-not $McpPath) {
    $McpPath = Read-Input -Prompt "Pfad zum MCP-Server-Ordner" -MustExist
}
$McpPath = (Resolve-Path -LiteralPath $McpPath).Path
Write-Ok "MCP-Ordner: $McpPath"

# --- 2. Typ erkennen ---
Write-Step "2/6 MCP-Typ erkennen"

function Test-HasFile { param($Dir, $Name) Test-Path -LiteralPath (Join-Path $Dir $Name) }

$isPython = (Test-HasFile $McpPath "pyproject.toml") -or (Test-HasFile $McpPath "setup.py") -or (Test-HasFile $McpPath "requirements.txt")
$isNode   = Test-HasFile $McpPath "package.json"

# Wenn beides moeglich: Python gewinnt wenn main.py/server.py vorhanden,
# sonst Node. Edge-Case, kaum relevant.
if ($isPython -and $isNode) {
    if ((Test-HasFile $McpPath "main.py") -or (Test-HasFile $McpPath "server.py")) {
        $isNode = $false
    } else {
        $isPython = $false
    }
}

# Fallback: Nur main.py vorhanden, keine pyproject.toml -> Python
if (-not $isPython -and -not $isNode) {
    if ((Test-HasFile $McpPath "main.py") -or (Test-HasFile $McpPath "server.py") -or (Test-HasFile $McpPath "__main__.py")) {
        $isPython = $true
    }
}

if ($isPython) {
    $mcpType = "python"
    Write-Ok "Python-MCP erkannt"
} elseif ($isNode) {
    $mcpType = "node"
    Write-Ok "Node-MCP erkannt"
} else {
    Write-Err "Konnte MCP-Typ nicht erkennen (keine pyproject.toml / package.json / main.py im Ordner)."
    exit 1
}

# --- KiCad-Spezial-Erkennung (silent) ---
function Test-IsKicadMcp {
    param([string]$Path)

    $leaf = (Split-Path -Leaf $Path).ToLowerInvariant()
    if ($leaf -match 'kicad') { return $true }

    $markers = @()
    foreach ($f in @("pyproject.toml", "README.md", "README.rst", "package.json")) {
        $fp = Join-Path $Path $f
        if (Test-Path -LiteralPath $fp) {
            $c = Get-Content -LiteralPath $fp -Raw -ErrorAction SilentlyContinue
            if ($c -and ($c -match 'pcbnew|kicad-cli|KiCad|kicad_mcp')) {
                $markers += $f
            }
        }
    }
    return ($markers.Count -gt 0)
}

$isKicad = Test-IsKicadMcp -Path $McpPath
if ($isKicad) {
    Write-Info "(KiCad-Bezug erkannt -- optimiere automatisch im Hintergrund.)"
}

# --- 3. MCP-ID ableiten ---
if (-not $McpId) {
    # Prefer pyproject.toml oder package.json name
    if ($mcpType -eq "python") {
        $py = Join-Path $McpPath "pyproject.toml"
        if (Test-Path -LiteralPath $py) {
            $content = Get-Content -LiteralPath $py -Raw
            if ($content -match '(?ms)\[project\][^\[]*?\bname\s*=\s*"([^"]+)"') {
                $McpId = $Matches[1].Trim()
            }
        }
    } elseif ($mcpType -eq "node") {
        $pkg = Join-Path $McpPath "package.json"
        if (Test-Path -LiteralPath $pkg) {
            try {
                $pkgJson = Get-Content -LiteralPath $pkg -Raw | ConvertFrom-Json
                if ($pkgJson.name) { $McpId = [string]$pkgJson.name }
            } catch { }
        }
    }
    if (-not $McpId) {
        $McpId = Split-Path -Leaf $McpPath
    }
    # Normalisieren: nur lowercase + dash
    $McpId = $McpId.ToLowerInvariant() -replace '[^a-z0-9_-]', '-' -replace '-+', '-'
    $McpId = $McpId.Trim('-')
    if ([string]::IsNullOrWhiteSpace($McpId)) { $McpId = "mcp" }
    # KiCad-Spezial: schoener Default-ID
    if ($isKicad -and $McpId -notmatch 'kicad') { $McpId = "kicad" }
    if ($isKicad -and $McpId -match '^kicad[-_]mcp$') { $McpId = "kicad" }
}
Write-Ok "MCP-ID: $McpId"

# --- 4. Command + Args + Env + cwd ermitteln ---
Write-Step "3/6 Startbefehl ermitteln"

$command = $null
$cmdArgs = @()
$envMap = @{}
$cwd = $McpPath

if ($mcpType -eq "python") {
    # Python-Pfad: KiCad-Python bevorzugen wenn relevant, sonst System-Python.
    $pythonPath = $null
    if ($isKicad) {
        $kicadPyCands = @(
            "C:\Program Files\KiCad\10.0\bin\python.exe",
            "C:\Program Files (x86)\KiCad\10.0\bin\python.exe",
            "C:\Program Files\KiCad\9.0\bin\python.exe",
            "C:\Program Files (x86)\KiCad\9.0\bin\python.exe"
        )
        foreach ($c in $kicadPyCands) {
            if (Test-Path -LiteralPath $c) { $pythonPath = $c; break }
        }
        if ($pythonPath) {
            Write-Info "Nutze KiCad-Python (wegen pcbnew-Modul): $pythonPath"
        } else {
            Write-Warn "KiCad-Python nicht gefunden -- nutze System-Python (Tools mit pcbnew-Abhaengigkeit werden evtl. fehlschlagen)."
        }
    }
    if (-not $pythonPath) {
        $cmd = Get-Command python.exe -ErrorAction SilentlyContinue
        if ($cmd) { $pythonPath = $cmd.Source }
    }
    if (-not $pythonPath) {
        $pythonPath = Read-Input -Prompt "Pfad zu python.exe (3.10+)" -MustExist
    }
    $command = $pythonPath

    # Entry-Point:
    #  (1) pyproject.toml [project.scripts] Eintrag finden -> python -m <pkg> oder
    #      direkt ueber den installierten script-eintrag ausfuehren
    #  (2) main.py im Root
    #  (3) server.py im Root
    #  (4) __main__.py in package_dir
    $entryFound = $false
    $pyproject = Join-Path $McpPath "pyproject.toml"
    if ((-not $entryFound) -and (Test-Path -LiteralPath $pyproject)) {
        $pj = Get-Content -LiteralPath $pyproject -Raw
        if ($pj -match '(?ms)\[project\.scripts\]\s*([^\[]+)') {
            $scriptsBlock = $Matches[1]
            if ($scriptsBlock -match '\s*([a-zA-Z0-9_-]+)\s*=\s*"([^"]+)"') {
                $scriptName = $Matches[1]
                $scriptTarget = $Matches[2]
                # Format: "package.module:function" -> nutze python -m package.module
                if ($scriptTarget -match '^([^:]+):') {
                    $moduleName = $Matches[1]
                    $cmdArgs = @("-m", $moduleName)
                    $entryFound = $true
                }
            }
        }
        # Fallback: [project] name -> python -m <package>
        if (-not $entryFound -and ($pj -match '(?ms)\[project\][^\[]*?\bname\s*=\s*"([^"]+)"')) {
            $pkgName = $Matches[1].Trim().Replace('-', '_')
            # Pruefen ob der Package-Folder existiert
            if (Test-Path -LiteralPath (Join-Path $McpPath $pkgName)) {
                $cmdArgs = @("-m", $pkgName)
                $entryFound = $true
            }
        }
    }
    if (-not $entryFound -and (Test-HasFile $McpPath "main.py")) {
        $cmdArgs = @("main.py")
        $entryFound = $true
    }
    if (-not $entryFound -and (Test-HasFile $McpPath "server.py")) {
        $cmdArgs = @("server.py")
        $entryFound = $true
    }
    if (-not $entryFound -and (Test-HasFile $McpPath "__main__.py")) {
        $cmdArgs = @("__main__.py")
        $entryFound = $true
    }
    if (-not $entryFound) {
        Write-Err "Python-MCP: kein Entry-Point gefunden (weder pyproject.toml scripts noch main.py/server.py/__main__.py)."
        exit 1
    }

    Write-Ok "Startbefehl: python $($cmdArgs -join ' ')"

    # Dependencies installieren
    if (-not $SkipDepsInstall) {
        Write-Info "Installiere Python-Dependencies..."
        Push-Location $McpPath
        try {
            $pipTarget = "."
            # [dev] extras wenn vorhanden
            if (Test-Path -LiteralPath $pyproject) {
                $pj = Get-Content -LiteralPath $pyproject -Raw
                if ($pj -match '(?ms)\[project\.optional-dependencies\][^\[]*?\bdev\s*=') {
                    $pipTarget = ".[dev]"
                }
            }
            $pipArg = "install", "-e", $pipTarget
            & $command -m pip @pipArg 2>&1 | ForEach-Object {
                if ($_ -match '^(ERROR|error:)') { Write-Host "      $_" -ForegroundColor Red }
                else { Write-Host "      $_" -ForegroundColor DarkGray }
            }
            $rc = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        if ($rc -ne 0) {
            Write-Err "pip install fehlgeschlagen (rc=$rc)."
            exit 1
        }
        Write-Ok "Dependencies installiert."
    }

} elseif ($mcpType -eq "node") {
    $nodeCmd = Get-Command node.exe -ErrorAction SilentlyContinue
    if (-not $nodeCmd) {
        Write-Err "node.exe nicht gefunden. Node.js installieren oder -NonInteractive ueberspringen."
        exit 1
    }

    # Entry aus package.json
    $pkg = Join-Path $McpPath "package.json"
    $pkgJson = Get-Content -LiteralPath $pkg -Raw | ConvertFrom-Json

    $entryFound = $false
    # (1) bin-Eintrag
    if ($pkgJson.PSObject.Properties['bin']) {
        if ($pkgJson.bin -is [string]) {
            $command = $nodeCmd.Source
            $cmdArgs = @($pkgJson.bin)
            $entryFound = $true
        } elseif ($pkgJson.bin -is [PSCustomObject]) {
            # Nimm den ersten bin-Eintrag
            $firstBin = $pkgJson.bin.PSObject.Properties | Select-Object -First 1
            if ($firstBin) {
                $command = $nodeCmd.Source
                $cmdArgs = @([string]$firstBin.Value)
                $entryFound = $true
            }
        }
    }
    # (2) main-Eintrag
    if (-not $entryFound -and $pkgJson.PSObject.Properties['main']) {
        $command = $nodeCmd.Source
        $cmdArgs = @([string]$pkgJson.main)
        $entryFound = $true
    }
    # (3) index.js
    if (-not $entryFound -and (Test-HasFile $McpPath "index.js")) {
        $command = $nodeCmd.Source
        $cmdArgs = @("index.js")
        $entryFound = $true
    }
    # (4) Fallback: npm start -- aber npm.cmd starten, nicht node
    if (-not $entryFound) {
        $npmCmd = Get-Command npm.cmd -ErrorAction SilentlyContinue
        if ($npmCmd -and $pkgJson.PSObject.Properties['scripts'] -and $pkgJson.scripts.PSObject.Properties['start']) {
            $command = $npmCmd.Source
            $cmdArgs = @("start")
            $entryFound = $true
        }
    }
    if (-not $entryFound) {
        Write-Err "Node-MCP: kein Entry-Point gefunden (bin/main in package.json, index.js, oder npm start)."
        exit 1
    }
    Write-Ok "Startbefehl: $(Split-Path -Leaf $command) $($cmdArgs -join ' ')"

    # Dependencies installieren
    if (-not $SkipDepsInstall) {
        Write-Info "Installiere Node-Dependencies..."
        Push-Location $McpPath
        try {
            $npmCmd = Get-Command npm.cmd -ErrorAction SilentlyContinue
            if ($npmCmd) {
                & $npmCmd.Source install 2>&1 | ForEach-Object {
                    Write-Host "      $_" -ForegroundColor DarkGray
                }
                $rc = $LASTEXITCODE
            } else {
                Write-Warn "npm nicht gefunden -- ueberspringe Install."
                $rc = 0
            }
        } finally {
            Pop-Location
        }
        if ($rc -ne 0) {
            Write-Err "npm install fehlgeschlagen (rc=$rc)."
            exit 1
        }
        Write-Ok "Dependencies installiert."
    }
}

# --- 5. Env-Vars ermitteln ---
Write-Step "4/6 Umgebungsvariablen ermitteln"

# (a) .env.example
$envExample = Join-Path $McpPath ".env.example"
if (Test-Path -LiteralPath $envExample) {
    Get-Content -LiteralPath $envExample -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_ -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*$') {
            $key = $Matches[1]
            $val = $Matches[2]
            # Quotes entfernen
            $val = $val -replace '^"(.*)"$', '$1' -replace "^'(.*)'$", '$1'
            if (-not $envMap.ContainsKey($key)) {
                $envMap[$key] = $val
            }
        }
    }
    Write-Info ".env.example gelesen ($($envMap.Count) Eintraege)."
}

# (b) KiCad-Spezial-Defaults
if ($isKicad) {
    $kicadCliCands = @(
        "C:\Program Files\KiCad\10.0\bin\kicad-cli.exe",
        "C:\Program Files (x86)\KiCad\10.0\bin\kicad-cli.exe",
        "C:\Program Files\KiCad\9.0\bin\kicad-cli.exe",
        "C:\Program Files (x86)\KiCad\9.0\bin\kicad-cli.exe"
    )
    foreach ($c in $kicadCliCands) {
        if (Test-Path -LiteralPath $c) {
            if ([string]::IsNullOrEmpty($envMap['KICAD_CLI_PATH'])) {
                $envMap['KICAD_CLI_PATH'] = $c
                Write-Info "KICAD_CLI_PATH: $c"
            }
            break
        }
    }
    # KICAD_SEARCH_PATHS: wenn leer, auf AI_Projects_Source zeigen
    if ([string]::IsNullOrEmpty($envMap['KICAD_SEARCH_PATHS'])) {
        $searches = @()
        if ($env:OneDrive) {
            $candidate = Join-Path $env:OneDrive "AI_Projects_Source"
            if (Test-Path -LiteralPath $candidate) { $searches += $candidate }
        }
        $docsKicad = Join-Path $env:USERPROFILE "Documents\KiCad"
        if (Test-Path -LiteralPath $docsKicad) { $searches += $docsKicad }
        if ($searches.Count -gt 0) {
            $envMap['KICAD_SEARCH_PATHS'] = $searches -join ';'
            Write-Info "KICAD_SEARCH_PATHS: $($envMap['KICAD_SEARCH_PATHS'])"
        }
    }
}

# (c) ExtraEnv-Parameter (fuer Automation/CI)
foreach ($k in $ExtraEnv.Keys) {
    $envMap[$k] = [string]$ExtraEnv[$k]
}

# (d) Secrets-Prompt: Variablen mit leerem Wert, die nach Secret aussehen
$secretPatterns = @('TOKEN$', 'KEY$', 'SECRET$', 'PASSWORD$', 'PASS$', 'API_KEY$')
$secretsNeeded = @()
foreach ($k in @($envMap.Keys)) {
    $v = $envMap[$k]
    if ([string]::IsNullOrWhiteSpace($v) -or $v -match '^(your|xxx|changeme|<.*>|example)' -or $v -match '^\$\{') {
        foreach ($p in $secretPatterns) {
            if ($k -match $p) {
                $secretsNeeded += $k
                break
            }
        }
    }
}
if ($secretsNeeded.Count -gt 0) {
    Write-Info "Secrets fehlen -- bitte jetzt eintragen (leere Eingabe = ueberspringen, Eintrag muss manuell in config.json nachgetragen werden):"
    foreach ($k in $secretsNeeded) {
        if ($NonInteractive) { continue }
        $val = Read-Host "    $k"
        if ([string]::IsNullOrWhiteSpace($val)) {
            Write-Warn "    $k uebersprungen -- Tool wird ohne diesen Wert evtl. nicht laufen."
            $envMap.Remove($k) | Out-Null
        } else {
            $envMap[$k] = $val
        }
    }
}

# Leere Env-Werte (nicht Secrets) entfernen, damit config.json sauber bleibt
$cleanEnv = @{}
foreach ($k in $envMap.Keys) {
    if (-not [string]::IsNullOrWhiteSpace($envMap[$k])) {
        $cleanEnv[$k] = $envMap[$k]
    }
}
$envMap = $cleanEnv

Write-Ok "Env: $($envMap.Count) Variable(n)"

# --- 6. config.json aktualisieren ---
Write-Step "5/6 agentbox-Konfiguration aktualisieren"

if (-not $AgentboxControlDir) {
    $cands = @()
    if ($env:OneDrive) {
        $cands += Join-Path $env:OneDrive "AI_Projects_Source\_control"
        $cands += Join-Path $env:OneDrive "AI_Projects\_control"
    }
    $cands += "D:\AI_Projects_Source\_control"
    $cands += "$env:USERPROFILE\AI_Projects_Source\_control"
    foreach ($c in $cands) {
        if (Test-Path -LiteralPath (Join-Path $c "config.json")) { $AgentboxControlDir = $c; break }
    }
    if (-not $AgentboxControlDir) {
        $AgentboxControlDir = Read-Input -Prompt "Pfad zum agentbox _control-Ordner" -MustExist
    }
}
$configPath = Join-Path $AgentboxControlDir "config.json"
if (-not (Test-Path -LiteralPath $configPath)) {
    Write-Err "config.json fehlt: $configPath"
    exit 1
}
Write-Info "_control: $AgentboxControlDir"

$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json

if (-not $config.PSObject.Properties['mcp_servers']) {
    $config | Add-Member -NotePropertyName 'mcp_servers' -NotePropertyValue @()
}

$existing = @($config.mcp_servers | Where-Object { $_.id -ne $McpId })

$entry = [ordered]@{ id = $McpId; command = $command }
if ($cmdArgs.Count -gt 0) { $entry['args'] = $cmdArgs }
if ($cwd) { $entry['cwd'] = $cwd }
if ($envMap.Count -gt 0) {
    $envObj = [ordered]@{}
    foreach ($k in ($envMap.Keys | Sort-Object)) { $envObj[$k] = $envMap[$k] }
    $entry['env'] = $envObj
}
$newEntry = [PSCustomObject]$entry

$config.mcp_servers = @($existing) + @($newEntry)

# Backup + schreiben
$backupPath = "$configPath.backup.$(Get-Date -Format 'yyyyMMdd_HHmmss')"
Copy-Item -LiteralPath $configPath -Destination $backupPath
Write-Info "Backup: $backupPath"

$newJson = $config | ConvertTo-Json -Depth 20
$newJson = $newJson -replace "`r`n", "`n" -replace "`r", "`n"
if (-not $newJson.EndsWith("`n")) { $newJson += "`n" }
[System.IO.File]::WriteAllText($configPath, $newJson, (New-Object System.Text.UTF8Encoding $false))
Write-Ok "config.json geschrieben. $($existing.Count) andere MCP-Eintrag(e) erhalten, '$McpId' neu gesetzt."

# --- 7. Hintergrund-Prozess neu laden ---
Write-Step "6/6 MCP-Hintergrund-Prozess neu laden"

$taskName = "agentbox-mcp-dispatcher"
$taskExists = $false
try { $null = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop; $taskExists = $true } catch { }

if (-not $taskExists) {
    Write-Warn "MCP-Prozess-Manager ('$taskName') ist noch nicht registriert."
    Write-Info "Einmaliger Fix: install.ps1 als Admin rerunnen."
    if (-not $NonInteractive) {
        $yn = Read-Host "install.ps1 jetzt als Admin starten? [j/N]"
        if ($yn -match '^[jJyY]') {
            $installPs1 = Join-Path $AgentboxControlDir "install.ps1"
            if (Test-Path -LiteralPath $installPs1) {
                Start-Process -FilePath "powershell.exe" `
                    -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-File",$installPs1 `
                    -Verb RunAs -Wait
                Start-Sleep -Seconds 2
                try { $null = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop; $taskExists = $true } catch { }
            }
        }
    }
    if (-not $taskExists) {
        Write-Err "Setup unvollstaendig -- bitte install.ps1 als Admin ausfuehren und diesen Wizard rerunnen."
        exit 2
    }
}

try { Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue } catch { }
Start-Sleep -Seconds 1
try { Start-ScheduledTask -TaskName $taskName -ErrorAction Stop } catch {
    Write-Err "Start fehlgeschlagen: $($_.Exception.Message)"
    exit 1
}
Write-Ok "MCP-Prozess-Manager neu gestartet."

# --- 8. Status pruefen ---
Start-Sleep -Seconds 3

$runtimeBase = Join-Path $env:LOCALAPPDATA "agentbox\mcp-runtime"
$handlerLog = Join-Path $runtimeBase "$McpId\handler.log"
$heartbeatFile = Join-Path $runtimeBase "$McpId\daemon.heartbeat"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
if (Test-Path -LiteralPath $heartbeatFile) {
    $hbAge = ((Get-Date) - (Get-Item -LiteralPath $heartbeatFile).LastWriteTime).TotalSeconds
    if ($hbAge -lt 30) {
        Write-Host " [OK] '$McpId' laeuft (Heartbeat $([int]$hbAge)s alt)" -ForegroundColor Green
        Write-Host " Naechste agentbox-Session -> /mcp zeigt den neuen Server." -ForegroundColor Green
    } else {
        Write-Host " [WARN] Heartbeat alt ($([int]$hbAge)s) -- Handler haengt evtl." -ForegroundColor Yellow
        Write-Host " Log: $handlerLog" -ForegroundColor Yellow
    }
} else {
    Write-Host " [WARN] Kein Heartbeat -- Handler konnte nicht starten." -ForegroundColor Yellow
    if (Test-Path -LiteralPath $handlerLog) {
        Write-Host " Letzte Log-Zeilen:" -ForegroundColor Yellow
        Get-Content -LiteralPath $handlerLog -Tail 15 | ForEach-Object { Write-Host "   $_" -ForegroundColor DarkGray }
    }
    Write-Host "" -ForegroundColor Yellow
    Write-Host " Vollstaendiges Log: $handlerLog" -ForegroundColor Yellow
}
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
