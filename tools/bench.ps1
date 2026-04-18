# tools/bench.ps1 -- agentbox Host-Baseline (Windows, NTFS, Host-Netz)
#
# Paar-Script zu tools/bench.sh. Beide **appenden** ins selbe
# bench-results.txt (CWD-relativ, ueberschreibbar via $env:BENCH_OUT).
# Wenn beide in einem agentbox-Projekt-Ordner laufen, teilen sie sich
# dieselbe Datei ueber den Bind-Mount -- Host-Run und Sandbox-Run
# stehen dann direkt untereinander.
#
# Ausfuehrungsreihenfolge:
#   1. Netzwerk: 500 MB download (Default: speed.cloudflare.com/__down).
#      Ueber $env:BENCH_URL aenderbar, falls der Upstream-SNI-Filter
#      die Subdomain blockt. Probiert bei Fehlschlag automatisch zwei
#      Fallback-URLs (registry.npmjs.org, fast-Cloudflare-Alt).
#   2. Disk: 1 GB sequential write mit Flush(true) (fsync-Aequivalent)
#   3. Disk: 10'000 kleine Files create (4 Byte each) mit Progress
#
# Alle Tests raeumen danach hinter sich auf. $env:TEMP wird fuer Disk-
# Tests verwendet -- liegt typisch auf dem System-Drive (NTFS).
#
# Hinweis: Windows-Defender Real-Time-Scan drueckt die Zahlen bei
# seq-write + small-files teils brutal (~50 %+). Das ist realistisch
# fuer den Dev-Alltag, kein Script-Bug. Zum Validieren kurz Defender-
# Exclusion auf $env:TEMP setzen und erneut messen.

$BENCH_VERSION = "2.1.4"

$ErrorActionPreference = 'Stop'
$tmp     = $env:TEMP
$outFile = if ($env:BENCH_OUT) { $env:BENCH_OUT } else { Join-Path (Get-Location) "bench-results.txt" }
$stamp   = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss zzz")

# Laufwerksbuchstabe der TEMP-Location -- manche Setups haben D:\Temp
# oder ein externes Drive, erklaert langsame Zahlen.
$tmpDrive = (Split-Path -Qualifier $tmp) -replace '[^A-Za-z:]',''
$header   = "# ======== $stamp | platform=host | version=$BENCH_VERSION | temp_drive=$tmpDrive ========"

Write-Host "========================================"
Write-Host " agentbox-bench v$BENCH_VERSION platform=host" -ForegroundColor Cyan
Write-Host "========================================"
Write-Host " Output-Datei:  $outFile"
Write-Host " TEMP-Location: $tmp"

# --- 1. Network ---
Write-Host ""
Write-Host "[1/3] Netzwerk: 500 MB download..."

function Test-Download {
    param([string]$Url, [string]$OutPath)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    # --show-error + Werte nach stderr, dann per 2>&1 auffangen.
    # -w schreibt http_code/size/time nach stdout zur Diagnose.
    $info = & curl.exe -sS -L --max-time 120 `
        -o $OutPath `
        -w "http_code=%{http_code}`nsize_download=%{size_download}`nspeed_download=%{speed_download}`n" `
        $Url 2>&1
    $sw.Stop()
    $curlExit = $LASTEXITCODE
    $result = [ordered]@{
        url        = $Url
        exit_code  = $curlExit
        http_code  = 0
        size_bytes = 0
        mbs        = 0
        error      = $null
    }
    if ($info) {
        foreach ($line in ($info | ForEach-Object { "$_" })) {
            if ($line -match '^http_code=(\d+)')       { $result.http_code  = [int]$Matches[1] }
            elseif ($line -match '^size_download=(\d+)') { $result.size_bytes = [long]$Matches[1] }
        }
        # Fehlermeldung = jede Zeile, die nicht ein key=value ist.
        $result.error = (@($info) | Where-Object { $_ -notmatch '^(http_code|size_download|speed_download)=' } | Select-Object -First 1)
    }
    if ($curlExit -eq 0 -and $result.http_code -ge 200 -and $result.http_code -lt 400 -and $result.size_bytes -gt 0) {
        $result.mbs = [Math]::Round(($result.size_bytes / 1MB) / $sw.Elapsed.TotalSeconds, 2)
    }
    return $result
}

$urlsToTry = @()
if ($env:BENCH_URL) {
    $urlsToTry += $env:BENCH_URL
} else {
    $urlsToTry = @(
        "https://speed.cloudflare.com/__down?bytes=524288000",
        "https://registry.npmjs.org/react/-/react-18.3.1.tgz",
        "https://proof.ovh.net/files/100Mb.dat"
    )
}

$netFile = Join-Path $tmp "bench_net.bin"
$netMbs  = 0
$netUrlUsed = ""
foreach ($u in $urlsToTry) {
    Write-Host "   Versuche: $u"
    $r = Test-Download -Url $u -OutPath $netFile
    if (Test-Path $netFile) { Remove-Item $netFile -Force -ErrorAction SilentlyContinue }
    if ($r.mbs -gt 0) {
        $netMbs = $r.mbs
        $netUrlUsed = $u
        Write-Host "   [OK] $($r.size_bytes) Bytes, HTTP $($r.http_code), $($r.mbs) MB/s"
        break
    } else {
        $errMsg = if ($r.error) { " -- $($r.error.Trim())" } else { "" }
        Write-Host "   [FAIL] exit=$($r.exit_code), http=$($r.http_code), size=$($r.size_bytes)$errMsg" -ForegroundColor Yellow
    }
}
if ($netMbs -eq 0) {
    Write-Host "   [WARN] Alle Download-Ziele fehlgeschlagen -- vermutlich SNI-Filter oder offline." -ForegroundColor Yellow
    Write-Host "          Override: `$env:BENCH_URL = 'https://dein-allowlisted-host/grosse-datei'" -ForegroundColor Gray
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

# --- 3. Disk: 10'000 small files create (mit Progress) ---
Write-Host ""
Write-Host "[3/3] Disk small-files: 10'000 x 4 B create (Progress alle 1000)..."
$dir = Join-Path $tmp "bench_small"
if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
New-Item -ItemType Directory -Path $dir | Out-Null
$sw = [Diagnostics.Stopwatch]::StartNew()
for ($i = 1; $i -le 10000; $i++) {
    [IO.File]::WriteAllText((Join-Path $dir "f_$i.txt"), "x")
    if ($i % 1000 -eq 0) {
        $cur = [Math]::Round($i / $sw.Elapsed.TotalSeconds, 0)
        Write-Host "   ... $i / 10000 ($cur files/s)" -ForegroundColor DarkGray
    }
}
$sw.Stop()
Remove-Item $dir -Recurse -Force
$elapsedSec     = [Math]::Round($sw.Elapsed.TotalSeconds, 3)
$smallFilesPerS = [Math]::Round(10000 / $sw.Elapsed.TotalSeconds, 0)
Write-Host "   -> $smallFilesPerS files/s (in ${elapsedSec}s)"

# --- Summary (stdout + append an bench-results.txt) ---
$summaryLines = @(
    $header,
    "agentbox-bench version=$BENCH_VERSION platform=host",
    "net_download_mbs=$netMbs",
    "net_url=$netUrlUsed",
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
