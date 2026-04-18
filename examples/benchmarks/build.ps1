# benchmarks/build.ps1 -- Default-Demo fuer agentbox Build-Task-Runner
#
# Wird vom Host-seitigen win-task-runner.ps1 getriggert, wenn der Agent
# in der Sandbox _tasks/build_*.json schreibt. Ruft die kanonische
# Host-Bench aus _control/tools/bench.ps1 auf (parallel zum Projekt-
# Ordner unter AI_Projects_Source/_control/).

$ErrorActionPreference = 'Stop'

$controlBench = Join-Path $PSScriptRoot "..\_control\tools\bench.ps1"

if (Test-Path -LiteralPath $controlBench) {
    Write-Host "[build.ps1] agentbox benchmarks demo -- running host bench"
    & $controlBench
} else {
    Write-Host "[build.ps1] _control\tools\bench.ps1 not found at $controlBench"
    Write-Host "[build.ps1] Demo build completed at $(Get-Date -Format 'o')"
}
