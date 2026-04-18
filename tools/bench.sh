#!/usr/bin/env bash
# bench.sh v3.0.0 - agentbox Sandbox-Baseline (Linux, ext4 in vhdx)
#
# Paar-Script zu bench.ps1. Beide schreiben in dasselbe bench-results.json,
# aber **strict overwrite** pro Seite: diese .sh mergt ihren Run in
# .sandbox, bench.ps1 in .host. Identische Workloads auf beiden Seiten
# -> Wirkungsgrad = sandbox / host (berechnet und gerendert in .ps1).
#
# Tests:
#   1. Netzwerk: 100 MB download (Multi-URL-Fallback, gleiche Reihenfolge wie .ps1)
#   2. Disk: 1 GB sequential write mit fdatasync
#   3. Disk: 10'000 kleine Files create (4 Byte each)
#   4. CPU:  SHA256 ueber 500 MB Nullen (single-thread)
#   5. Prozesse: 500 x /bin/true (fork+exec Overhead)
#
# Disk-Tests laufen in $BENCH_DIR (Default /tmp = ext4 in vhdx, Fast-Path).
# Fuer DrvFs-Messung: BENCH_DIR=/workspace/src bash src/bench.sh
#
# Kein HTML, kein Browser-Trigger - das ist Host-Sache (bench.ps1).

set -u

BENCH_VERSION="3.0.0"
BENCH_DIR="${BENCH_DIR:-/tmp}"
BENCH_OUT="${BENCH_OUT:-$(pwd)/bench-results.json}"
STAMP=$(date -Iseconds 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')

FS_HINT=""
[ "$BENCH_DIR" = "/tmp" ] && FS_HINT=" (ext4 in vhdx)"
case "$BENCH_DIR" in
    /workspace/*) FS_HINT=" (DrvFs bzw. ext4-overlay)";;
esac

echo "========================================"
echo " agentbox-bench v$BENCH_VERSION platform=sandbox"
echo "========================================"
echo " JSON-Out: $BENCH_OUT"

# --- 1. Network: 100 MB download mit Multi-URL-Fallback ---
echo ""
echo "[1/5] Netzwerk: 100 MB download..."
NET_FILE="/tmp/bench_net.bin"
URLS=(
  "https://cachefly.cachefly.net/100mb.test"
  "https://proof.ovh.net/files/100Mb.dat"
  "https://speed.cloudflare.com/__down?bytes=104857600"
)
[ -n "${BENCH_URL:-}" ] && URLS=("$BENCH_URL")

NET_MBS="0.00"
NET_URL=""
for u in "${URLS[@]}"; do
  echo "   Versuche: $u"
  rm -f "$NET_FILE"
  out=$(curl -sS -L --max-time 90 -o "$NET_FILE" \
    -w "http_code=%{http_code} size=%{size_download} speed=%{speed_download}" \
    "$u" 2>&1) || true
  http=$(echo "$out" | grep -oE 'http_code=[0-9]+' | cut -d= -f2)
  size=$(echo "$out" | grep -oE 'size=[0-9]+' | cut -d= -f2)
  speed=$(echo "$out" | grep -oE 'speed=[0-9.]+' | cut -d= -f2)
  http="${http:-0}"
  size="${size:-0}"
  speed="${speed:-0}"
  if [ "$http" -ge 200 ] && [ "$http" -lt 400 ] && [ "$size" -gt 1000 ]; then
    NET_MBS=$(awk -v b="$speed" 'BEGIN{printf "%.2f", b/1048576}')
    NET_URL="$u"
    echo "   [OK] http=$http size=${size}B speed=$NET_MBS MB/s"
    break
  else
    echo "   [FAIL] http=$http size=$size"
  fi
done
rm -f "$NET_FILE"
echo "   -> $NET_MBS MB/s"

# --- 2. Disk seq write: 1 GB ---
echo ""
echo "[2/5] Disk seq write: 1 GB nach $BENCH_DIR$FS_HINT ..."
DISK_FILE="$BENCH_DIR/bench_disk.bin"
DD_OUT=$(dd if=/dev/zero of="$DISK_FILE" bs=1M count=1024 conv=fdatasync 2>&1 | tail -1)
rm -f "$DISK_FILE"
SEQ_WRITE_MBS=$(echo "$DD_OUT" \
    | grep -oE '[0-9.]+ [MG]B/s' \
    | tail -1 \
    | awk '{if ($2=="GB/s") printf "%.2f", $1*1024; else printf "%.2f", $1}')
[ -z "$SEQ_WRITE_MBS" ] && SEQ_WRITE_MBS="0"
echo "   -> $SEQ_WRITE_MBS MB/s"

# --- 3. Disk small files: 10'000 x 4 B ---
echo ""
echo "[3/5] Disk small-files: 10'000 x 4 B in $BENCH_DIR$FS_HINT ..."
SMALL_DIR="$BENCH_DIR/bench_small_$$"
rm -rf "$SMALL_DIR"
mkdir -p "$SMALL_DIR"
START=$(date +%s.%N)
for i in $(seq 1 10000); do
    echo -n "x" > "$SMALL_DIR/f_$i.txt"
done
END=$(date +%s.%N)
rm -rf "$SMALL_DIR"
ELAPSED=$(awk "BEGIN{printf \"%.3f\", $END - $START}")
SMALL_FILES_PER_S=$(awk "BEGIN{printf \"%d\", 10000 / $ELAPSED}")
echo "   -> $SMALL_FILES_PER_S files/s (in ${ELAPSED}s)"

# --- 4. CPU: SHA256 von 500 MB Nullen (rein in-memory, fair vs .NET) ---
echo ""
echo "[4/5] CPU: SHA256 von 500 MB Nullen (in-memory) ..."
CPU_ELAPSED=$(python3 -c "
import hashlib, time
data = bytes(524288000)
t = time.perf_counter()
hashlib.sha256(data).digest()
print(f'{time.perf_counter() - t:.4f}')
")
CPU_MBS=$(awk "BEGIN{printf \"%.2f\", 500 / $CPU_ELAPSED}")
echo "   -> $CPU_MBS MB/s (in ${CPU_ELAPSED}s)"

# --- 5. Process spawn: 500 x /bin/true ---
echo ""
echo "[5/5] Process spawn: 500 x /bin/true ..."
START=$(date +%s.%N)
for i in $(seq 1 500); do /bin/true; done
END=$(date +%s.%N)
SPAWN_ELAPSED=$(awk "BEGIN{printf \"%.3f\", $END - $START}")
SPAWN_PER_S=$(awk "BEGIN{printf \"%d\", 500 / $SPAWN_ELAPSED}")
echo "   -> $SPAWN_PER_S procs/s (in ${SPAWN_ELAPSED}s)"

# --- JSON merge: .sandbox-Seite ueberschreiben, .host bleibt erhalten ---
# python3 ist im Sandbox-Template garantiert (wird oben schon fuer SHA256
# verwendet) - daher kein jq-Fallback noetig.
OUT_DIR=$(dirname "$BENCH_OUT")
mkdir -p "$OUT_DIR" 2>/dev/null || true

python3 - "$BENCH_OUT" <<PYEOF
import json, os, sys

out_path = sys.argv[1]
existing = {}
if os.path.exists(out_path):
    try:
        with open(out_path, 'r', encoding='utf-8') as f:
            raw = f.read().strip()
        if raw:
            existing = json.loads(raw)
    except Exception as e:
        print(f"[WARN] bestehende JSON konnte nicht gelesen werden, ueberschreibe: {e}", file=sys.stderr)
        existing = {}

if not isinstance(existing, dict):
    existing = {}

existing["sandbox"] = {
    "timestamp": "$STAMP",
    "platform": "sandbox",
    "version": "$BENCH_VERSION",
    "net_mbs": float("$NET_MBS") if "$NET_MBS" else 0.0,
    "net_url": "$NET_URL",
    "disk_seq_mbs": float("$SEQ_WRITE_MBS") if "$SEQ_WRITE_MBS" else 0.0,
    "disk_small_files_per_s": int("$SMALL_FILES_PER_S") if "$SMALL_FILES_PER_S" else 0,
    "cpu_sha256_mbs": float("$CPU_MBS") if "$CPU_MBS" else 0.0,
    "proc_spawn_per_s": int("$SPAWN_PER_S") if "$SPAWN_PER_S" else 0,
}

with open(out_path, 'w', encoding='utf-8') as f:
    json.dump(existing, f, indent=2, ensure_ascii=False)
    f.write("\n")

print(json.dumps(existing["sandbox"], ensure_ascii=False))
PYEOF

echo ""
echo "========================================"
echo " Ergebnis in $BENCH_OUT (Schluessel .sandbox)"
echo "========================================"
