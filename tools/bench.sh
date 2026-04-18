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
#   1. Netzwerk: 500 MB download (Default: speed.cloudflare.com/__down).
#      Ueber $BENCH_URL aenderbar, falls der Upstream-SNI-Filter die
#      Subdomain blockt. Probiert bei Fehlschlag automatisch zwei
#      Fallback-URLs (registry.npmjs.org, OVH).
#   2. Disk: 1 GB sequential write mit fdatasync
#   3. Disk: 10'000 kleine Files create (mit Progress alle 1000)
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
echo " Disk-Bench-Dir: $BENCH_DIR$FS_HINT"

# --- 1. Network ---
echo ""
echo "[1/3] Netzwerk: 500 MB download..."

# URL-Liste: BENCH_URL ueberschreibt alles, sonst Cloudflare → npm → OVH.
if [ -n "${BENCH_URL:-}" ]; then
    URL_LIST=("$BENCH_URL")
else
    URL_LIST=(
        "https://speed.cloudflare.com/__down?bytes=524288000"
        "https://registry.npmjs.org/react/-/react-18.3.1.tgz"
        "https://proof.ovh.net/files/100Mb.dat"
    )
fi

NET_FILE="/tmp/bench_net.bin"
NET_MBS="0"
NET_URL_USED=""
for U in "${URL_LIST[@]}"; do
    echo "   Versuche: $U"
    CURL_OUT=$(curl -sS -L --max-time 120 \
        -o "$NET_FILE" \
        -w "http_code=%{http_code}\nsize_download=%{size_download}\nspeed_download=%{speed_download}\n" \
        "$U" 2>&1)
    CURL_EXIT=$?
    HTTP_CODE=$(echo "$CURL_OUT" | grep -oE '^http_code=[0-9]+'       | head -1 | cut -d= -f2)
    SIZE_BYTES=$(echo "$CURL_OUT" | grep -oE '^size_download=[0-9]+'  | head -1 | cut -d= -f2)
    SPEED_BPS=$(echo "$CURL_OUT" | grep -oE '^speed_download=[0-9.]+' | head -1 | cut -d= -f2)
    HTTP_CODE="${HTTP_CODE:-0}"
    SIZE_BYTES="${SIZE_BYTES:-0}"
    SPEED_BPS="${SPEED_BPS:-0}"
    rm -f "$NET_FILE"
    if [ "$CURL_EXIT" -eq 0 ] && [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 400 ] && [ "$SIZE_BYTES" -gt 0 ]; then
        NET_MBS=$(awk -v b="$SPEED_BPS" 'BEGIN{printf "%.2f", b/1048576}')
        NET_URL_USED="$U"
        echo "   [OK] $SIZE_BYTES Bytes, HTTP $HTTP_CODE, $NET_MBS MB/s"
        break
    else
        # Erste nicht-key=value-Zeile als Fehlerhinweis.
        ERR_MSG=$(echo "$CURL_OUT" | grep -vE '^(http_code|size_download|speed_download)=' | head -1)
        echo "   [FAIL] exit=$CURL_EXIT, http=$HTTP_CODE, size=$SIZE_BYTES ${ERR_MSG:+— $ERR_MSG}"
    fi
done
if [ "$NET_MBS" = "0" ] || [ "$NET_MBS" = "0.00" ]; then
    echo "   [WARN] Alle Download-Ziele fehlgeschlagen — SNI-Filter oder offline."
    echo "          Override: BENCH_URL=https://dein-allowlisted-host/grosse-datei bash tools/bench.sh"
fi
echo "   -> $NET_MBS MB/s"

# --- 2. Disk seq write ---
echo ""
echo "[2/3] Disk seq write: 1 GB nach $BENCH_DIR$FS_HINT ..."
DISK_FILE="$BENCH_DIR/bench_disk.bin"
DD_OUT=$(dd if=/dev/zero of="$DISK_FILE" bs=1M count=1024 conv=fdatasync 2>&1 | tail -1)
rm -f "$DISK_FILE"
SEQ_WRITE_MBS=$(echo "$DD_OUT" \
    | grep -oE '[0-9.]+ [MG]B/s' \
    | tail -1 \
    | awk '{if ($2=="GB/s") printf "%.2f", $1*1024; else printf "%.2f", $1}')
[ -z "$SEQ_WRITE_MBS" ] && SEQ_WRITE_MBS="0"
echo "   -> $SEQ_WRITE_MBS MB/s"

# --- 3. Disk: 10'000 small files (mit Progress) ---
echo ""
echo "[3/3] Disk small-files: 10'000 x 4 B in $BENCH_DIR$FS_HINT (Progress alle 1000)..."
SMALL_DIR="$BENCH_DIR/bench_small_$$"
rm -rf "$SMALL_DIR"
mkdir -p "$SMALL_DIR"
START=$(date +%s.%N)
for i in $(seq 1 10000); do
    echo -n "x" > "$SMALL_DIR/f_$i.txt"
    if [ $((i % 1000)) -eq 0 ]; then
        NOW=$(date +%s.%N)
        CUR=$(awk "BEGIN{printf \"%d\", $i / ($NOW - $START)}")
        echo "   ... $i / 10000 ($CUR files/s)"
    fi
done
END=$(date +%s.%N)
rm -rf "$SMALL_DIR"
ELAPSED=$(awk "BEGIN{printf \"%.3f\", $END - $START}")
SMALL_FILES_PER_S=$(awk "BEGIN{printf \"%d\", 10000 / $ELAPSED}")
echo "   -> $SMALL_FILES_PER_S files/s (in ${ELAPSED}s)"

# --- Summary ---
SUMMARY="$HEADER
agentbox-bench v1 platform=sandbox
net_download_mbs=$NET_MBS
net_url=$NET_URL_USED
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
