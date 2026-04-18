#!/usr/bin/env bash
# tools/bench.sh — agentbox Sandbox-Baseline (Linux, ext4 in vhdx, mirrored/NAT)
#
# Paar-Script zu tools/bench.ps1. Beide **appenden** ins selbe
# bench-results.txt (CWD-relativ, ueberschreibbar via $BENCH_OUT).
# Wenn beide in einem agentbox-Projekt-Ordner laufen, teilen sie sich
# dieselbe Datei ueber den Bind-Mount — Host-Run und Sandbox-Run
# stehen dann direkt untereinander in derselben Datei.
#
# Ausfuehrungsreihenfolge:
#   1. Netzwerk: 500 MB download von speed.cloudflare.com/__down
#   2. Disk: 1 GB sequential write mit fdatasync
#   3. Disk: 10'000 kleine Files create (4 Byte each)
#
# Disk-Tests laufen in $BENCH_DIR (Default /tmp = ext4 in vhdx, Fast-Path).
# Fuer DrvFs-Messung: BENCH_DIR=/workspace/src bash tools/bench.sh

set -u

BENCH_DIR="${BENCH_DIR:-/tmp}"
BENCH_OUT="${BENCH_OUT:-$(pwd)/bench-results.txt}"
STAMP=$(date -Iseconds 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')
HEADER="# ======== $STAMP | platform=sandbox | bench_dir=$BENCH_DIR ========"

FS_HINT=""
if [ "$BENCH_DIR" = "/tmp" ]; then FS_HINT=" (ext4 in vhdx)"; fi
case "$BENCH_DIR" in
    /workspace/*) FS_HINT=" (DrvFs bzw. ext4-overlay)";;
esac

echo "========================================"
echo " agentbox-bench v1 platform=sandbox"
echo "========================================"
echo " Output-Datei: $BENCH_OUT"

# --- 1. Network ---
echo ""
echo "[1/3] Netzwerk: 500 MB download von speed.cloudflare.com..."
NET_URL="https://speed.cloudflare.com/__down?bytes=524288000"
NET_FILE="/tmp/bench_net.bin"
NET_SPEED_BPS=$(curl -s -o "$NET_FILE" -L --max-time 120 \
    -w "%{speed_download}" "$NET_URL" 2>/dev/null || echo "0")
rm -f "$NET_FILE"
NET_MBS=$(awk -v b="$NET_SPEED_BPS" 'BEGIN{printf "%.2f", b/1048576}')
echo "   -> $NET_MBS MB/s"

# --- 2. Disk seq write ---
echo ""
echo "[2/3] Disk seq write: 1 GB nach $BENCH_DIR$FS_HINT ..."
DISK_FILE="$BENCH_DIR/bench_disk.bin"
DD_OUT=$(dd if=/dev/zero of="$DISK_FILE" bs=1M count=1024 conv=fdatasync 2>&1 | tail -1)
rm -f "$DISK_FILE"
# dd-Output-Parsen: "... 2.34 s, 459 MB/s" oder "... 1.2 GB/s"
SEQ_WRITE_MBS=$(echo "$DD_OUT" \
    | grep -oE '[0-9.]+ [MG]B/s' \
    | tail -1 \
    | awk '{if ($2=="GB/s") printf "%.2f", $1*1024; else printf "%.2f", $1}')
[ -z "$SEQ_WRITE_MBS" ] && SEQ_WRITE_MBS="0"
echo "   -> $SEQ_WRITE_MBS MB/s"

# --- 3. Disk: 10'000 small files ---
echo ""
echo "[3/3] Disk small-files: 10'000 x 4 B in $BENCH_DIR$FS_HINT ..."
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

# --- Summary (stdout + append an bench-results.txt) ---
SUMMARY="$HEADER
agentbox-bench v1 platform=sandbox
net_download_mbs=$NET_MBS
disk_seq_write_mbs=$SEQ_WRITE_MBS
disk_small_files_per_s=$SMALL_FILES_PER_S
"
echo ""
echo "========================================"
echo " Ergebnis (auch angehaengt an $BENCH_OUT)"
echo "========================================"
printf '%s\n' "$SUMMARY"

OUT_DIR=$(dirname "$BENCH_OUT")
mkdir -p "$OUT_DIR" 2>/dev/null || true
if ! printf '%s' "$SUMMARY" >> "$BENCH_OUT" 2>/dev/null; then
    echo "[WARN] Konnte nicht an $BENCH_OUT anhaengen." >&2
fi
