# tools/bench.ps1 — agentbox Host-Baseline (Windows, NTFS, Host-Netz)
#
# Paar-Script zu tools/bench.sh. Beide **appenden** ins selbe
# bench-results.txt (CWD-relativ, ueberschreibbar via $env:BENCH_OUT).
# Wenn beide in einem agentbox-Projekt-Ordner laufen, teilen sie sich
# dieselbe Datei ueber den Bind-Mount — Host-Run und Sandbox-Run
# stehen dann direkt untereinander.
#
# Ausfuehrungsreihenfolge:
#   1. Netzwerk: 500 MB download von speed.cloudflare.com/__down
#   2. Disk: 1 GB sequential write mit Flush(true) (fsync-Aequivalent)
#   3. Disk: 10'000 kleine Files create (4 Byte each)
#
# Alle Tests raeumen danach hinter sich auf. $env:TEMP wird fuer Disk-
# Tests verwendet — liegt typisch auf dem System-Drive (NTFS).

$ErrorActionPreference = 'Stop'
$tmp     = $env:TEMP
$outFile = if ($env:BENCH_OUT) { $env:BENCH_OUT } else { Join-Path (Get-Location) "bench-results.txt" }
$stamp   = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss zzz")
$header  = "# ======== $stamp | platform=host ========"

Write-Host "========================================"
Write-Host " agentbox-bench v1 platform=host"
Write-Host "========================================"
Write-Host " Output-Datei: $outFile"

# --- 1. Network ---
Write-Host ""
Write-Host "[1/3] Netzwerk: 500 MB download von speed.cloudflare.com..."
$netUrl  = "https://speed.cloudflare.com/__down?bytes=524288000"
$netFile = Join-Path $tmp "bench_net.bin"
$netMbs  = 0
try {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & curl.exe -s -o $netFile -L --max-time 120 $netUrl
    $sw.Stop()
    if ($LASTEXITCODE -eq 0 -and (Test-Path $netFile)) {
        $sizeMB = (Get-Item $netFile).Length / 1MB
        $netMbs = [Math]::Round($sizeMB / $sw.Elapsed.TotalSeconds, 2)
    } else {
        Write-Host "   [WARN] Download fehlgeschlagen (curl exit=$LASTEXITCODE)" -ForegroundColor Yellow
    }
} catch {
    Write-Host "   [ERR] $($_.Exception.Message)" -ForegroundColor Red
} finally {
    if (Test-Path $netFile) { Remove-Item $netFile -Force -ErrorAction SilentlyContinue }
}
Write-Host "   -> $netMbs MB/s"

# --- 2. Disk: Sequential write 1 GB ---
Write-Host ""
Write-Host "[2/3] Disk seq write: 1 GB nach $tmp (NTFS)..."
$diskFile = Join-Path $tmp "bench_disk.bin"
$buf      = New-Object byte[] (1MB)
$sw       = [Diagnostics.Stopwatch]::StartNew()
$fs       = [IO.File]::Create($diskFile)
for ($i = 0; $i -lt 1024; $i++) { $fs.Write($buf, 0, $buf.Length) }
$fs.Flush($true)
$fs.Close()
$sw.Stop()
Remove-Item $diskFile -Force
$seqWriteMbs = [Math]::Round(1024 / $sw.Elapsed.TotalSeconds, 2)
Write-Host "   -> $seqWriteMbs MB/s"

# --- 3. Disk: 10'000 small files create ---
Write-Host ""
Write-Host "[3/3] Disk small-files: 10'000 x 4 B create..."
$dir = Join-Path $tmp "bench_small"
if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
New-Item -ItemType Directory -Path $dir | Out-Null
$sw = [Diagnostics.Stopwatch]::StartNew()
for ($i = 1; $i -le 10000; $i++) {
    [IO.File]::WriteAllText((Join-Path $dir "f_$i.txt"), "x")
}
$sw.Stop()
Remove-Item $dir -Recurse -Force
$elapsedSec     = [Math]::Round($sw.Elapsed.TotalSeconds, 3)
$smallFilesPerS = [Math]::Round(10000 / $sw.Elapsed.TotalSeconds, 0)
Write-Host "   -> $smallFilesPerS files/s (in ${elapsedSec}s)"

# --- Summary (stdout + append an bench-results.txt) ---
$summaryLines = @(
    $header,
    "agentbox-bench v1 platform=host",
    "net_download_mbs=$netMbs",
    "disk_seq_write_mbs=$seqWriteMbs",
    "disk_small_files_per_s=$smallFilesPerS",
    ""
)
Write-Host ""
Write-Host "========================================"
Write-Host " Ergebnis (auch angehaengt an $outFile)"
Write-Host "========================================"
$summaryLines | ForEach-Object { Write-Host $_ }

try {
    $outDir = Split-Path -Parent $outFile
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
        [System.IO.Directory]::CreateDirectory($outDir) | Out-Null
    }
    $toAppend = ($summaryLines -join "`r`n") + "`r`n"
    [IO.File]::AppendAllText($outFile, $toAppend, (New-Object System.Text.UTF8Encoding($false)))
} catch {
    Write-Host "[WARN] Konnte nicht an $outFile anhaengen: $($_.Exception.Message)" -ForegroundColor Yellow
}
