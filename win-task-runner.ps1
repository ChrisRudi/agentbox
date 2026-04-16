# win-task-runner.ps1
# agentbox — Task Queue + Build/Deploy Runner
# Modi: -watch (FileSystemWatcher Daemon) oder -once (einmal durchlaufen)
# Version: 3.2

param(
    [switch]$watch,
    [switch]$once
)

$ErrorActionPreference = "Stop"

# --- Konfiguration ---
# Pfad robust bestimmen: 1. Umgebungsvariable, 2. relativ zum Skriptort
if ($env:OneDrive) {
    $baseDir = Join-Path $env:OneDrive "AI_Projects_Source"
} elseif ($PSScriptRoot -and $PSScriptRoot -match '(.+)[\\/]_control$') {
    # Skript liegt in _control → Elternordner ist baseDir
    $baseDir = $Matches[1]
} else {
    Write-Host "FEHLER: OneDrive-Pfad nicht ermittelbar." -ForegroundColor Red
    Write-Host "Setze die Umgebungsvariable OneDrive oder starte aus dem _control-Ordner." -ForegroundColor Yellow
    exit 1
}
$controlDir = Join-Path $baseDir "_control"

# --- config.json laden ---
$configPath = Join-Path $controlDir "config.json"
$config = $null
try {
    if (Test-Path -LiteralPath $configPath) {
        $config = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop | ConvertFrom-Json
    }
} catch {
    Write-Host "[INFO] config.json nicht lesbar — verwende Standardwerte." -ForegroundColor Gray
}

# base_path_override aus Config anwenden
if ($config -and $config.base_path_override -and $config.base_path_override -ne "") {
    $baseDir = $config.base_path_override
    $controlDir = Join-Path $baseDir (
        if ($config.control_dir_name) { $config.control_dir_name } else { "_control" }
    )
}

$historyDir = Join-Path $controlDir "history"
$eventSource = if ($config -and $config.event_log_source) { $config.event_log_source } else { "AIProjects" }

# Build-Whitelist (exakter Match, kein Prefix, kein Wildcard)
$buildWhitelist = if ($config -and $config.build_whitelist) {
    @($config.build_whitelist)
} else {
    @(
        "npm run build",
        "npm run test",
        "npm install",
        "pip install -r requirements.txt",
        "python build.py",
        "python setup.py install",
        "dotnet build",
        "make"
    )
}

# Deploy-Whitelist (exakter Match)
$deployWhitelist = if ($config -and $config.deploy_whitelist) {
    @($config.deploy_whitelist)
} else {
    @(
        "local",
        "github"
    )
}

# --- Hilfsfunktionen ---

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "ERROR"   { "Red" }
        "WARN"    { "Yellow" }
        "OK"      { "Green" }
        default   { "White" }
    }
    Write-Host "[$timestamp] $Level — $Message" -ForegroundColor $color
}

function Write-EventLogEntry {
    param([string]$Message, [string]$EntryType = "Information", [int]$EventId = 1000)
    try {
        Write-EventLog -LogName Application -Source $eventSource -EntryType $EntryType `
            -EventId $EventId -Message $Message -ErrorAction SilentlyContinue
    } catch {
        # Event-Log nicht verfuegbar — ignorieren
    }
}

function Write-StatusFile {
    param(
        [string]$ProjectDir,
        [string]$Action,
        [string]$Status,
        [string]$ErrorMsg = ""
    )
    $tasksDir = Join-Path $ProjectDir "_tasks"
    $statusFile = Join-Path $tasksDir "status_$Action.json"

    $statusObj = @{
        status    = $Status
        timestamp = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
    }
    if ($ErrorMsg) {
        $statusObj.error = $ErrorMsg
    }

    [System.IO.File]::WriteAllText($statusFile, ($statusObj | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding $false))
}

function Move-TaskToHistory {
    param(
        [string]$TaskFilePath,
        [hashtable]$TaskData,
        [string]$Status,
        [string]$ErrorMsg = ""
    )

    if (-not (Test-Path -LiteralPath $historyDir)) {
        [System.IO.Directory]::CreateDirectory($historyDir) | Out-Null
    }

    $TaskData.status = $Status
    $TaskData.completed = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
    if ($ErrorMsg) {
        $TaskData.error = $ErrorMsg
    }

    $historyName = "$(Get-Date -Format 'yyyyMMdd_HHmmss')_$($TaskData.project)_$($TaskData.action).json"
    $historyPath = Join-Path $historyDir $historyName

    [System.IO.File]::WriteAllText($historyPath, ($TaskData | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding $false))

    # .NET-API statt Remove-Item: PS 5.1 hat einen Provider-Bug, bei dem
    # Remove-Item -LiteralPath bei Tilde-Pfaden (Username mit Umlaut →
    # Schueler → SCHLER~1) mit InvalidArgument crasht.
    try { [System.IO.File]::Delete($TaskFilePath) } catch { }
}

# --- Teil 1: Fehleranzeige ---

function Show-FailedTasks {
    if (-not (Test-Path -LiteralPath $historyDir)) { return }

    $failedFiles = Get-ChildItem -LiteralPath $historyDir -Filter "*.json" -ErrorAction SilentlyContinue |
        Sort-Object -Property LastWriteTime -Descending

    $failedTasks = @()
    foreach ($file in $failedFiles) {
        try {
            $data = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            if ($data.status -eq "failed") {
                $failedTasks += $data
            }
        } catch {
            continue
        }
    }

    if ($failedTasks.Count -gt 0) {
        Write-Host ""
        Write-Host "=== FEHLGESCHLAGENE TASKS ===" -ForegroundColor Red
        foreach ($task in $failedTasks) {
            $ts = if ($task.completed) { $task.completed } else { "unbekannt" }
            Write-Host "  [$ts] $($task.project) / $($task.action)" -ForegroundColor Red
            Write-Host "  Fehler: $($task.error)" -ForegroundColor Yellow
            Write-Host ""
        }
        Write-Host "Kein automatischer Retry. Bitte manuell beheben." -ForegroundColor Gray
        Write-Host ""
    }
}

# --- Teil 2 + 3: Task-Verarbeitung ---

function Invoke-BuildAction {
    param(
        [string]$ProjectDir,
        [PSCustomObject]$ProjectConfig
    )

    if (-not $ProjectConfig.build -or -not $ProjectConfig.build.command) {
        Write-Log "Kein Build konfiguriert — ueberspringe." "WARN"
        return
    }

    $buildCmd = $ProjectConfig.build.command

    # Whitelist-Pruefung (exakter Match)
    if ($buildCmd -notin $buildWhitelist) {
        throw "Build-Kommando nicht in Whitelist: '$buildCmd'"
    }

    $outputDir = "build_out"
    if ($ProjectConfig.build.output_dir) {
        $outputDir = $ProjectConfig.build.output_dir
    }
    $outputPath = Join-Path $ProjectDir $outputDir
    if (-not (Test-Path -LiteralPath $outputPath)) {
        [System.IO.Directory]::CreateDirectory($outputPath) | Out-Null
    }

    Write-Log "Fuehre Build aus: $buildCmd" "INFO"

    $process = Start-Process -FilePath "cmd.exe" `
        -ArgumentList "/c", "cd /d `"$ProjectDir`" && $buildCmd" `
        -Wait -NoNewWindow -PassThru

    if ($process.ExitCode -ne 0) {
        throw "Build fehlgeschlagen mit Exit-Code $($process.ExitCode)"
    }

    Write-Log "Build erfolgreich." "OK"
}

function Invoke-DeployAction {
    param(
        [string]$ProjectDir,
        [PSCustomObject]$ProjectConfig
    )

    if (-not $ProjectConfig.deploy -or -not $ProjectConfig.deploy.target) {
        throw "Deploy-Target nicht konfiguriert in project.json"
    }

    $target = $ProjectConfig.deploy.target

    # Whitelist-Pruefung (exakter Match)
    if ($target -notin $deployWhitelist) {
        throw "Deploy-Target nicht in Whitelist: '$target'"
    }

    switch ($target) {
        "local" {
            Write-Log "Deploy-Target 'local' — keine Aktion noetig." "OK"
        }
        "github" {
            Write-Log "Deploy nach GitHub..." "INFO"
            $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

            Push-Location $ProjectDir
            try {
                $addResult = Start-Process -FilePath "git.exe" `
                    -ArgumentList "add", "-A" `
                    -Wait -NoNewWindow -PassThru
                if ($addResult.ExitCode -ne 0) { throw "git add fehlgeschlagen" }

                $commitResult = Start-Process -FilePath "git.exe" `
                    -ArgumentList "commit", "-m", "Deploy $timestamp" `
                    -Wait -NoNewWindow -PassThru
                if ($commitResult.ExitCode -ne 0) { throw "git commit fehlgeschlagen" }

                $pushResult = Start-Process -FilePath "git.exe" `
                    -ArgumentList "push", "origin", "main" `
                    -Wait -NoNewWindow -PassThru
                if ($pushResult.ExitCode -ne 0) { throw "git push fehlgeschlagen" }

                Write-Log "GitHub-Deploy erfolgreich." "OK"
            } finally {
                Pop-Location
            }
        }
    }
}

function Process-SingleTask {
    param([string]$TaskFilePath)

    $fileName = Split-Path -Leaf $TaskFilePath
    Write-Log "Verarbeite Task: $fileName"

    # Task-Datei lesen und validieren
    try {
        $taskData = Get-Content -LiteralPath $TaskFilePath -Raw | ConvertFrom-Json
    } catch {
        Write-Log "Ungueltige JSON-Datei: $fileName" "ERROR"
        return
    }

    if (-not $taskData.project -or -not $taskData.action) {
        Write-Log "Pflichtfelder 'project' oder 'action' fehlen in $fileName" "ERROR"
        return
    }

    $action = $taskData.action
    $projectName = $taskData.project

    # Action-Whitelist
    if ($action -notin @("build", "deploy")) {
        Write-Log "Unbekannte Aktion '$action' in $fileName — abgelehnt." "ERROR"
        $taskHash = @{
            project   = $projectName
            action    = $action
            timestamp = $taskData.timestamp
        }
        Move-TaskToHistory -TaskFilePath $TaskFilePath -TaskData $taskHash `
            -Status "failed" -ErrorMsg "Unbekannte Aktion: $action"
        return
    }

    # Projektordner finden
    $projectDir = Get-ChildItem -LiteralPath $baseDir -Directory |
        Where-Object { $_.Name -eq $projectName -and $_.Name -ne "_control" } |
        Select-Object -First 1

    if (-not $projectDir) {
        Write-Log "Projekt '$projectName' nicht gefunden." "ERROR"
        $taskHash = @{
            project   = $projectName
            action    = $action
            timestamp = $taskData.timestamp
        }
        Move-TaskToHistory -TaskFilePath $TaskFilePath -TaskData $taskHash `
            -Status "failed" -ErrorMsg "Projekt nicht gefunden: $projectName"
        return
    }

    $projectPath = $projectDir.FullName

    # project.json lesen
    $projectJsonPath = Join-Path $projectPath "project.json"
    if (-not (Test-Path -LiteralPath $projectJsonPath)) {
        Write-Log "project.json nicht gefunden in $projectPath" "ERROR"
        $taskHash = @{
            project   = $projectName
            action    = $action
            timestamp = $taskData.timestamp
        }
        Move-TaskToHistory -TaskFilePath $TaskFilePath -TaskData $taskHash `
            -Status "failed" -ErrorMsg "project.json nicht gefunden"
        Write-StatusFile -ProjectDir $projectPath -Action $action `
            -Status "failed" -ErrorMsg "project.json nicht gefunden"
        return
    }

    $projectConfig = Get-Content -LiteralPath $projectJsonPath -Raw | ConvertFrom-Json

    # Status: running
    Write-StatusFile -ProjectDir $projectPath -Action $action -Status "running"
    Write-EventLogEntry -Message "Task gestartet: $projectName / $action" -EventId 1001

    # Ausfuehren
    $taskHash = @{
        project   = $projectName
        action    = $action
        timestamp = $taskData.timestamp
    }

    try {
        switch ($action) {
            "build"  { Invoke-BuildAction -ProjectDir $projectPath -ProjectConfig $projectConfig }
            "deploy" { Invoke-DeployAction -ProjectDir $projectPath -ProjectConfig $projectConfig }
        }

        # Erfolg
        Move-TaskToHistory -TaskFilePath $TaskFilePath -TaskData $taskHash -Status "done"
        Write-StatusFile -ProjectDir $projectPath -Action $action -Status "done"
        Write-EventLogEntry -Message "Task erledigt: $projectName / $action" -EventId 1002

        Write-Log "Task erledigt: $projectName / $action" "OK"

    } catch {
        $errorMsg = $_.Exception.Message

        Move-TaskToHistory -TaskFilePath $TaskFilePath -TaskData $taskHash `
            -Status "failed" -ErrorMsg $errorMsg
        Write-StatusFile -ProjectDir $projectPath -Action $action `
            -Status "failed" -ErrorMsg $errorMsg
        Write-EventLogEntry -Message "Task fehlgeschlagen: $projectName / $action — $errorMsg" `
            -EntryType "Error" -EventId 1003

        Write-Log "Task fehlgeschlagen: $errorMsg" "ERROR"
    }
}

function Process-AllTasks {
    if (-not (Test-Path -LiteralPath $baseDir)) { return }

    $projectDirs = Get-ChildItem -LiteralPath $baseDir -Directory |
        Where-Object { $_.Name -ne "_control" }

    foreach ($projDir in $projectDirs) {
        $tasksDir = Join-Path $projDir.FullName "_tasks"
        if (-not (Test-Path -LiteralPath $tasksDir)) { continue }

        # .json Dateien suchen (keine .tmp)
        $taskFiles = Get-ChildItem -LiteralPath $tasksDir -Filter "*.json" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike "status_*" } |
            Sort-Object -Property CreationTime

        # Rate Limit: max 1 Task pro Projekt gleichzeitig
        if ($taskFiles.Count -gt 0) {
            Process-SingleTask -TaskFilePath $taskFiles[0].FullName
        }
    }
}

# --- Hauptprogramm ---

Write-Host ""
Write-Host "=== agentbox Task Runner ===" -ForegroundColor Cyan
Write-Host ""

# Fehleranzeige (immer)
Show-FailedTasks

if ($watch) {
    # --- Watch-Modus: FileSystemWatcher ---
    Write-Log "Starte im Watch-Modus (Ctrl+C zum Beenden)..." "INFO"

    # Einmal alles verarbeiten
    Process-AllTasks

    $watchers = @()
    $projectDirs = Get-ChildItem -LiteralPath $baseDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne "_control" }

    foreach ($projDir in $projectDirs) {
        $tasksDir = Join-Path $projDir.FullName "_tasks"
        if (-not (Test-Path -LiteralPath $tasksDir)) {
            [System.IO.Directory]::CreateDirectory($tasksDir) | Out-Null
        }

        $watcher = New-Object System.IO.FileSystemWatcher
        $watcher.Path = $tasksDir
        $watcher.Filter = "*.json"
        $watcher.NotifyFilter = [System.IO.NotifyFilters]::FileName -bor `
                                [System.IO.NotifyFilters]::LastWrite
        $watcher.EnableRaisingEvents = $true

        $action = {
            $filePath = $Event.SourceEventArgs.FullPath
            $fileName = $Event.SourceEventArgs.Name

            # status_ Dateien ignorieren
            if ($fileName -like "status_*") { return }

            # Kurz warten (Datei koennte noch geschrieben werden)
            Start-Sleep -Milliseconds 500

            if (Test-Path -LiteralPath $filePath) {
                Process-SingleTask -TaskFilePath $filePath
            }
        }

        Register-ObjectEvent -InputObject $watcher -EventName "Created" `
            -Action $action -SourceIdentifier "agentbox_$($projDir.Name)" | Out-Null
        Register-ObjectEvent -InputObject $watcher -EventName "Renamed" `
            -Action $action -SourceIdentifier "agentbox_rename_$($projDir.Name)" | Out-Null

        $watchers += $watcher
        Write-Log "Ueberwache: $tasksDir"
    }

    Write-Log "FileSystemWatcher aktiv. Warte auf Tasks..."
    Write-Host ""

    try {
        while ($true) {
            Start-Sleep -Seconds 5
        }
    } finally {
        Write-Log "Beende Watch-Modus..." "WARN"
        foreach ($w in $watchers) {
            $w.EnableRaisingEvents = $false
            $w.Dispose()
        }
        Get-EventSubscriber | Where-Object { $_.SourceIdentifier -like "agentbox_*" } |
            Unregister-Event
    }

} elseif ($once) {
    # --- Once-Modus: einmal durchlaufen ---
    Write-Log "Einmal-Durchlauf..."
    Process-AllTasks
    Write-Log "Fertig."

} else {
    # Default: watch
    Write-Host "Verwendung: win-task-runner.ps1 -watch | -once" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  -watch    FileSystemWatcher Daemon (empfohlen)" -ForegroundColor White
    Write-Host "  -once     Einmal alle Tasks verarbeiten" -ForegroundColor White
    Write-Host ""
    Write-Host "Starte im Watch-Modus..." -ForegroundColor Cyan
    & $MyInvocation.MyCommand.Path -watch
}
