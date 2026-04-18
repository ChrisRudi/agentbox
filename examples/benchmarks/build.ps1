# benchmarks/build.ps1 -- Default-Demo fuer agentbox Build-Task-Runner
#
# Wird vom Host-seitigen win-task-runner.ps1 getriggert, wenn der Agent
# in der Sandbox _tasks/build_*.json schreibt. Delegiert an die
# kanonische Host-Bench aus _control/tools/bench.ps1 (v2.2.0+).
#
# bench.ps1 misst 5 Workloads (Netz, Disk seq, Disk small-files, CPU-
# SHA256, Process-spawn), haengt eine Zeile an bench-results.jsonl im
# aktuellen Verzeichnis an und generiert anschliessend index.html mit
# den Durchschnitten + Wirkungsgrad aus allen bisherigen Host- und
# Sandbox-Runs in der JSONL.
#
# Das Pair-Script _control/tools/bench.sh schreibt mit platform=sandbox
# in dieselbe JSONL -- einmal aus der Sandbox laufen lassen, dann
# diesen Build triggern, und index.html zeigt beide Spalten.
#
# Dieser Wrapper demonstriert die agentbox-PS-Convention: build.ps1 im
# Projekt-Root, delegiert an Shared-Tools im parallelen _control/. Kein
# Duplikat, eine Source-of-Truth.

$ErrorActionPreference = 'Stop'

$controlBench = Join-Path $PSScriptRoot "..\_control\tools\bench.ps1"

if (Test-Path -LiteralPath $controlBench) {
    Write-Host "[build.ps1] agentbox benchmarks demo -- delegating to tools\bench.ps1"
    & $controlBench
} else {
    Write-Host "[build.ps1] _control\tools\bench.ps1 not found at $controlBench"
    Write-Host "[build.ps1] Demo build completed at $(Get-Date -Format 'o')"
}
