# bench.ps1 v2.2.0 -- agentbox Host-Baseline + Build-Schritt
#
# Paar-Script zu bench.sh. Beide haengen Resultate als JSONL-Zeile an
# bench-results.jsonl. Diese .ps1 ist auch der **Build-Schritt**: nach dem
# Messen liest sie die JSONL, berechnet Durchschnitte und schreibt eine
# statische index.html mit eingebackenen Werten + Wirkungsgrad.
#
# Tests: 1) Netz 100 MB  2) Disk seq 1 GB  3) 10'000 small files
#        4) CPU SHA256 500 MB  5) 500 x cmd /c exit
#
# Hinweis: Windows-Defender kann Disk + Spawn drueckten. Zum Validieren
# kurz Defender-Exclusion auf $env:TEMP setzen.

$BENCH_VERSION = "2.2.0"

$ErrorActionPreference = 'Stop'
$tmp     = $env:TEMP
$outFile = if ($env:BENCH_OUT) { $env:BENCH_OUT } else { Join-Path (Get-Location) "bench-results.jsonl" }
$htmlOut = if ($env:BENCH_HTML) { $env:BENCH_HTML } else { Join-Path (Get-Location) "index.html" }
$stamp   = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")
$tmpDrive = (Split-Path -Qualifier $tmp) -replace '[^A-Za-z:]',''

Write-Host "========================================"
Write-Host " agentbox-bench v$BENCH_VERSION platform=host" -ForegroundColor Cyan
Write-Host "========================================"
Write-Host " JSONL-Out:     $outFile"
Write-Host " HTML-Out:      $htmlOut"
Write-Host " TEMP-Location: $tmp ($tmpDrive)"

# --- 1. Network: 100 MB download mit Multi-URL-Fallback ---
Write-Host ""
Write-Host "[1/5] Netzwerk: 100 MB download..."

function Test-Download {
    param([string]$Url, [string]$OutPath)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $info = & curl.exe -sS -L --max-time 90 `
        -o $OutPath `
        -w "http_code=%{http_code}`nsize_download=%{size_download}`nspeed_download=%{speed_download}`n" `
        $Url 2>&1
    $sw.Stop()
    $curlExit = $LASTEXITCODE
    $result = [ordered]@{ url=$Url; exit_code=$curlExit; http_code=0; size_bytes=0; mbs=0; error=$null }
    if ($info) {
        foreach ($line in ($info | ForEach-Object { "$_" })) {
            if ($line -match '^http_code=(\d+)')        { $result.http_code  = [int]$Matches[1] }
            elseif ($line -match '^size_download=(\d+)'){ $result.size_bytes = [long]$Matches[1] }
        }
        $result.error = (@($info) | Where-Object { $_ -notmatch '^(http_code|size_download|speed_download)=' } | Select-Object -First 1)
    }
    if ($curlExit -eq 0 -and $result.http_code -ge 200 -and $result.http_code -lt 400 -and $result.size_bytes -gt 1000) {
        $result.mbs = [Math]::Round(($result.size_bytes / 1MB) / $sw.Elapsed.TotalSeconds, 2)
    }
    return $result
}

$urlsToTry = @()
if ($env:BENCH_URL) {
    $urlsToTry += $env:BENCH_URL
} else {
    $urlsToTry = @(
        "https://cachefly.cachefly.net/100mb.test",
        "https://proof.ovh.net/files/100Mb.dat",
        "https://speed.cloudflare.com/__down?bytes=104857600"
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
Write-Host "   -> $netMbs MB/s"

# --- 2. Disk: Sequential write 1 GB ---
Write-Host ""
Write-Host "[2/5] Disk seq write: 1 GB nach $tmp (NTFS)..."
$diskFile = Join-Path $tmp "bench_disk.bin"
$buf      = New-Object byte[] (1MB)
$sw       = [Diagnostics.Stopwatch]::StartNew()
$fs       = [IO.File]::Create($diskFile)
for ($i = 0; $i -lt 1024; $i++) { $fs.Write($buf, 0, $buf.Length) }
$fs.Flush($true); $fs.Close()
$sw.Stop()
Remove-Item $diskFile -Force
$seqWriteMbs = [Math]::Round(1024 / $sw.Elapsed.TotalSeconds, 2)
Write-Host "   -> $seqWriteMbs MB/s"

# --- 3. Disk: 10'000 small files ---
Write-Host ""
Write-Host "[3/5] Disk small-files: 10'000 x 4 B ..."
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
$smallFilesPerS = [int][Math]::Round(10000 / $sw.Elapsed.TotalSeconds, 0)
Write-Host "   -> $smallFilesPerS files/s"

# --- 4. CPU: SHA256 ueber 500 MB Nullen ---
Write-Host ""
Write-Host "[4/5] CPU: SHA256 von 500 MB Nullen ..."
$cpuBuf = New-Object byte[] (500 * 1MB)
$sha    = [System.Security.Cryptography.SHA256]::Create()
$sw     = [Diagnostics.Stopwatch]::StartNew()
$null   = $sha.ComputeHash($cpuBuf)
$sw.Stop()
$sha.Dispose(); $cpuBuf = $null
$cpuMbs = [Math]::Round(500 / $sw.Elapsed.TotalSeconds, 2)
Write-Host "   -> $cpuMbs MB/s"

# --- 5. Process spawn: 500 x cmd /c exit ---
Write-Host ""
Write-Host "[5/5] Process spawn: 500 x cmd /c exit ..."
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = "cmd.exe"; $psi.Arguments = "/c exit"
$psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
$sw = [Diagnostics.Stopwatch]::StartNew()
for ($i = 1; $i -le 500; $i++) {
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.WaitForExit(); $p.Dispose()
}
$sw.Stop()
$spawnPerS = [int][Math]::Round(500 / $sw.Elapsed.TotalSeconds, 0)
Write-Host "   -> $spawnPerS procs/s"

# --- JSONL append ---
$record = [ordered]@{
    timestamp                = $stamp
    platform                 = "host"
    version                  = $BENCH_VERSION
    net_mbs                  = $netMbs
    net_url                  = $netUrlUsed
    disk_seq_mbs             = $seqWriteMbs
    disk_small_files_per_s   = $smallFilesPerS
    cpu_sha256_mbs           = $cpuMbs
    proc_spawn_per_s         = $spawnPerS
}
$json = ConvertTo-Json $record -Compress

Write-Host ""
Write-Host "========================================"
Write-Host " Ergebnis (an $outFile angehaengt)"
Write-Host "========================================"
Write-Host $json

try {
    $outDir = Split-Path -Parent $outFile
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
        [System.IO.Directory]::CreateDirectory($outDir) | Out-Null
    }
    [IO.File]::AppendAllText($outFile, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
} catch {
    Write-Host "[WARN] JSONL-Append fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Yellow
}

# --- BUILD: index.html mit Durchschnitten + Wirkungsgrad generieren ---
Write-Host ""
Write-Host "========================================"
Write-Host " Build: index.html generieren" -ForegroundColor Cyan
Write-Host "========================================"

function Avg($values) {
    $vals = @($values | Where-Object { $_ -ne $null })
    if ($vals.Count -eq 0) { return $null }
    return [Math]::Round(($vals | Measure-Object -Average).Average, 2)
}
function Ratio($s, $h) {
    # Wirkungsgrad = host / sandbox, gedeckelt auf 100 %.
    if (-not $s -or -not $h -or $s -eq 0) { return $null }
    $r = $h / $s
    if ($r -gt 1) { $r = 1 }
    return [Math]::Round($r * 100, 1)
}
function Cell($v, $unit) {
    if ($v -eq $null) { return "<td class=na>n/a</td>" }
    return "<td>$v <span class=u>$unit</span></td>"
}
function Pct($v) {
    if ($v -eq $null) { return "<td class=na>n/a</td>" }
    $cls = if ($v -ge 100) { "good" } elseif ($v -ge 50) { "ok" } else { "bad" }
    return "<td class=$cls>$v %</td>"
}

$runs = @()
if (Test-Path $outFile) {
    $runs = Get-Content $outFile | Where-Object { $_.Trim() -ne "" } | ForEach-Object { $_ | ConvertFrom-Json }
}
$host_runs = @($runs | Where-Object { $_.platform -eq "host" })
$sand_runs = @($runs | Where-Object { $_.platform -eq "sandbox" })

$h_net = Avg ($host_runs.net_mbs);   $s_net = Avg ($sand_runs.net_mbs)
$h_seq = Avg ($host_runs.disk_seq_mbs); $s_seq = Avg ($sand_runs.disk_seq_mbs)
$h_sml = Avg ($host_runs.disk_small_files_per_s); $s_sml = Avg ($sand_runs.disk_small_files_per_s)
$h_cpu = Avg ($host_runs.cpu_sha256_mbs); $s_cpu = Avg ($sand_runs.cpu_sha256_mbs)
$h_spw = Avg ($host_runs.proc_spawn_per_s); $s_spw = Avg ($sand_runs.proc_spawn_per_s)

$rows = @"
<tr><td>Netzwerk-Download</td>$(Cell $h_net "MB/s")$(Cell $s_net "MB/s")$(Pct (Ratio $s_net $h_net))</tr>
<tr><td>Disk seq write (1 GB)</td>$(Cell $h_seq "MB/s")$(Cell $s_seq "MB/s")$(Pct (Ratio $s_seq $h_seq))</tr>
<tr><td>Disk small files (10'000 x 4 B)</td>$(Cell $h_sml "files/s")$(Cell $s_sml "files/s")$(Pct (Ratio $s_sml $h_sml))</tr>
<tr><td>CPU SHA256 (500 MB)</td>$(Cell $h_cpu "MB/s")$(Cell $s_cpu "MB/s")$(Pct (Ratio $s_cpu $h_cpu))</tr>
<tr><td>Process spawn (500 procs)</td>$(Cell $h_spw "procs/s")$(Cell $s_spw "procs/s")$(Pct (Ratio $s_spw $h_spw))</tr>
"@

$html = @"
<!doctype html>
<html lang=de>
<meta charset=utf-8>
<title>agentbox-bench Wirkungsgrad</title>
<style>
body{font:14px/1.5 system-ui,sans-serif;max-width:780px;margin:2rem auto;padding:0 1rem;color:#222}
h1{margin-bottom:.2rem}
.sub{color:#666;margin-bottom:1.5rem}
table{width:100%;border-collapse:collapse;margin-bottom:1rem}
th,td{padding:.5rem .7rem;border-bottom:1px solid #ddd;text-align:right}
th:first-child,td:first-child{text-align:left}
th{background:#f4f4f4;font-weight:600}
.u{color:#888;font-size:.85em}
.na{color:#bbb}
.good{background:#d4f4d4;font-weight:600}
.ok{background:#fff4c4;font-weight:600}
.bad{background:#f8d4d4;font-weight:600}
.meta{font-size:.85em;color:#666;margin-top:1.5rem}
</style>
<h1>agentbox-bench &mdash; Wirkungsgrad</h1>
<div class=sub>Durchschnittswerte aus $($host_runs.Count) Host- und $($sand_runs.Count) Sandbox-Lauf/Laeufen. Build: $stamp</div>
<table>
<thead><tr><th>Metrik</th><th>Host (&Oslash;)</th><th>Sandbox (&Oslash;)</th><th>Wirkungsgrad</th></tr></thead>
<tbody>
$rows
</tbody>
</table>
<div class=meta>
Wirkungsgrad = host / sandbox &times; 100&nbsp;%, gedeckelt auf 100&nbsp;%. 100&nbsp;% = Sandbox bremst nicht.<br>
Quelle: <code>bench-results.jsonl</code>. Generiert von <code>bench.ps1</code> beim Build.
</div>
</html>
"@

[IO.File]::WriteAllText($htmlOut, $html, (New-Object System.Text.UTF8Encoding($false)))
Write-Host " -> $htmlOut geschrieben ($($host_runs.Count) Host, $($sand_runs.Count) Sandbox Runs)"
