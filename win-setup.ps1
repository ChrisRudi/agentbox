# win-setup.ps1 — PS 5.1 LF-kompatibler Shim (nur Single-Line-Statements, kein Multi-Line)
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Invoke-Expression ([System.IO.File]::ReadAllText((Join-Path $scriptDir 'win-setup-core.ps1')))
