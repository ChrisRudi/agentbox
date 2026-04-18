# diagnose.ps1
# agentbox -- Host-Side Diagnose fuer den kompletten Task-Runner-Flow
# Laeuft die ganze Kette durch: Scheduled Task, Event-Source, config.json,
# Whitelist, demo-benchmark Seed, project.json Match, pending Tasks,
# history, EventLog, bench-Output, Versions-Dateien.
#
# Aufruf:
#   powershell -NoProfile -ExecutionPolicy Bypass -File diagnose.ps1
#
# Exit-Code: 0 wenn alle Checks OK, 1 bei >=1 FAIL.
#
# PS 5.1 kompatibel: keine Here-Strings, kein New-Item -LiteralPath,
# ASCII-only (die CLAUDE.md-Regel).

$ErrorActionPreference = "Continue"

# --- Counter fuer Summary ---
$script:fails  = 0
$script:warns  = 0
$script:passes = 0

function Line-OK   { param([string]$m) Write-Host "[ OK  ] $m" -ForegroundColor Green;   $script:passes++ }
function Line-WARN { param([string]$m) Write-Host "[WARN ] $m" -ForegroundColor Yellow;  $script:warns++  }
function Line-FAIL { param([string]$m) Write-Host "[FAIL ] $m" -ForegroundColor Red;     $script:fails++  }
function Line-INFO { param([string]$m) Write-Host "        $m" -ForegroundColor Gray }
function Line-HEAD { param([string]$m)
    Write-Host ""
    Write-Host "--- $m ---" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "=== agentbox diagnose ===" -ForegroundColor Cyan
Write-Host "Zeitpunkt: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
Write-Host ""

# --- Pfadaufloesung (spiegelt win-task-runner.ps1) ---
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

$baseDir = $null
if ($env:OneDrive) {
    $baseDir = Join-Path $env:OneDrive "AI_Projects_Source"
} elseif ($scriptDir -match '(.+)[\\/]_control$') {
    $baseDir = $Matches[1]
}
$controlDir = if ($baseDir) { Join-Path $baseDir "_control" } else { $scriptDir }

$configPath = Join-Path $controlDir "config.json"
$config = $null
if (Test-Path -LiteralPath $configPath) {
    try {
        $config = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch {
        # Konfig kaputt -- im Check unten bemerkt
    }
}

# base_path_override
if ($config -and $config.base_path_override -and $config.base_path_override -ne "") {
    $baseDir = $config.base_path_override
    $cdName = if ($config.control_dir_name) { $config.control_dir_name } else { "_control" }
    $controlDir = Join-Path $baseDir $cdName
    $configPath = Join-Path $controlDir "config.json"
}

$taskName    = if ($config -and $config.scheduled_task_name) { $config.scheduled_task_name } else { "agentbox-task-runner" }
$eventSource = if ($config -and $config.event_log_source)    { $config.event_log_source    } else { "AIProjects" }
$demoDir     = if ($baseDir) { Join-Path $baseDir "demo-benchmark" } else { $null }
$historyDir  = Join-Path $controlDir "history"

Line-INFO "baseDir     : $baseDir"
Line-INFO "controlDir  : $controlDir"
Line-INFO "demoDir     : $demoDir"
Line-INFO "taskName    : $taskName"
Line-INFO "eventSource : $eventSource"

# ================================================================
# 1. Scheduled Task
# ================================================================
Line-HEAD "1. Scheduled Task"

$task = $null
try {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
} catch {
    Line-FAIL "Scheduled Task '$taskName' NICHT gefunden. install.ps1 als Admin ausfuehren."
}

if ($task) {
    Line-OK "Scheduled Task '$taskName' registriert"

    $action = $task.Actions | Select-Object -First 1
    if (-not $action) {
        Line-FAIL "Task hat keine Action"
    } else {
        if ($action.Execute -match "powershell\.exe$|powershell$") {
            Line-OK "Action Execute = $($action.Execute)"
        } else {
            Line-FAIL "Action Execute != powershell.exe (ist: $($action.Execute))"
        }

        if ($action.Arguments -match "win-task-runner\.ps1") {
            Line-OK "Action ruft win-task-runner.ps1 auf"
        } else {
            Line-FAIL "Action ruft win-task-runner.ps1 NICHT auf"
            Line-INFO "Arguments: $($action.Arguments)"
        }

        if ($action.Arguments -match "-once") {
            Line-OK "Action laeuft im -once Mode"
        } else {
            Line-WARN "Action laeuft nicht im -once Mode (Arguments: $($action.Arguments))"
        }

        if ($action.Arguments -match "-WindowStyle\s+Hidden") {
            Line-OK "WindowStyle Hidden aktiv (Fenster wird unterdrueckt)"
        } else {
            Line-WARN "WindowStyle Hidden nicht gesetzt -- Fenster bleibt sichtbar"
        }

        if ($action.WorkingDirectory) {
            if (Test-Path -LiteralPath $action.WorkingDirectory) {
                Line-OK "WorkingDirectory existiert: $($action.WorkingDirectory)"
            } else {
                Line-FAIL "WorkingDirectory existiert NICHT: $($action.WorkingDirectory)"
            }
        } else {
            Line-WARN "Keine WorkingDirectory gesetzt"
        }
    }

    # Trigger
    $eventTrigger  = $task.Triggers | Where-Object { $_.CimClass.CimClassName -eq "MSFT_TaskEventTrigger" } | Select-Object -First 1
    $logonTrigger  = $task.Triggers | Where-Object { $_.CimClass.CimClassName -eq "MSFT_TaskLogonTrigger" } | Select-Object -First 1

    if ($eventTrigger) {
        if ($eventTrigger.Subscription -match "EventID\]=2000|EventID=2000") {
            Line-OK "Event-Trigger auf EventID 2000 konfiguriert"
        } else {
            Line-WARN "Event-Trigger vorhanden, aber NICHT auf EventID 2000"
            Line-INFO "Subscription: $($eventTrigger.Subscription)"
        }
    } else {
        Line-FAIL "KEIN Event-Trigger (sollte MSFT_TaskEventTrigger mit EventID 2000 sein)"
    }

    if ($logonTrigger) {
        Line-OK "AtLogon-Trigger als Safety-Net konfiguriert"
    } else {
        Line-WARN "Kein AtLogon-Trigger -- pending Tasks werden nicht beim Login abgearbeitet"
    }

    # LastRun
    try {
        $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction Stop
        Line-INFO "LastRunTime      : $($info.LastRunTime)"
        Line-INFO "LastTaskResult   : 0x$('{0:X}' -f $info.LastTaskResult) ($($info.LastTaskResult))"
        Line-INFO "NextRunTime      : $($info.NextRunTime)"
        if ($info.LastTaskResult -eq 0) {
            Line-OK "Letzter Task-Run: Exit-Code 0"
        } elseif ($info.LastTaskResult -eq 267011 -or $info.LastTaskResult -eq 267009) {
            Line-INFO "(267011 = Task hat nie gelaufen / 267009 = Task laeuft gerade)"
        } else {
            Line-WARN "Letzter Task-Run: Exit-Code non-zero ($($info.LastTaskResult))"
        }
    } catch {
        Line-WARN "Konnte Task-Info nicht lesen: $($_.Exception.Message)"
    }
}

# ================================================================
# 2. Event-Source
# ================================================================
Line-HEAD "2. Event-Source"

try {
    if ([System.Diagnostics.EventLog]::SourceExists($eventSource)) {
        Line-OK "Event-Source '$eventSource' registriert"
    } else {
        Line-FAIL "Event-Source '$eventSource' NICHT registriert -- install.ps1 als Admin rerun"
    }
} catch {
    Line-WARN "Konnte SourceExists nicht pruefen: $($_.Exception.Message)"
}

# ================================================================
# 3. config.json
# ================================================================
Line-HEAD "3. config.json"

if (-not (Test-Path -LiteralPath $configPath)) {
    Line-FAIL "config.json nicht gefunden: $configPath"
} else {
    Line-OK "config.json vorhanden: $configPath"
    if (-not $config) {
        Line-FAIL "config.json NICHT parsebar (JSON-Fehler)"
    } else {
        Line-OK "config.json parsebar"
        if ($config.build_whitelist) {
            $wlCount = @($config.build_whitelist).Count
            Line-OK "build_whitelist hat $wlCount Eintrag/Eintraege"
            $benchEntry = "powershell -NoProfile -ExecutionPolicy Bypass -File bench.ps1"
            if ($config.build_whitelist -contains $benchEntry) {
                Line-OK "Whitelist enthaelt den bench.ps1-Eintrag"
            } else {
                Line-FAIL "Whitelist enthaelt NICHT den bench.ps1-Eintrag:"
                Line-INFO "Erwartet: $benchEntry"
                foreach ($wl in $config.build_whitelist) { Line-INFO "  - '$wl'" }
            }
        } else {
            Line-WARN "Kein build_whitelist -- Fallback in win-task-runner.ps1 greift (9 Eintraege inkl. bench.ps1)"
        }
    }
}

# ================================================================
# 4. win-task-runner.ps1
# ================================================================
Line-HEAD "4. win-task-runner.ps1"

$runnerPath = Join-Path $controlDir "win-task-runner.ps1"
if (Test-Path -LiteralPath $runnerPath) {
    Line-OK "win-task-runner.ps1 vorhanden: $runnerPath"
} else {
    Line-FAIL "win-task-runner.ps1 fehlt: $runnerPath"
}

# ================================================================
# 5. demo-benchmark Projekt
# ================================================================
Line-HEAD "5. demo-benchmark Projekt"

$projectConfig = $null
$projectJsonPath = $null
if (-not $demoDir -or -not (Test-Path -LiteralPath $demoDir)) {
    Line-FAIL "demo-benchmark-Ordner fehlt: $demoDir -- install.ps1 rerun"
} else {
    Line-OK "demo-benchmark vorhanden: $demoDir"

    $expectedFiles = @("bench.ps1", "bench.sh", "project.json")
    foreach ($f in $expectedFiles) {
        $p = Join-Path $demoDir $f
        if (Test-Path -LiteralPath $p) {
            Line-OK "$f vorhanden"
        } else {
            Line-FAIL "$f fehlt in demo-benchmark"
        }
    }

    # project.json parsen
    $projectJsonPath = Join-Path $demoDir "project.json"
    if (Test-Path -LiteralPath $projectJsonPath) {
        try {
            $projectConfig = Get-Content -LiteralPath $projectJsonPath -Raw | ConvertFrom-Json
            Line-OK "project.json parsebar"
        } catch {
            Line-FAIL "project.json NICHT parsebar: $($_.Exception.Message)"
        }
    }
}

# ================================================================
# 6. Whitelist-Match (exakter String)
# ================================================================
Line-HEAD "6. Whitelist-Match"

if ($projectConfig -and $projectConfig.build -and $projectConfig.build.command) {
    $pjCmd = $projectConfig.build.command
    Line-INFO "project.json build.command: '$pjCmd'"

    $wl = $null
    if ($config -and $config.build_whitelist) { $wl = @($config.build_whitelist) }

    if ($wl) {
        if ($wl -contains $pjCmd) {
            Line-OK "build.command matcht config.json Whitelist exakt"
        } else {
            Line-FAIL "build.command matcht Whitelist NICHT exakt -- Task wirft 'nicht in Whitelist'"
            # Levenshtein-lite: zeige den aehnlichsten Eintrag
            foreach ($w in $wl) {
                if ($w -and $pjCmd -and ($w.Length -eq $pjCmd.Length)) {
                    Line-INFO "Aehnlich (gleiche Laenge): '$w'"
                }
            }
        }
    } else {
        Line-WARN "config.json hat keine build_whitelist -- pruefe gegen Inline-Fallback manuell"
    }
} else {
    Line-WARN "project.json hat keinen build.command -- skip"
}

# ================================================================
# 7. _tasks/ Inhalt + status_build.json
# ================================================================
Line-HEAD "7. demo-benchmark/_tasks"

if ($demoDir -and (Test-Path -LiteralPath $demoDir)) {
    $tasksDir = Join-Path $demoDir "_tasks"
    if (-not (Test-Path -LiteralPath $tasksDir)) {
        Line-INFO "_tasks/ existiert nicht -- wird vom Watch-Modus on-demand angelegt"
    } else {
        $pending = @(Get-ChildItem -LiteralPath $tasksDir -Filter "*.json" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike "status_*" })
        if ($pending.Count -eq 0) {
            Line-OK "Keine pending Tasks"
        } else {
            Line-WARN "$($pending.Count) pending Task(s) in _tasks/ -- noch nicht abgearbeitet"
            foreach ($p in $pending) {
                Line-INFO "  $($p.Name) -- $($p.LastWriteTime)"
            }
        }

        $statusFile = Join-Path $tasksDir "status_build.json"
        if (Test-Path -LiteralPath $statusFile) {
            try {
                $st = Get-Content -LiteralPath $statusFile -Raw | ConvertFrom-Json
                Line-INFO "Letzter status_build: $($st.status) [$($st.timestamp)]"
                if ($st.error) { Line-INFO "  error: $($st.error)" }
                if ($st.status -eq "failed") { $script:warns++ }
            } catch {
                Line-WARN "status_build.json nicht parsebar"
            }
        } else {
            Line-INFO "status_build.json existiert nicht (noch kein Build gelaufen)"
        }
    }
}

# ================================================================
# 8. _control/history -- letzte failed Tasks
# ================================================================
Line-HEAD "8. history (letzte failed Tasks)"

if (-not (Test-Path -LiteralPath $historyDir)) {
    Line-INFO "history/ existiert nicht (noch kein Task gelaufen)"
} else {
    $hist = @(Get-ChildItem -LiteralPath $historyDir -Filter "*.json" -ErrorAction SilentlyContinue |
        Sort-Object -Property LastWriteTime -Descending)
    Line-INFO "history/ enthaelt $($hist.Count) Eintrag/Eintraege"
    $failedShown = 0
    foreach ($h in $hist) {
        if ($failedShown -ge 5) { break }
        try {
            $d = Get-Content -LiteralPath $h.FullName -Raw | ConvertFrom-Json
            if ($d.status -eq "failed") {
                Line-WARN "[$($d.completed)] $($d.project)/$($d.action) -- $($d.error)"
                $failedShown++
            }
        } catch { }
    }
    if ($failedShown -eq 0) {
        Line-OK "Keine failed Tasks in history/"
    }
}

# ================================================================
# 9. Letzte EventLog-Eintraege
# ================================================================
Line-HEAD "9. EventLog (letzte 10 Eintraege von Source $eventSource)"

try {
    $events = @(Get-WinEvent -FilterHashtable @{
        LogName      = 'Application'
        ProviderName = $eventSource
    } -MaxEvents 10 -ErrorAction Stop)

    if ($events.Count -eq 0) {
        Line-INFO "Keine Events gefunden"
    } else {
        Line-OK "$($events.Count) Events gefunden"
        foreach ($e in $events) {
            $msg = $e.Message
            if ($msg) {
                $firstLine = ($msg -split "`r?`n")[0]
                if ($firstLine.Length -gt 90) { $firstLine = $firstLine.Substring(0, 87) + "..." }
            } else {
                $firstLine = "(no message)"
            }
            $lbl = switch ($e.Id) {
                2000 { "TRIGGER" }
                1001 { "START  " }
                1002 { "DONE   " }
                1003 { "FAIL   " }
                default { "ID=$($e.Id)" }
            }
            Line-INFO "$($e.TimeCreated.ToString('MM-dd HH:mm:ss')) $lbl $firstLine"
        }
    }
} catch {
    Line-WARN "EventLog nicht lesbar: $($_.Exception.Message)"
}

# ================================================================
# 10. bench-results.json sanity
# ================================================================
Line-HEAD "10. bench-results.json"

if ($demoDir) {
    $resultsPath = Join-Path $demoDir "bench-results.json"
    if (-not (Test-Path -LiteralPath $resultsPath)) {
        Line-INFO "bench-results.json existiert nicht (noch kein Run)"
    } else {
        try {
            $r = Get-Content -LiteralPath $resultsPath -Raw | ConvertFrom-Json
            Line-OK "bench-results.json parsebar"
            foreach ($key in @("host", "agentbox_host")) {
                if ($r.$key) {
                    $ts = $r.$key.timestamp
                    Line-OK ".$key vorhanden (timestamp: $ts)"
                } else {
                    Line-INFO ".$key fehlt (noch nicht gemessen)"
                }
            }
        } catch {
            Line-FAIL "bench-results.json NICHT parsebar: $($_.Exception.Message)"
        }
    }

    $htmlPath = Join-Path $demoDir "index.html"
    if (Test-Path -LiteralPath $htmlPath) {
        $age = (Get-Date) - (Get-Item -LiteralPath $htmlPath).LastWriteTime
        Line-INFO "index.html Alter: $([int]$age.TotalMinutes) Minute(n)"
    }
}

# ================================================================
# 11. Versions-Dateien
# ================================================================
Line-HEAD "11. .version / .update_class"

$verFile = Join-Path $controlDir ".version"
$ucFile  = Join-Path $controlDir ".update_class"

if (Test-Path -LiteralPath $verFile) {
    $v = (Get-Content -LiteralPath $verFile -Raw).Trim()
    Line-OK ".version: $v"
} else {
    Line-WARN ".version fehlt"
}

if (Test-Path -LiteralPath $ucFile) {
    $uc = (Get-Content -LiteralPath $ucFile -Raw).Trim()
    if ($uc -in @("minor", "major")) {
        Line-OK ".update_class: $uc"
    } else {
        Line-WARN ".update_class: '$uc' (erwartet: minor oder major)"
    }
} else {
    Line-INFO ".update_class fehlt -- default minor"
}

# ================================================================
# Summary
# ================================================================
Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Cyan
$total = $script:passes + $script:warns + $script:fails
Write-Host "Summary: $($script:passes) passed / $($script:warns) warnings / $($script:fails) failed  (von $total)" -ForegroundColor Cyan

if ($script:fails -gt 0) {
    Write-Host ""
    Write-Host "FAIL -- behebe die [FAIL]-Zeilen (siehe oben)." -ForegroundColor Red
    exit 1
} elseif ($script:warns -gt 0) {
    Write-Host ""
    Write-Host "WARNINGS -- System laeuft, aber die [WARN]-Zeilen deuten auf Drift hin." -ForegroundColor Yellow
    exit 0
} else {
    Write-Host ""
    Write-Host "All green -- alle Checks OK." -ForegroundColor Green
    exit 0
}
