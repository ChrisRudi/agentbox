# setup-mcp.ps1
# agentbox -- Generischer MCP-Einbind-Wizard (2.5.0)
#
# Nimmt einen Ordner mit einem MCP-Server (Python oder Node.js) und
# traegt ihn in die agentbox-Konfiguration ein. Der Wizard erkennt
# automatisch:
#  - Typ (pyproject.toml/setup.py/requirements.txt -> Python;
#    package.json -> Node)
#  - Startbefehl ([project.scripts] / main.py / server.py; bin/main /
#    index.js)
#  - Dependencies werden installiert
#  - .env.example gelesen (Environment-Variablen)
#  - Secrets (TOKEN/KEY/SECRET) explizit abgefragt wenn Platzhalter
#  - KiCad-Bezug erkannt -> KiCad-eigenes Python wird genutzt, weil
#    System-Python kein pcbnew hat (silent, kein Prompt)
#
# User-Interaktion reduziert auf: Ordnerpfad + fehlende Secrets.
#
# Aufruf:
#   irm https://raw.githubusercontent.com/ChrisRudi/agentbox/main/proxy-mcp/setup-mcp.ps1 | iex
#   # oder lokal aus _control/proxy-mcp/:
#   .\setup-mcp.ps1 -McpPath "C:\Pfad\zum\MCP"

[CmdletBinding()]
param(
    [string]$McpPath = "",
    [string]$McpId = "",
    [int]$Port = 0,
    [string]$AgentboxControlDir = "",
    [hashtable]$ExtraEnv = @{},
    [switch]$SkipDepsInstall,
    [switch]$NonInteractive
)

$ErrorActionPreference = "Stop"

function Write-Step { param($msg) Write-Host ""; Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok   { param($msg) Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Warn { param($msg) Write-Host "    [WARN] $msg" -ForegroundColor Yellow }
function Write-Err  { param($msg) Write-Host "    [FEHLER] $msg" -ForegroundColor Red }
function Write-Info { param($msg) Write-Host "    $msg" -ForegroundColor Gray }

function Read-Input {
    param([string]$Prompt, [string]$Default = "", [switch]$MustExist)
    if ($NonInteractive) {
        if (-not $Default) { throw "NonInteractive: '$Prompt' ist Pflicht." }
        return $Default
    }
    while ($true) {
        $hint = if ($Default) { " [$Default]" } else { "" }
        $in = Read-Host "$Prompt$hint"
        if ([string]::IsNullOrWhiteSpace($in) -and $Default) { $in = $Default }
        if ([string]::IsNullOrWhiteSpace($in)) { Write-Warn "Leere Eingabe."; continue }
        if ($MustExist -and -not (Test-Path -LiteralPath $in)) { Write-Warn "Pfad existiert nicht: $in"; continue }
        return $in
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " agentbox: MCP-Server einbinden" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# --- 1. Ordner ---
Write-Step "1/5 MCP-Ordner bestimmen"
if (-not $McpPath) {
    $here = (Get-Location).Path
    if ((Test-Path (Join-Path $here "pyproject.toml")) -or
        (Test-Path (Join-Path $here "package.json")) -or
        (Test-Path (Join-Path $here "main.py"))) {
        $McpPath = $here
        Write-Info "Aktuelles Verzeichnis erkannt als MCP-Ordner."
    }
}
if (-not $McpPath) {
    $McpPath = Read-Input -Prompt "Pfad zum MCP-Server-Ordner" -MustExist
}
$McpPath = (Resolve-Path -LiteralPath $McpPath).Path
Write-Ok $McpPath

# --- 2. Typ + KiCad-Bezug erkennen ---
Write-Step "2/5 MCP-Typ erkennen"

function Test-HasFile { param($Dir, $Name) Test-Path -LiteralPath (Join-Path $Dir $Name) }

$isPython = (Test-HasFile $McpPath "pyproject.toml") -or (Test-HasFile $McpPath "setup.py") -or (Test-HasFile $McpPath "requirements.txt")
$isNode   = Test-HasFile $McpPath "package.json"
if ($isPython -and $isNode) {
    if ((Test-HasFile $McpPath "main.py") -or (Test-HasFile $McpPath "server.py")) { $isNode = $false }
    else { $isPython = $false }
}
if (-not $isPython -and -not $isNode) {
    if ((Test-HasFile $McpPath "main.py") -or (Test-HasFile $McpPath "server.py") -or (Test-HasFile $McpPath "__main__.py")) {
        $isPython = $true
    }
}
$mcpType = if ($isPython) { "python" } elseif ($isNode) { "node" } else { $null }
if (-not $mcpType) { Write-Err "MCP-Typ nicht erkannt (keine pyproject.toml/package.json/main.py)."; exit 1 }
Write-Ok "$mcpType-MCP"

function Test-IsKicadMcp {
    param([string]$Path)
    $leaf = (Split-Path -Leaf $Path).ToLowerInvariant()
    if ($leaf -match 'kicad') { return $true }
    foreach ($f in @("pyproject.toml", "README.md", "README.rst", "package.json")) {
        $fp = Join-Path $Path $f
        if (Test-Path -LiteralPath $fp) {
            $c = Get-Content -LiteralPath $fp -Raw -ErrorAction SilentlyContinue
            if ($c -and ($c -match 'pcbnew|kicad-cli|KiCad|kicad_mcp')) { return $true }
        }
    }
    return $false
}
$isKicad = Test-IsKicadMcp -Path $McpPath
if ($isKicad) { Write-Info "(KiCad-Bezug erkannt -- optimiere still im Hintergrund.)" }

# --- 3. MCP-ID ableiten ---
if (-not $McpId) {
    if ($mcpType -eq "python") {
        $py = Join-Path $McpPath "pyproject.toml"
        if (Test-Path -LiteralPath $py) {
            $content = Get-Content -LiteralPath $py -Raw
            if ($content -match '(?ms)\[project\][^\[]*?\bname\s*=\s*"([^"]+)"') { $McpId = $Matches[1].Trim() }
        }
    } elseif ($mcpType -eq "node") {
        $pkg = Join-Path $McpPath "package.json"
        if (Test-Path -LiteralPath $pkg) {
            try { $pj = Get-Content -LiteralPath $pkg -Raw | ConvertFrom-Json; if ($pj.name) { $McpId = [string]$pj.name } } catch { }
        }
    }
    if (-not $McpId) { $McpId = Split-Path -Leaf $McpPath }
    $McpId = $McpId.ToLowerInvariant() -replace '[^a-z0-9_-]', '-' -replace '-+', '-'
    $McpId = $McpId.Trim('-')
    if ([string]::IsNullOrWhiteSpace($McpId)) { $McpId = "mcp" }
    if ($isKicad -and $McpId -notmatch 'kicad') { $McpId = "kicad" }
    if ($isKicad -and $McpId -match '^kicad[-_]mcp$') { $McpId = "kicad" }
}
Write-Info "MCP-ID: $McpId"

# --- 4. Startbefehl + Dependencies ---
Write-Step "3/5 Startbefehl + Dependencies"
$command = $null
$cmdArgs = @()
$envMap = @{}
$cwd = $McpPath

if ($mcpType -eq "python") {
    # Python-Pfad: KiCad-Python bevorzugen wenn isKicad
    $pythonPath = $null
    if ($isKicad) {
        foreach ($c in @(
            "C:\Program Files\KiCad\10.0\bin\python.exe",
            "C:\Program Files (x86)\KiCad\10.0\bin\python.exe",
            "C:\Program Files\KiCad\9.0\bin\python.exe",
            "C:\Program Files (x86)\KiCad\9.0\bin\python.exe"
        )) {
            if (Test-Path -LiteralPath $c) { $pythonPath = $c; break }
        }
        if ($pythonPath) { Write-Info "Nutze KiCad-Python (wegen pcbnew): $pythonPath" }
    }
    if (-not $pythonPath) {
        $cmd = Get-Command python.exe -ErrorAction SilentlyContinue
        if ($cmd) { $pythonPath = $cmd.Source }
    }
    if (-not $pythonPath) { $pythonPath = Read-Input -Prompt "Pfad zu python.exe (3.10+)" -MustExist }
    $command = $pythonPath

    # Entry-Point
    $entryFound = $false
    $pyproject = Join-Path $McpPath "pyproject.toml"
    if (Test-Path -LiteralPath $pyproject) {
        $pj = Get-Content -LiteralPath $pyproject -Raw
        if ($pj -match '(?ms)\[project\.scripts\]\s*([^\[]+)') {
            $block = $Matches[1]
            if ($block -match '\s*([a-zA-Z0-9_-]+)\s*=\s*"([^"]+)"') {
                if ($Matches[2] -match '^([^:]+):') {
                    $cmdArgs = @("-m", $Matches[1]); $entryFound = $true
                }
            }
        }
        if (-not $entryFound -and ($pj -match '(?ms)\[project\][^\[]*?\bname\s*=\s*"([^"]+)"')) {
            $pkgName = $Matches[1].Trim().Replace('-', '_')
            if (Test-Path -LiteralPath (Join-Path $McpPath $pkgName)) {
                $cmdArgs = @("-m", $pkgName); $entryFound = $true
            }
        }
    }
    foreach ($f in @("main.py", "server.py", "__main__.py")) {
        if (-not $entryFound -and (Test-HasFile $McpPath $f)) { $cmdArgs = @($f); $entryFound = $true; break }
    }
    if (-not $entryFound) { Write-Err "Kein Python-Entry-Point gefunden."; exit 1 }
    Write-Ok "python $($cmdArgs -join ' ')"

    if (-not $SkipDepsInstall) {
        Write-Info "Installiere Python-Dependencies..."
        Push-Location $McpPath
        try {
            $target = "."
            if (Test-Path -LiteralPath $pyproject) {
                $pj = Get-Content -LiteralPath $pyproject -Raw
                if ($pj -match '(?ms)\[project\.optional-dependencies\][^\[]*?\bdev\s*=') { $target = ".[dev]" }
            }
            & $command -m pip install -e $target 2>&1 | ForEach-Object {
                if ($_ -match '^(ERROR|error:)') { Write-Host "      $_" -ForegroundColor Red }
                else { Write-Host "      $_" -ForegroundColor DarkGray }
            }
            if ($LASTEXITCODE -ne 0) { Write-Err "pip install fehlgeschlagen."; exit 1 }
        } finally { Pop-Location }
        Write-Ok "Dependencies installiert."
    }
} else {
    # Node
    $nodeCmd = Get-Command node.exe -ErrorAction SilentlyContinue
    if (-not $nodeCmd) { Write-Err "node.exe nicht gefunden."; exit 1 }
    $pkg = Join-Path $McpPath "package.json"
    $pj = Get-Content -LiteralPath $pkg -Raw | ConvertFrom-Json
    $entryFound = $false
    if ($pj.PSObject.Properties['bin']) {
        if ($pj.bin -is [string]) { $command = $nodeCmd.Source; $cmdArgs = @($pj.bin); $entryFound = $true }
        elseif ($pj.bin -is [PSCustomObject]) {
            $first = $pj.bin.PSObject.Properties | Select-Object -First 1
            if ($first) { $command = $nodeCmd.Source; $cmdArgs = @([string]$first.Value); $entryFound = $true }
        }
    }
    if (-not $entryFound -and $pj.PSObject.Properties['main']) {
        $command = $nodeCmd.Source; $cmdArgs = @([string]$pj.main); $entryFound = $true
    }
    if (-not $entryFound -and (Test-HasFile $McpPath "index.js")) {
        $command = $nodeCmd.Source; $cmdArgs = @("index.js"); $entryFound = $true
    }
    if (-not $entryFound) { Write-Err "Kein Node-Entry-Point gefunden."; exit 1 }
    Write-Ok "node $($cmdArgs -join ' ')"

    if (-not $SkipDepsInstall) {
        Write-Info "Installiere Node-Dependencies..."
        Push-Location $McpPath
        try {
            $npmCmd = Get-Command npm.cmd -ErrorAction SilentlyContinue
            if ($npmCmd) {
                & $npmCmd.Source install 2>&1 | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
                if ($LASTEXITCODE -ne 0) { Write-Err "npm install fehlgeschlagen."; exit 1 }
            }
        } finally { Pop-Location }
        Write-Ok "Dependencies installiert."
    }
}

# --- 5. Env-Vars ---
Write-Info "Erfasse Umgebungsvariablen..."
# (a) .env.example
$envExample = Join-Path $McpPath ".env.example"
if (Test-Path -LiteralPath $envExample) {
    Get-Content -LiteralPath $envExample | ForEach-Object {
        if ($_ -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*$') {
            $k = $Matches[1]; $v = $Matches[2] -replace '^"(.*)"$', '$1' -replace "^'(.*)'$", '$1'
            if (-not $envMap.ContainsKey($k)) { $envMap[$k] = $v }
        }
    }
}
# (b) KiCad-Defaults
if ($isKicad) {
    foreach ($c in @(
        "C:\Program Files\KiCad\10.0\bin\kicad-cli.exe",
        "C:\Program Files (x86)\KiCad\10.0\bin\kicad-cli.exe",
        "C:\Program Files\KiCad\9.0\bin\kicad-cli.exe"
    )) {
        if (Test-Path -LiteralPath $c) {
            if ([string]::IsNullOrEmpty($envMap['KICAD_CLI_PATH'])) { $envMap['KICAD_CLI_PATH'] = $c }
            break
        }
    }
    if ([string]::IsNullOrEmpty($envMap['KICAD_SEARCH_PATHS'])) {
        $searches = @()
        if ($env:OneDrive) {
            $c = Join-Path $env:OneDrive "AI_Projects_Source"
            if (Test-Path -LiteralPath $c) { $searches += $c }
        }
        $d = Join-Path $env:USERPROFILE "Documents\KiCad"
        if (Test-Path -LiteralPath $d) { $searches += $d }
        if ($searches.Count -gt 0) { $envMap['KICAD_SEARCH_PATHS'] = $searches -join ';' }
    }
}
# (c) ExtraEnv
foreach ($k in $ExtraEnv.Keys) { $envMap[$k] = [string]$ExtraEnv[$k] }
# (d) Secrets-Prompt
$secretPatterns = @('TOKEN$', 'KEY$', 'SECRET$', 'PASSWORD$', 'PASS$')
$secretsNeeded = @()
foreach ($k in @($envMap.Keys)) {
    $v = $envMap[$k]
    if ([string]::IsNullOrWhiteSpace($v) -or $v -match '^(your|xxx|changeme|<.*>|example)' -or $v -match '^\$\{') {
        foreach ($p in $secretPatterns) { if ($k -match $p) { $secretsNeeded += $k; break } }
    }
}
if ($secretsNeeded.Count -gt 0 -and -not $NonInteractive) {
    Write-Info "Secrets fehlen:"
    foreach ($k in $secretsNeeded) {
        $val = Read-Host "    $k"
        if ([string]::IsNullOrWhiteSpace($val)) { $envMap.Remove($k) | Out-Null; Write-Warn "    $k uebersprungen" }
        else { $envMap[$k] = $val }
    }
}
$cleanEnv = @{}
foreach ($k in $envMap.Keys) { if (-not [string]::IsNullOrWhiteSpace($envMap[$k])) { $cleanEnv[$k] = $envMap[$k] } }
$envMap = $cleanEnv
Write-Ok "Env: $($envMap.Count) Variable(n)"

# --- 6. config.json ---
Write-Step "4/5 agentbox-Konfiguration aktualisieren"
if (-not $AgentboxControlDir) {
    $ctrlCands = @()
    if ($env:OneDrive) {
        $ctrlCands += (Join-Path $env:OneDrive "AI_Projects_Source\_control")
        $ctrlCands += (Join-Path $env:OneDrive "AI_Projects\_control")
    }
    $ctrlCands += "D:\AI_Projects_Source\_control"
    $ctrlCands += (Join-Path $env:USERPROFILE "AI_Projects_Source\_control")
    foreach ($c in $ctrlCands) {
        if ($c -and (Test-Path -LiteralPath (Join-Path $c "config.json"))) { $AgentboxControlDir = $c; break }
    }
    if (-not $AgentboxControlDir) { $AgentboxControlDir = Read-Input -Prompt "Pfad zum _control-Ordner" -MustExist }
}
$configPath = Join-Path $AgentboxControlDir "config.json"
if (-not (Test-Path -LiteralPath $configPath)) { Write-Err "config.json fehlt: $configPath"; exit 1 }

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
if ($Port -gt 0) { $entry['port'] = $Port }
$config.mcp_servers = @($existing) + @([PSCustomObject]$entry)

$backupPath = "$configPath.backup.$(Get-Date -Format 'yyyyMMdd_HHmmss')"
Copy-Item -LiteralPath $configPath -Destination $backupPath
Write-Info "Backup: $backupPath"

$json = $config | ConvertTo-Json -Depth 20
$json = $json -replace "`r`n", "`n" -replace "`r", "`n"
if (-not $json.EndsWith("`n")) { $json += "`n" }
[System.IO.File]::WriteAllText($configPath, $json, (New-Object System.Text.UTF8Encoding $false))
Write-Ok "config.json geschrieben."

# --- 7. Dispatcher reload ---
Write-Step "5/5 MCP-Hintergrund-Prozess neu laden"
$taskName = "agentbox-mcp-dispatcher"
try { $null = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop } catch {
    Write-Err "Scheduled Task '$taskName' nicht registriert."
    Write-Info "Einmaliger Fix: install.ps1 als Admin ausfuehren."
    exit 2
}
try { Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue } catch { }
Start-Sleep -Seconds 1
try { Start-ScheduledTask -TaskName $taskName -ErrorAction Stop } catch {
    Write-Err "Start fehlgeschlagen: $($_.Exception.Message)"; exit 1
}
Write-Ok "Dispatcher neu gestartet."

# --- Status ---
Start-Sleep -Seconds 3
$portsFile = Join-Path $env:LOCALAPPDATA "agentbox\mcp-runtime\ports.json"
$bridgeLog = Join-Path $env:LOCALAPPDATA "agentbox\mcp-runtime\$McpId\bridge.log"
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
if (Test-Path -LiteralPath $portsFile) {
    try {
        $p = Get-Content -LiteralPath $portsFile -Raw | ConvertFrom-Json
        if ($p.PSObject.Properties[$McpId]) {
            $assignedPort = $p.$McpId
            Write-Host " [OK] '$McpId' laeuft auf Port $assignedPort" -ForegroundColor Green
            Write-Host " Neue agentbox-Session starten -> MCP wird vom Agent erreicht." -ForegroundColor Green
        } else {
            Write-Host " [WARN] '$McpId' nicht in ports.json -- Dispatcher-Log pruefen:" -ForegroundColor Yellow
            Write-Host "  $(Join-Path $env:LOCALAPPDATA 'agentbox\mcp-runtime\dispatcher.log')" -ForegroundColor Gray
        }
    } catch { Write-Warn "ports.json nicht lesbar" }
} else {
    Write-Host " [WARN] ports.json nicht da -- Dispatcher haengt?" -ForegroundColor Yellow
}
if (Test-Path -LiteralPath $bridgeLog) {
    Write-Host " Log fuer Fehlersuche: $bridgeLog" -ForegroundColor Gray
}
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
