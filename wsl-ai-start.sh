#!/bin/bash
# wsl-ai-start.sh
# agentbox — Agent/Projekt-Auswahl und Sandbox-Lifecycle
# Laeuft in der normalen Host-WSL
# Version: 3.2

set -euo pipefail

# --- Modus-Erkennung ---
# Argumente werden hier nur eingesammelt; die Modi --list-sessions und
# --compare lesen aus SESSIONS_DIR, welches erst nach
# _resolve_agentbox_local_root (unten) definiert ist. Deshalb Ausfuehrung
# deferred — siehe "--- Deferred Modi ---" weiter unten.
AUTO_MODE=false
REPLAY_SESSION=""
LIST_SESSIONS_MODE=false
COMPARE_MODE=false
COMPARE_SESSIONS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --auto)
            AUTO_MODE=true
            shift
            ;;
        --replay)
            REPLAY_SESSION="${2:-}"
            if [ -z "$REPLAY_SESSION" ]; then
                # Frueh im Script (vor lib/log.sh-Source): plain echo + >&2
                echo "FEHLER: --replay braucht eine Session-ID." >&2
                echo "Verfuegbare Sessions: agentbox --list-sessions" >&2
                exit 1
            fi
            shift 2
            ;;
        --list-sessions)
            LIST_SESSIONS_MODE=true
            shift
            ;;
        --compare)
            COMPARE_MODE=true
            COMPARE_SESSIONS=("${2:-}" "${3:-}")
            if [ -z "${COMPARE_SESSIONS[0]}" ] || [ -z "${COMPARE_SESSIONS[1]}" ]; then
                echo "FEHLER: --compare braucht zwei Session-IDs." >&2
                echo "Verwendung: agentbox --compare <session1> <session2>" >&2
                exit 1
            fi
            shift 3
            ;;
        *)
            shift
            ;;
    esac
done

# --- Auto-Modus (aus .bashrc) ---
# Kein Prompt: wer agentbox-host per Shortcut/`wsl -d agentbox-host -e bash
# -li -c agentbox` oeffnet, will starten — nicht gefragt werden. Der
# "agentbox starten? [J/n]"-Countdown war redundant und hat den Start
# jedes Mal um auto_start_timeout Sekunden verzoegert.
# Fuer Plain-Shell ohne agentbox: `wsl -d agentbox-host --cd ~`.
if [ "$AUTO_MODE" = true ]; then
    echo ""
fi

# --- Konfiguration ---
AI_PROJECTS_ROOT="${AI_PROJECTS_ROOT:-}"
if [ -z "$AI_PROJECTS_ROOT" ]; then
    # Frueh im Script (vor lib/log.sh-Source): plain echo + >&2
    echo "FEHLER: AI_PROJECTS_ROOT ist nicht gesetzt." >&2
    echo "Bitte zuerst install.ps1 ausfuehren." >&2
    exit 1
fi

CONTROL_DIR="$AI_PROJECTS_ROOT/_control"

# --- Farben + log_*-Helper aus gemeinsamer Library laden (single source) ---
# Frueh geladen, damit alle FEHLER-/WARN-Pfade ab hier die gleichen Helper
# nutzen (seit 2.0.14: log_warn/log_error schreiben auf stderr). Die noch
# frueheren Pfade (argparse + AI_PROJECTS_ROOT-Check) arbeiten mit plain
# `echo "FEHLER: ..." >&2` — log.sh braucht CONTROL_DIR, das ist dort noch
# nicht verfuegbar.
# Inline-Fallback fuer Pre-2.0.5-Upgrades bleibt als Kompatibilitaetsnetz.
if [ -f "$CONTROL_DIR/lib/log.sh" ]; then
    . "$CONTROL_DIR/lib/log.sh"
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    NC='\033[0m'
    log_info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
    log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
    log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
    log_error() { echo -e "${RED}[FEHLER]${NC} $1" >&2; }
fi

# --- config.json laden ---
CONFIG_LIB="$CONTROL_DIR/lib/config.sh"
if [ -f "$CONFIG_LIB" ]; then
    # Preflight gegen OneDrive-Files-On-Demand: wenn _control/ in OneDrive
    # liegt (Default-Setup) und OneDrive nicht laeuft, sind nicht-kuerzlich-
    # angefasste Dateien nur als Cloud-Placeholder vorhanden. WSL's /mnt/c-
    # Bridge kann solche Placeholder nicht on-demand hydraten — der `source`
    # crasht dann mit "Input/output error" und eine kryptische Meldung
    # landet beim User (User-Report 1.0.24, Schueler-OneDrive).
    # Vor dem source einmal probelesen; wenn das scheitert, geben wir eine
    # klare Anleitung aus statt den Fehler weiter zu reichen.
    if ! head -c 1 "$CONFIG_LIB" >/dev/null 2>&1; then
        echo "" >&2
        log_error "'$CONFIG_LIB' konnte nicht gelesen werden (I/O error)."
        echo "" >&2
        case "$CONFIG_LIB" in
            /mnt/c/*[Oo]ne[Dd]rive*)
                echo "Wahrscheinliche Ursache: OneDrive Files-On-Demand." >&2
                echo "Die Datei ist nur als Cloud-Placeholder vorhanden, und OneDrive" >&2
                echo "scheint nicht zu laufen — WSL kann sie nicht transparent holen." >&2
                echo "" >&2
                echo "Fix (einmalig):" >&2
                echo "  1) OneDrive starten (Startmenue -> OneDrive)" >&2
                echo "     ODER" >&2
                echo "  2) Im Windows Explorer rechtsklick auf den _control-Ordner" >&2
                echo "     -> 'Immer auf diesem Geraet behalten' (gruener Haken)" >&2
                echo "  3) agentbox nochmal starten" >&2
                ;;
            *)
                echo "Pfad liegt nicht in OneDrive — pruefe Dateisystem-Berechtigung" >&2
                echo "oder ob der Storage hinter '$CONFIG_LIB' ueberhaupt gemounted ist." >&2
                ;;
        esac
        echo "" >&2
        exit 1
    fi
    . "$CONFIG_LIB"
fi

# base_path_override anwenden
_base_override=$(cfg_get "base_path_override" "")
if [ -n "$_base_override" ]; then
    # Windows-Pfad in Linux-Pfad konvertieren falls noetig
    if [[ "$_base_override" == *\\* ]] || [[ "$_base_override" == *:* ]]; then
        AI_PROJECTS_ROOT=$(wslpath -u "$_base_override" 2>/dev/null || echo "$_base_override")
    else
        AI_PROJECTS_ROOT="$_base_override"
    fi
    # Trailing Slashes entfernen
    AI_PROJECTS_ROOT="${AI_PROJECTS_ROOT%/}"
    CONTROL_DIR="$AI_PROJECTS_ROOT/$(cfg_get 'control_dir_name' '_control')"
fi

TEMPLATE_PATH_OLD="$CONTROL_DIR/sandbox/template.tar.gz"
SANDBOX_INIT="$CONTROL_DIR/wsl-sandbox-init.sh"
TYPE_DEFAULTS="$CONTROL_DIR/type_defaults.json"
AGENTBOX_CONFIG="$CONTROL_DIR/config.json"

# --- Runtime-State unter %LOCALAPPDATA%\agentbox\ aufloesen ---
# Template (~1 GB), Paket-Cache, Session-Snapshots und Auth-State gehoeren
# nicht in den OneDrive-synchronisierten CONTROL_DIR. Gleiche Regel wie
# fuer ~/.claude/: lokal, user-privat, kein Cloud-Sync. Der Host-Distro-
# Ordner liegt bereits dort (install.ps1 Import-AgentboxHostDistro).
#
# Die Aufloesung von %LOCALAPPDATA% ist tueckisch, wenn der Windows-User
# einen Umlaut im Namen hat (z.B. "Schueler"):
# - cmd.exe schreibt seinen Output in der OEM-Codepage (cp850 in DE, NICHT
#   UTF-8). Der "ue" wird als single byte 0x81 ausgegeben, bash interpretiert
#   das als invalid UTF-8 lead byte, und wslpath bekommt einen Garbage-Pfad.
# - powershell.exe kann auf UTF-8 gezwungen werden — bevorzugte Methode.
# - Als finaler Rettungsanker: glob-match auf /mnt/c/Users/*/AppData/Local/
#   agentbox/. Der Ordner muss existieren, weil install.ps1 ihn beim Setup
#   anlegt. Bash globbing nutzt direkt die Filesystem-Bytes, kein Encoding-
#   Roundtrip noetig.
_resolve_agentbox_local_root() {
    local _w _l _candidate

    # Methode 1: PowerShell mit explizitem UTF-8 Output. Robust gegen Umlaute.
    if command -v powershell.exe >/dev/null 2>&1; then
        _w=$(powershell.exe -NoProfile -NonInteractive -Command '[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; Write-Output $env:LOCALAPPDATA' 2>/dev/null | tr -d '\r\n' | tr -d '\000' || true)
        if [ -n "$_w" ]; then
            _l=$(wslpath -u "$_w" 2>/dev/null || true)
            if [ -n "$_l" ] && [ -d "$_l" ]; then
                echo "$_l/agentbox"
                return 0
            fi
        fi
    fi

    # Methode 2: cmd.exe als Fallback. Funktioniert bei ASCII-Usernamen, kann
    # bei Umlauten failen wegen OEM-Codepage-Mismatch.
    _w=$(cmd.exe /c "echo %LOCALAPPDATA%" 2>/dev/null | tr -d '\r\n' | tr -d '\000' || true)
    if [ -n "$_w" ]; then
        _l=$(wslpath -u "$_w" 2>/dev/null || true)
        if [ -n "$_l" ] && [ -d "$_l" ]; then
            echo "$_l/agentbox"
            return 0
        fi
    fi

    # Methode 3: Filesystem-Glob auf /mnt/c/Users/*/AppData/Local/agentbox/.
    # Funktioniert auch mit Umlauten, weil bash-globbing direkt mit den
    # Filesystem-Bytes arbeitet und keinen Windows-CLI-Roundtrip macht. Gilt
    # nur, wenn install.ps1 das agentbox-Verzeichnis bereits angelegt hat.
    # Public/Default/All-Users-Profile ueberspringen — das sind Windows-
    # System-Profile, kein echter User.
    for _candidate in /mnt/c/Users/*/AppData/Local/agentbox; do
        case "$_candidate" in
            */Public/*) continue ;;
            */Default/*) continue ;;
            */Default\ User/*) continue ;;
            */All\ Users/*) continue ;;
        esac
        if [ -d "$_candidate" ]; then
            echo "$_candidate"
            return 0
        fi
    done

    return 1
}
AGENTBOX_LOCAL_ROOT=$(_resolve_agentbox_local_root || echo "")
if [ -z "$AGENTBOX_LOCAL_ROOT" ]; then
    log_error "%LOCALAPPDATA% nicht ermittelbar — Runtime-State nicht lokalisierbar."
    echo "        Versucht wurden:" >&2
    echo "          1) powershell.exe (UTF-8)" >&2
    echo "          2) cmd.exe (OEM-Codepage)" >&2
    echo "          3) glob /mnt/c/Users/*/AppData/Local/agentbox/" >&2
    echo "        Pruefe, ob Windows-Interop in agentbox-host aktiv ist:" >&2
    echo "          ls /mnt/c   # sollte den Windows-C-Drive zeigen" >&2
    echo "          which powershell.exe cmd.exe" >&2
    exit 1
fi
# Root selbst anlegen; die Unter-Ordner NICHT vorab — sonst schlaegt die
# Migration unten fehl (mv src_dir existing_empty_dst = "move src INTO dst",
# nicht "rename src to dst", GNU-Verhalten).
mkdir -p "$AGENTBOX_LOCAL_ROOT" 2>/dev/null || true

TEMPLATE_PATH="$AGENTBOX_LOCAL_ROOT/sandbox/template.tar.gz"
# agentbox 2.0: vhdx-Fastpath. Wenn das Template-Build eine vhdx erzeugt
# hat (WSL 2.0.x+), nutzen wir die fuer Session-Start (Copy + import-in-
# place statt tar.gz-Extract, ~5s statt 30-120s). Fehlt die Datei oder
# versteht die WSL-Installation kein --import-in-place, faellt der
# Start-Pfad transparent auf tar.gz zurueck.
TEMPLATE_VHD_PATH="$AGENTBOX_LOCAL_ROOT/sandbox/template.vhdx"
CACHE_DIR="$AGENTBOX_LOCAL_ROOT/cache"
SESSIONS_DIR="$AGENTBOX_LOCAL_ROOT/sessions"
AUTH_BASE="$AGENTBOX_LOCAL_ROOT/auth"

# --- Einmalige Migration: alte Pfade aus CONTROL_DIR raus ---
# Wer von einer aelteren Version kommt, hat Template/Cache/Sessions noch
# unter _control/ (in OneDrive). Beim ersten Start der neuen Version
# ziehen wir die Dateien einmalig rueber und raeumen die alten Ordner ab.
_migrate_from_control() {
    local _old="$1" _new="$2" _label="$3"
    [ -e "$_old" ] || return 0
    # Neues Ziel schon vorhanden und nicht leer → alte Daten sind veraltet,
    # nur loeschen. Leere Zielordner loeschen, damit `mv` den Source an
    # exact diese Stelle umbenennen kann (statt "INTO existing dir").
    if [ -e "$_new" ]; then
        if [ -n "$(ls -A "$_new" 2>/dev/null)" ]; then
            rm -rf "$_old" 2>/dev/null || true
            return 0
        fi
        rmdir "$_new" 2>/dev/null || true
    fi
    mkdir -p "$(dirname "$_new")"
    if mv "$_old" "$_new" 2>/dev/null; then
        echo "[MIGRATE] $_label: $_old → $_new"
    else
        # mv scheitert z.B. bei OneDrive-Placeholder → cp + rm als Fallback
        if cp -r "$_old" "$_new" 2>/dev/null; then
            rm -rf "$_old" 2>/dev/null || true
            echo "[MIGRATE] $_label (kopiert): $_old → $_new"
        else
            log_warn "Migration $_label fehlgeschlagen — bitte manuell pruefen"
        fi
    fi
}
_migrate_from_control "$CONTROL_DIR/sandbox"  "$AGENTBOX_LOCAL_ROOT/sandbox"  "Template"
_migrate_from_control "$CONTROL_DIR/cache"    "$AGENTBOX_LOCAL_ROOT/cache"    "Cache"
_migrate_from_control "$CONTROL_DIR/sessions" "$AGENTBOX_LOCAL_ROOT/sessions" "Sessions"

# Ziel-Unterordner jetzt anlegen — nach Migration, damit leere Shells
# nicht mit dem Rename-Verhalten kollidieren.
mkdir -p "$AGENTBOX_LOCAL_ROOT/sandbox" "$AGENTBOX_LOCAL_ROOT/cache/npm" \
         "$AGENTBOX_LOCAL_ROOT/cache/pip" "$AGENTBOX_LOCAL_ROOT/sessions" \
         "$AGENTBOX_LOCAL_ROOT/auth" 2>/dev/null || true

# --- Deferred Modi: --list-sessions, --compare ---
# Diese Modi lesen aus $SESSIONS_DIR. Deshalb Ausfuehrung hier, nach
# Path-Resolve + Migration — nicht mehr im Argparse-Loop.
if [ "$LIST_SESSIONS_MODE" = true ]; then
    if [ -d "$SESSIONS_DIR" ] && [ -n "$(ls -A "$SESSIONS_DIR" 2>/dev/null)" ]; then
        echo "=== agentbox Sessions ==="
        for s in "$SESSIONS_DIR"/*/; do
            [ -d "$s" ] || continue
            _sid=$(basename "$s")
            _meta="$s/meta.json"
            if [ -f "$_meta" ] && command -v python3 &> /dev/null; then
                _info=$(python3 -c "
import json
with open('$_meta') as f:
    d = json.load(f)
print(f\"  {d.get('id','?'):20s}  {d.get('agent','?'):15s}  {d.get('project','?'):15s}  {d.get('timestamp','?')}\")
" 2>/dev/null || echo "  $_sid")
                echo "$_info"
            else
                echo "  $_sid"
            fi
        done
    else
        echo "Keine Sessions vorhanden."
    fi
    exit 0
fi

if [ "$COMPARE_MODE" = true ]; then
    _s1="$SESSIONS_DIR/${COMPARE_SESSIONS[0]}"
    _s2="$SESSIONS_DIR/${COMPARE_SESSIONS[1]}"

    if [ ! -d "$_s1" ] || [ ! -d "$_s2" ]; then
        log_error "Session nicht gefunden."
        [ ! -d "$_s1" ] && echo "  Nicht gefunden: ${COMPARE_SESSIONS[0]}" >&2
        [ ! -d "$_s2" ] && echo "  Nicht gefunden: ${COMPARE_SESSIONS[1]}" >&2
        exit 1
    fi

    # Meta-Infos lesen
    for _sd in "$_s1" "$_s2"; do
        _meta="$_sd/meta.json"
        if [ -f "$_meta" ] && command -v python3 &> /dev/null; then
            python3 -c "
import json
with open('$_meta') as f:
    d = json.load(f)
print(f\"Session: {d.get('id','')}  Agent: {d.get('agent','')}  Projekt: {d.get('project','')}  Zeit: {d.get('timestamp','')}\")
" 2>/dev/null
        fi
    done

    echo ""
    echo "=== Diff-Vergleich ==="
    echo ""

    if [ -f "$_s1/changes.diff" ] && [ -f "$_s2/changes.diff" ]; then
        diff --color=auto -u \
            --label "${COMPARE_SESSIONS[0]}" "$_s1/changes.diff" \
            --label "${COMPARE_SESSIONS[1]}" "$_s2/changes.diff" \
            || true
    else
        echo "Keine Diffs vorhanden — wurde die Session mit Snapshot gestartet?"
    fi
    exit 0
fi

# Einmaliges Cleanup alter Desktop-Shortcut-Namen (1.0.17 hat auf EINEN
# gemeinsamen `agentbox`-Shortcut konsolidiert — die separaten Installer/
# Update-Shortcuts sind damit obsolet). Via powershell.exe-Interop statt
# /mnt/c/Users/..., weil cmd.exe bzw. /mnt/c-Pfade bei Umlaut-Usernamen
# stolpern. Marker-Datei verhindert, dass der Check bei jedem Start
# laeuft — nur einmal pro Rechner, dann nie wieder.
_legacy_shortcut_marker="$AGENTBOX_LOCAL_ROOT/.legacy-shortcut-cleaned"
if [ ! -f "$_legacy_shortcut_marker" ] && command -v powershell.exe &> /dev/null; then
    powershell.exe -NoProfile -Command \
        "\$d=[Environment]::GetFolderPath('Desktop'); foreach(\$n in 'agentbox-installer.lnk','agentbox-update.lnk'){\$p=Join-Path \$d \$n; if(Test-Path -LiteralPath \$p){Remove-Item -LiteralPath \$p -Force -ErrorAction SilentlyContinue}}" \
        2>/dev/null || true
    touch "$_legacy_shortcut_marker" 2>/dev/null || true
fi

# --- Hilfsfunktionen ---

# Alle Projektordner unter AI_PROJECTS_ROOT (ohne _control), sortiert
# nach letzter Aenderung (neueste zuerst).
_list_projects_sorted() {
    find "$AI_PROJECTS_ROOT" -maxdepth 1 -mindepth 1 -type d \
        -not -name "_control" -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | cut -d' ' -f2-
}

# Prueft ob eine WSL-Distro mit dem gegebenen Namen registriert ist.
# wsl.exe -l -q liefert UTF-16LE mit NUL-Bytes + CR — beides saeubern.
_wsl_distro_exists() {
    wsl.exe -l -q 2>/dev/null | tr -d '\000\r' | grep -Fxq "$1"
}

# Prueft ob eine WSL-Distro tatsaechlich laeuft (nicht nur registriert).
# Wichtig fuer den Session-Lock: ein abgebrochener wsl --import kann eine
# leere Distro zurueck lassen, die als "exists" zaehlt aber nicht running
# ist — die wollen wir vom Stale-Cleanup aufraeumen lassen, nicht als
# laufende Session interpretieren.
_wsl_distro_running() {
    wsl.exe -l -q --running 2>/dev/null | tr -d '\000\r' | grep -Fxq "$1"
}

# Trap-Cleanup: garantiert, dass die ephemere Sandbox-Distro auf JEDEM
# Exit-Pfad terminiert + unregistered wird — auch wenn der User das
# Terminal hart schliesst (Strg+C, X-Klick, kill -9), der watchdog
# stirbt, oder wsl-sandbox-init.sh mit non-zero exit endet. Ohne Trap
# bleibt die Distro im "running"-Zustand stehen und der Session-Lock
# beim naechsten Start interpretiert sie als laufende Session.
# Idempotent: prueft selbst, ob es etwas zu tun gibt, und schluckt alle
# Fehler. Lebt nur, sobald DISTRO_NAME gesetzt ist (vorher No-Op).
_agentbox_cleanup() {
    local _ec=$?
    if [ -n "${WATCHDOG_PID:-}" ]; then
        kill "$WATCHDOG_PID" 2>/dev/null || true
        wait "$WATCHDOG_PID" 2>/dev/null || true
        WATCHDOG_PID=""
    fi
    if [ -n "${DISTRO_NAME:-}" ] && _wsl_distro_exists "$DISTRO_NAME"; then
        wsl.exe --terminate "$DISTRO_NAME" >/dev/null 2>&1 || true
        wsl.exe --unregister "$DISTRO_NAME" >/dev/null 2>&1 || true
    fi
    # vhdx-Fastpath hinterlaesst die session.vhdx im %TEMP%\agentbox\...\-
    # Ordner, weil `wsl --unregister` bei `--import-in-place`-Distros die
    # Datei nicht loescht (sie gehoert dem User, nicht WSL). Best-effort
    # entfernen; der naechste Start wischt den Ordner ohnehin neu.
    if [ -n "${LINUX_TEMP_DIR:-}" ] && [ -d "$LINUX_TEMP_DIR" ]; then
        rm -f "$LINUX_TEMP_DIR/session.vhdx" 2>/dev/null || true
    fi
    return $_ec
}

# --- Auto-Update pruefen ---
_auto_update=$(cfg_get "auto_update" "true")
_update_interval=$(cfg_get "auto_update_interval_hours" "24")
# Validierung: Intervall muss 1-999 sein
if ! [[ "$_update_interval" =~ ^[0-9]+$ ]] || [ "$_update_interval" -lt 1 ] || [ "$_update_interval" -gt 999 ]; then
    _update_interval=24
fi
_last_check_file="$CONTROL_DIR/.last_update_check"

if [ "$_auto_update" = "true" ]; then
    _do_check=true

    # Intervall pruefen (nicht bei jedem Start)
    if [ -f "$_last_check_file" ]; then
        _last_ts=$(cat "$_last_check_file" 2>/dev/null || echo "0")
        # Sanitierung: nur Ziffern akzeptieren
        if ! [[ "$_last_ts" =~ ^[0-9]+$ ]]; then _last_ts=0; fi
        _now_ts=$(date +%s)
        _interval_sec=$(( _update_interval * 3600 ))
        if [ $(( _now_ts - _last_ts )) -lt "$_interval_sec" ] 2>/dev/null; then
            _do_check=false
        fi
    fi

    if [ "$_do_check" = true ]; then
        # Lokale Version lesen
        _local_version=""
        if [ -f "$CONTROL_DIR/.version" ]; then
            _local_version=$(cat "$CONTROL_DIR/.version" 2>/dev/null | tr -d '[:space:]')
        fi

        # Remote-Version pruefen (curl, max 5 Sekunden)
        _remote_version=""
        _version_url="https://raw.githubusercontent.com/ChrisRudi/agentbox/main/.version"
        if command -v curl &> /dev/null; then
            _remote_version=$(curl -fsSL --connect-timeout 5 --max-time 5 "$_version_url" 2>/dev/null | tr -d '[:space:]')
        elif command -v wget &> /dev/null; then
            _remote_version=$(wget -qO- --timeout=5 "$_version_url" 2>/dev/null | tr -d '[:space:]')
        fi

        # Update-Class (minor|major) remote pruefen — bestimmt, ob der Pull
        # silent durchlaeuft oder ob der User zum Installer-Rerun mit UAC
        # geroutet werden muss. Default bei fehlender Datei: "minor", damit
        # Upgrades von Pre-1.0.17-Versionen ohne Reibung durchlaufen.
        _remote_update_class="minor"
        _class_url="https://raw.githubusercontent.com/ChrisRudi/agentbox/main/.update_class"
        _class_raw=""
        if command -v curl &> /dev/null; then
            _class_raw=$(curl -fsSL --connect-timeout 5 --max-time 5 "$_class_url" 2>/dev/null | tr -d '[:space:]' || echo "")
        elif command -v wget &> /dev/null; then
            _class_raw=$(wget -qO- --timeout=5 "$_class_url" 2>/dev/null | tr -d '[:space:]' || echo "")
        fi
        if [ "$_class_raw" = "major" ] || [ "$_class_raw" = "minor" ]; then
            _remote_update_class="$_class_raw"
        fi

        date +%s > "$_last_check_file"

        # Nur updaten wenn remote tatsaechlich neuer ist (sort -V = Version-
        # Vergleich, korrekt fuer semver-artige Versionen wie 3.4.5 vs 3.10.0)
        _need_update=false
        if [ -n "$_remote_version" ] && [ -n "$_local_version" ] && [ "$_local_version" != "$_remote_version" ]; then
            _newer=$(printf '%s\n%s\n' "$_local_version" "$_remote_version" | sort -V | tail -1)
            if [ "$_newer" = "$_remote_version" ]; then
                _need_update=true
            fi
        fi
        if [ "$_need_update" = true ] && [ "$_remote_update_class" = "major" ]; then
            # MAJOR-Update: Installer-Rerun mit Admin noetig. In-Place-Pull
            # wuerde nur die Scripts aktualisieren, aber die Windows-seitigen
            # Aenderungen (Features, Kernel, Template-Rebuild-Struktur)
            # nicht auftragen. Also: prompt → elevated PS spawn → exit.
            echo ""
            echo -e "${CYAN}[UPDATE]${NC} Neue agentbox-Version verfuegbar! ($YELLOW$_local_version${NC} → ${GREEN}$_remote_version${NC}) ${YELLOW}[MAJOR]${NC}"
            echo "         Dieses Update braucht ein einmaliges Admin-Setup (UAC-Prompt)."
            echo ""
            echo "           [1] Jetzt aktualisieren (oeffnet elevated Installer)"
            echo "           [2] Diesmal skippen (agentbox startet mit aktueller Version)"
            echo ""
            echo -n "         Auswahl [1]: "
            _major_choice=1
            if read -r -t 10 _major_answer; then
                case "$_major_answer" in
                    2) _major_choice=2 ;;
                    *) _major_choice=1 ;;
                esac
            else
                echo ""
            fi

            if [ "$_major_choice" = "1" ]; then
                echo -e "         ${CYAN}Spawne elevated Installer — bitte den UAC-Prompt bestaetigen...${NC}"
                # Via WSL-Interop einen externen PS-Prozess starten, der per
                # -Verb RunAs eine neue, elevated PS mit install.ps1 hochzieht.
                # Wir koennen die aktuelle WSL-Session nicht in-place eleven;
                # der Umweg ueber powershell.exe ist der einzige saubere Pfad.
                powershell.exe -NoProfile -Command "Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-Command','irm https://raw.githubusercontent.com/ChrisRudi/agentbox/main/install.ps1 | iex'" 2>/dev/null || true
                echo ""
                echo "         Nach Abschluss des Installers bitte agentbox erneut starten."
                exit 0
            else
                echo "         Update uebersprungen — beim naechsten Start (> 24h) wieder."
            fi
            # Flag, damit der unten folgende minor-Block nicht auch noch
            # aktiv wird.
            _need_update=false
        fi
        if [ "$_need_update" = true ]; then
            echo ""
            echo -e "${CYAN}[UPDATE]${NC} Neue agentbox-Version verfuegbar! ($YELLOW$_local_version${NC} → ${GREEN}$_remote_version${NC})"
            echo -n "         Jetzt aktualisieren? [J/n] "

            _do_update=false
            if read -r -t 10 _update_answer; then
                case "$_update_answer" in
                    n|N|nein|Nein) echo "         Update uebersprungen." ;;
                    *) _do_update=true ;;
                esac
            else
                # Timeout → Update ausfuehren
                echo ""
                _do_update=true
            fi

            if [ "$_do_update" = true ]; then
                # Animierter Dot-Spinner statt statischer "Aktualisiere..."-
                # Zeile. git pull / zip-Download kann 30-120s stumm laufen;
                # vorher sah der User nur eine tote Zeile und dachte der
                # Start haengt (Issue #33).
                (
                    _phase=0
                    while :; do
                        _phase=$(( (_phase % 3) + 1 ))
                        _dots=""
                        _i=0
                        while [ "$_i" -lt "$_phase" ]; do _dots="$_dots ."; _i=$((_i+1)); done
                        # \r + ANSI clear-to-eol -> in-place update statt neue Zeilen.
                        printf "\r         ${CYAN}[update%s]${NC} Aktualisiere agentbox...\033[K" "$_dots"
                        sleep 1
                    done
                ) &
                _spinner_pid=$!
                _update_ok=false

                # Methode 1: git pull (wenn git-Repo vorhanden)
                if [ -d "$CONTROL_DIR/.git" ] && command -v git &> /dev/null; then
                    (cd "$CONTROL_DIR" && git pull origin main --quiet 2>/dev/null) && _update_ok=true
                fi

                # Methode 2: ZIP-Download (Fallback)
                if [ "$_update_ok" = false ] && command -v curl &> /dev/null; then
                    _zip_url="https://github.com/ChrisRudi/agentbox/archive/refs/heads/main.zip"
                    _tmp_zip="/tmp/agentbox_update_$$.zip"
                    _tmp_dir="/tmp/agentbox_extract_$$"

                    if curl -fsSL --connect-timeout 10 --max-time 60 -o "$_tmp_zip" "$_zip_url" 2>/dev/null; then
                        mkdir -p "$_tmp_dir"
                        (cd "$_tmp_dir" && python3 -c "
import zipfile, sys
with zipfile.ZipFile('$_tmp_zip') as z:
    z.extractall()
" 2>/dev/null)
                        _extracted=$(find "$_tmp_dir" -maxdepth 1 -mindepth 1 -type d | head -1)
                        if [ -n "$_extracted" ] && [ -d "$_extracted" ]; then
                            # User-config.json sichern
                            _user_cfg=""
                            if [ -f "$CONTROL_DIR/config.json" ]; then
                                _user_cfg=$(cat "$CONTROL_DIR/config.json")
                            fi
                            # Alle Dateien kopieren — sandbox/, cache/, sessions/
                            # liegen inzwischen unter %LOCALAPPDATA%\agentbox\ und
                            # sind im ZIP gar nicht mehr enthalten, deshalb keine
                            # Exclude-Liste mehr noetig.
                            find "$_extracted" -maxdepth 1 -mindepth 1 | while read -r item; do
                                cp -rf "$item" "$CONTROL_DIR/" 2>/dev/null
                            done
                            # User-config.json wiederherstellen
                            if [ -n "$_user_cfg" ]; then
                                echo "$_user_cfg" > "$CONTROL_DIR/config.json"
                            fi
                            _update_ok=true
                        fi
                    fi
                    rm -rf "$_tmp_zip" "$_tmp_dir" 2>/dev/null
                fi

                # Spinner beenden + Progress-Zeile ueberschreiben, bevor
                # die finale Status-Zeile folgt.
                kill "$_spinner_pid" 2>/dev/null || true
                wait "$_spinner_pid" 2>/dev/null || true
                printf "\r\033[K"

                if [ "$_update_ok" = true ]; then
                    echo -e "         ${GREEN}[OK] Update auf Version $_remote_version erfolgreich.${NC}"

                    # Template-Rebuild noetig? Hash-Format MUSS zu
                    # Get-AgentboxConfigHash in win-setup-core.ps1 passen.
                    _cfg_hash_file="$AGENTBOX_LOCAL_ROOT/sandbox/.config_hash"
                    _current_hash=""
                    if command -v python3 &> /dev/null && [ -f "$AGENTBOX_CONFIG" ]; then
                        _current_hash=$(python3 -c "
import json, hashlib
try:
    with open('$AGENTBOX_CONFIG') as f: data = json.load(f)
    ps = lambda v: 'True' if v is True else ('False' if v is False else str(v))
    parts = sorted(f'{k}={ps(data[k])}' for k in data
                   if k.startswith('agent_') or k in ('ubuntu_image_url','nodejs_setup_url'))
    print(hashlib.md5('|'.join(parts).encode('utf-8')).hexdigest())
except:
    print('')
" 2>/dev/null)
                    fi

                    _saved_hash=""
                    if [ -f "$_cfg_hash_file" ]; then
                        _saved_hash=$(cat "$_cfg_hash_file" 2>/dev/null)
                    fi

                    if [ -n "$_current_hash" ] && [ "$_current_hash" != "$_saved_hash" ]; then
                        echo ""
                        echo -e "         ${YELLOW}[INFO] Agent-Konfiguration geaendert — Template-Rebuild empfohlen.${NC}"
                        echo "         Bitte in einer Admin-PowerShell ausfuehren:"
                        echo "         & \"$CONTROL_DIR/win-setup.ps1\""
                    fi
                else
                    echo -e "         ${YELLOW}[WARN] Update fehlgeschlagen — weiter mit aktueller Version.${NC}"
                fi
            fi
        fi
    fi
fi

# --- Template pruefen ---
# Seit 2.0: vhdx ist das primaere Format (Session-Start via import-in-
# place), tar.gz nur Fallback falls --export --vhd beim Build nicht
# verfuegbar war. Mindestens eines von beiden muss da sein.
if [ ! -f "$TEMPLATE_PATH" ] && [ ! -f "$TEMPLATE_VHD_PATH" ]; then
    log_error "Kein Template gefunden — weder $TEMPLATE_VHD_PATH noch $TEMPLATE_PATH"
    if [ -f "$TEMPLATE_PATH_OLD" ]; then
        echo "       Alte Version gefunden unter $TEMPLATE_PATH_OLD —"
        echo "       Migration fehlgeschlagen. Bitte manuell nach"
        echo "       $TEMPLATE_PATH verschieben, oder win-setup.ps1 neu laufen."
    else
        echo "Bitte zuerst win-setup.ps1 als Admin in PowerShell ausfuehren."
    fi
    exit 1
fi

# --- Projektordner scannen ---
echo ""
echo -e "${CYAN}=== agentbox ===${NC}"
echo ""

projects=()
while IFS= read -r dir; do
    [ -d "$dir" ] && projects+=("$dir")
done < <(_list_projects_sorted)

if [ ${#projects[@]} -eq 0 ]; then
    log_warn "Keine Projektordner gefunden in $AI_PROJECTS_ROOT"
    echo "Erstelle einen Projektordner und starte erneut."
    exit 1
fi

# Hidden-Projekte ausfiltern (.agentbox-hidden marker)
visible_projects=()
hidden_projects=()
for _p in "${projects[@]}"; do
    if [ -f "$_p/.agentbox-hidden" ]; then
        hidden_projects+=("$_p")
    else
        visible_projects+=("$_p")
    fi
done
projects=("${visible_projects[@]}")

if [ ${#projects[@]} -eq 0 ]; then
    log_warn "Alle Projektordner sind versteckt. Nutze [c] Konfiguration um sie wieder einzublenden."
    exit 1
fi

# --- Projekt auswaehlen ---
# Auto-Select wenn nur eine Option vorhanden
if [ ${#projects[@]} -eq 1 ]; then
    PROJECT_DIR="${projects[0]}"
    PROJECT_NAME=$(basename "$PROJECT_DIR")
    log_ok "Projekt: $PROJECT_NAME (automatisch gewaehlt — einziges Projekt)"
else
    echo "Welches Projekt?"
    echo ""
    for i in "${!projects[@]}"; do
        pname=$(basename "${projects[$i]}")
        suffix=""
        if [ "$i" -eq 0 ]; then suffix=" (zuletzt)"; fi
        echo "  [$((i+1))] $pname$suffix"
    done
    echo ""

    read -r -p "Auswahl [1]: " choice
    choice=${choice:-1}

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#projects[@]} ]; then
        log_error "Ungueltige Auswahl."
        exit 1
    fi

    PROJECT_DIR="${projects[$((choice-1))]}"
    PROJECT_NAME=$(basename "$PROJECT_DIR")

    log_ok "Projekt: $PROJECT_NAME"
fi

# --- OneDrive Files-On-Demand: Projektordner lokal pinnen + hydrieren ---
# Wenn das Projekt unter OneDrive liegt, sind Dateien haeufig nur als Cloud-
# Only-Placeholder vorhanden (Reparse-Points mit RECALL_ON_DATA_ACCESS). Die
# spaeteren bind-Mounts in die Sandbox-Distro koennen solche Placeholder
# NICHT zuverlaessig hydrieren → der Agent sieht "Input/output error" auf
# CLAUDE.md, project.json, src/. Wir forcen hier "Immer auf diesem Geraet
# behalten" (attrib +P) und triggern danach einen synchronen Read-Pass
# ueber PowerShell, damit OneDrive alles vor dem Sandbox-Start herunterlaedt.
_hydrate_onedrive_project() {
    local _linux_path="$1"
    local _win_path
    _win_path=$(wslpath -w "$_linux_path" 2>/dev/null)
    if [ -z "$_win_path" ]; then
        log_warn "OneDrive-Hydration: Windows-Pfad nicht ermittelbar"
        return 2
    fi

    echo ""
    log_info "Projekt liegt in OneDrive — setze 'Immer auf diesem Geraet behalten'..."
    echo "       Pfad: $_win_path"

    # Schritt 1: Pinnen via attrib.exe (+P = Always keep on this device)
    # /s = rekursiv, /d = inkl. Verzeichnisse. OneDrive beginnt dann asynchron
    # mit dem Download; Schritt 2 erzwingt danach die synchrone Vollendung.
    cmd.exe /c "attrib.exe +P /s /d \"${_win_path}\\*\"" >/dev/null 2>&1 || true

    # Schritt 2: Synchrone Hydration via PowerShell File.OpenRead.
    # Script als Quoted-Heredoc (bash expandiert nichts), danach den Pfad
    # per Platzhalter-Substitution einsetzen — verhindert Bash-$-Konflikte
    # mit PowerShell-$-Variablen.
    local _ps_template
    _ps_template=$(cat <<'PSEOF'
$ErrorActionPreference = 'SilentlyContinue'
$Dir = '@@WIN_PATH@@'
$total = 0
$hydrated = 0
$failed = 0
$failList = New-Object System.Collections.ArrayList
Get-ChildItem -Path $Dir -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object {
    $total++
    $a = [int]$_.Attributes
    # 0x400000 = FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS
    # 0x001000 = FILE_ATTRIBUTE_OFFLINE
    if (($a -band 0x400000) -or ($a -band 0x1000)) {
        try {
            $fs = [System.IO.File]::OpenRead($_.FullName)
            $null = $fs.ReadByte()
            $fs.Close()
            $hydrated++
        } catch {
            $failed++
            if ($failList.Count -lt 5) { [void]$failList.Add($_.FullName) }
        }
    }
}
Write-Host "[HYDRATE] gesamt=$total hydriert=$hydrated fehlgeschlagen=$failed"
foreach ($f in $failList) { Write-Host "         FAIL: $f" }
if ($failed -gt 0) { exit 1 } else { exit 0 }
PSEOF
)
    # Pfad einsetzen (Single-Quote escapen für PS-String-Literal)
    local _win_path_ps="${_win_path//\'/\'\'}"
    local _ps_final="${_ps_template//@@WIN_PATH@@/$_win_path_ps}"

    local _tmp_ps="/tmp/agentbox_hydrate_$$.ps1"
    printf '%s\n' "$_ps_final" > "$_tmp_ps"

    local _win_tmp
    _win_tmp=$(wslpath -w "$_tmp_ps" 2>/dev/null)
    if [ -z "$_win_tmp" ]; then
        rm -f "$_tmp_ps"
        log_warn "OneDrive-Hydration: wslpath fuer Temp-Skript fehlgeschlagen"
        return 2
    fi

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$_win_tmp" 2>&1 | \
        while IFS= read -r _line; do echo "       ${_line%$'\r'}"; done
    local _rc="${PIPESTATUS[0]}"
    rm -f "$_tmp_ps"
    return "$_rc"
}

_pd_lower="${PROJECT_DIR,,}"
# Matched: /OneDrive/ (persoenlich) oder /OneDrive - Company/ (Business-Tenant).
# Nicht gematcht: /OneDrive_backup/ (Unterstrich) oder Dateinamen wie onedrive.md.
if [[ "$_pd_lower" == */onedrive/* ]] || [[ "$_pd_lower" == */onedrive\ * ]]; then
    _hydrate_onedrive_project "$PROJECT_DIR"
    _h_rc=$?
    case "$_h_rc" in
        0) log_ok "OneDrive-Dateien hydriert und lokal gepinnt" ;;
        2) log_warn "OneDrive-Hydration uebersprungen — Voraussetzungen fehlen" ;;
        *)
            echo ""
            log_warn "OneDrive-Hydration unvollstaendig — einige Dateien konnten"
            log_warn "nicht synchronisiert werden. In der Sandbox erscheinen sie"
            log_warn "als 'Input/output error'. Typische Ursachen:"
            log_warn "  - OneDrive offline oder Sync pausiert"
            log_warn "  - Sync-Konflikt auf einzelnen Dateien"
            log_warn "  - Keine Netzwerkverbindung"
            echo -n "       Trotzdem fortfahren? [J/n] "
            if read -r _h_ans; then
                case "$_h_ans" in
                    n|N|nein|Nein) exit 1 ;;
                esac
            fi
            ;;
    esac
fi

# --- project.json pruefen/generieren ---
PROJECT_JSON="$PROJECT_DIR/project.json"

if [ ! -f "$PROJECT_JSON" ]; then
    log_info "Keine project.json gefunden — generiere automatisch..."

    # Auto-Detection
    detected_type="generic"

    if [ -f "$PROJECT_DIR/src/package.json" ] || [ -f "$PROJECT_DIR/package.json" ]; then
        detected_type="node"
    elif compgen -G "$PROJECT_DIR/src/*.py" > /dev/null 2>&1 || compgen -G "$PROJECT_DIR/*.py" > /dev/null 2>&1; then
        detected_type="python"
    elif compgen -G "$PROJECT_DIR/src/*.ps1" > /dev/null 2>&1 || compgen -G "$PROJECT_DIR/*.ps1" > /dev/null 2>&1; then
        detected_type="powershell"
    elif compgen -G "$PROJECT_DIR/src/*.html" > /dev/null 2>&1 || compgen -G "$PROJECT_DIR/*.html" > /dev/null 2>&1; then
        detected_type="html"
    fi

    log_info "Erkannter Typ: $detected_type"

    # Defaults aus type_defaults.json laden
    if [ -f "$TYPE_DEFAULTS" ] && command -v python3 &> /dev/null; then
        defaults=$(python3 -c "
import json, sys
with open('$TYPE_DEFAULTS') as f:
    data = json.load(f)
d = data['defaults'].get('$detected_type', data['defaults']['generic'])
result = {
    'name': '$PROJECT_NAME',
    'type': '$detected_type',
    'version': '1.0.0',
    'build': d.get('build'),
    'deploy': d.get('deploy', {'target': '', 'url': ''}),
    'agent': d.get('agent', {'working_dir': 'src', 'entry_point': ''})
}
print(json.dumps(result, indent=2, ensure_ascii=False))
")
    else
        # Fallback ohne Python
        defaults=$(cat <<PJEOF
{
  "name": "$PROJECT_NAME",
  "type": "$detected_type",
  "version": "1.0.0",
  "build": null,
  "deploy": { "target": "", "url": "" },
  "agent": { "working_dir": "src", "entry_point": "" }
}
PJEOF
)
    fi

    echo "$defaults" > "$PROJECT_JSON"
    log_ok "project.json generiert"
fi

# --- CLAUDE.md generieren falls nicht vorhanden ---
CLAUDE_MD="$PROJECT_DIR/CLAUDE.md"

if [ ! -f "$CLAUDE_MD" ]; then
    cat > "$CLAUDE_MD" << 'CMDEOF'
# CLAUDE.md — Session-Kontinuitaet

## Projektstatus
- Neues Projekt, noch keine vorherige Session.

## Naechste Schritte
- Projekt erkunden und Struktur verstehen.
- Erste Aufgaben definieren.

## Entscheidungen
- (noch keine)
CMDEOF
    log_ok "CLAUDE.md erstellt"
fi

# --- CLAUDE.md Backup ---
cp "$CLAUDE_MD" "${CLAUDE_MD}.bak"
log_ok "CLAUDE.md Backup erstellt"

# --- _tasks/ Ordner anlegen ---
TASKS_DIR="$PROJECT_DIR/_tasks"
if [ ! -d "$TASKS_DIR" ]; then
    mkdir -p "$TASKS_DIR"
fi

# --- Auth-State anlegen (persistiert Agent-Logins ueber Sessions) ---
# AUTH_BASE wurde bereits oben aus AGENTBOX_LOCAL_ROOT abgeleitet; hier
# nur noch die Per-Agent-Unterordner anlegen und die globale CLAUDE.md
# als Memory einsetzen. Agent-Liste + Home-relativer Auth-Dir kommen aus
# config.json via cfg_get_agents_all (einzige Wahrheitsquelle; ersetzt
# die frueher-hartcodierte Liste). Format pro Zeile: "id:auth_dir".
#
# Defensive: wenn lib/config.sh auf dem Host aus irgendeinem Grund
# noch Pre-2.0.4 ist (OneDrive-Sync-Skew, partieller Pull), faellt
# cfg_get_agents_all aus und `set -u` killt den Start. Wir shimmen
# die Funktion in dem Fall mit einem Hardcode-Return ab — derselbe
# Inhalt wie der 2.0.4-Fallback in lib/config.sh.
if ! declare -F cfg_get_agents_all >/dev/null 2>&1; then
    cfg_get_agents_all() {
        echo "claude:.claude"
        echo "codex:.codex"
        echo "gemini:.gemini"
        echo "aider:.aider"
        echo "goose:.config/goose"
    }
fi

AGENTBOX_AUTH_SPEC=""
AGENTBOX_AUTH_IDS=""
while IFS=: read -r _aid _adir; do
    [ -z "$_aid" ] && continue
    mkdir -p "$AUTH_BASE/$_aid"
    # AUTH_SPEC fuer sandbox-init: id=auth_dir, Semikolon-getrennt (wsl.exe
    # Interop trennt uns Newlines nicht zuverlaessig ueber Argumente).
    if [ -z "$AGENTBOX_AUTH_SPEC" ]; then
        AGENTBOX_AUTH_SPEC="${_aid}=${_adir}"
        AGENTBOX_AUTH_IDS="$_aid"
    else
        AGENTBOX_AUTH_SPEC="${AGENTBOX_AUTH_SPEC};${_aid}=${_adir}"
        AGENTBOX_AUTH_IDS="$AGENTBOX_AUTH_IDS $_aid"
    fi
done < <(cfg_get_agents_all)

# Defensiver Fallback: sollte cfg_get_agents_all (z.B. ohne python3 + ohne
# config.json) leer liefern, nutzen wir die Legacy-Hardcode-Liste statt
# die Auth-Persistenz komplett zu verlieren.
if [ -z "$AGENTBOX_AUTH_SPEC" ]; then
    AGENTBOX_AUTH_SPEC="claude=.claude;codex=.codex;gemini=.gemini;aider=.aider;goose=.config/goose"
    AGENTBOX_AUTH_IDS="claude codex gemini aider goose"
    for _aid in claude codex gemini aider goose; do
        mkdir -p "$AUTH_BASE/$_aid"
    done
fi
# SYSTEM_META_PROMPT.md als globale Claude-Code-Memory im Claude-Auth-
# Ordner ablegen (Claude Code laedt ~/.claude/CLAUDE.md automatisch als
# globalen Kontext). Ueberschreiben ist bewusst: das ist der agentbox-
# Vertrag, nicht user-editierbar — bei einem Update soll der Agent die
# neue Version sehen.
if [ -f /etc/agentbox/SYSTEM_META_PROMPT.md ]; then
    cp /etc/agentbox/SYSTEM_META_PROMPT.md "$AUTH_BASE/claude/CLAUDE.md" 2>/dev/null || true
fi

# --- Auto-Approve-Defaults je Agent seeden ---
# Die Sandbox selbst ist die Vertrauensgrenze (kein Host-FS, kein LAN,
# Firewall default-deny). Innerhalb davon ist das staendige "Darf ich X
# ausfuehren?" reine Reibung. Wir seeden deshalb pro Agent die jeweilige
# Config-Datei mit "ja zu allem".
#
# Smart-Merge statt naivem if-not-exists, weil manche Agents (z.B. Claude
# Code) beim ersten Start ihre settings.json selbst als leeres {} anlegen —
# ein reines if-not-exists wuerde dann bei spaeteren Starts die leere Datei
# sehen, skippen, und der User bekaeme trotz Seed keine Policies.
#
# Logik pro Agent:
# - Datei fehlt         -> neu schreiben
# - Datei existiert leer -> neu schreiben
# - Datei existiert mit Content:
#     * Claude (JSON):   permissions.defaultMode ergaenzen wenn fehlend,
#                        andere Keys unberuehrt lassen. Kaputtes JSON: warnen.
#     * Codex (TOML):    nicht anfassen (User hat was gesetzt)
#     * Goose (YAML):    nicht anfassen (User hat was gesetzt)
#
# Gemini CLI: YOLO-Mode laesst sich laut Docs nur per CLI-Flag aktivieren.
# Aider: Config liegt in ~/.aider.conf.yml, NICHT im gemounteten .aider/-
# Ordner — Seeding hier wuerde nichts bringen. Fuer beide setzt
# wsl-sandbox-init.sh beim Launch den CLI-Flag.

# Helper: schreibt $2 nach $1, wenn Datei fehlt oder nur whitespace enthaelt.
# Gibt auf stdout "created"/"replaced-empty"/"kept" fuer Logging.
_seed_if_empty() {
    local _path="$1"
    local _content="$2"
    mkdir -p "$(dirname "$_path")"
    if [ ! -f "$_path" ]; then
        printf '%s\n' "$_content" > "$_path"
        echo "created"
        return
    fi
    if [ ! -s "$_path" ] || [ -z "$(tr -d '[:space:]' < "$_path" 2>/dev/null)" ]; then
        printf '%s\n' "$_content" > "$_path"
        echo "replaced-empty"
        return
    fi
    echo "kept"
}

# Claude Code — ~/.claude/settings.json
# permissions.defaultMode=bypassPermissions: keine Approval-Prompts mehr.
# .git/, .claude/ (ausser commands|skills|agents), .vscode/, .idea/,
# .husky/ fragen trotzdem noch — das ist in Claude Code fest eingebaut.
_seed_claude_settings() {
    local _path="$AUTH_BASE/claude/settings.json"
    local _default='{
  "permissions": {
    "defaultMode": "bypassPermissions"
  }
}'
    mkdir -p "$(dirname "$_path")"

    # Fehlt oder leer → komplett neu
    if [ ! -f "$_path" ] || [ ! -s "$_path" ] \
       || [ -z "$(tr -d '[:space:]' < "$_path" 2>/dev/null)" ]; then
        printf '%s\n' "$_default" > "$_path"
        echo "created"
        return
    fi

    # Trivial {} (Claude Code legt beim ersten Start eine leere an) → ersetzen
    local _trimmed
    _trimmed="$(tr -d '[:space:]' < "$_path" 2>/dev/null)"
    if [ "$_trimmed" = "{}" ]; then
        printf '%s\n' "$_default" > "$_path"
        echo "replaced-empty"
        return
    fi

    # Sonst: JSON parsen, defaultMode ergaenzen wenn fehlt, User-Keys behalten.
    # python3 ist im Template garantiert (siehe win-setup-core.ps1 Step [3/5]).
    local _py_result
    _py_result=$(python3 - "$_path" << 'PYEOF' 2>/dev/null
import json, sys
path = sys.argv[1]
try:
    with open(path, encoding='utf-8') as f:
        data = json.load(f)
except Exception:
    print("invalid")
    sys.exit(0)

if not isinstance(data, dict):
    print("not-object")
    sys.exit(0)

perms = data.get("permissions")
if isinstance(perms, dict) and "defaultMode" in perms:
    print("already-set")
    sys.exit(0)

if not isinstance(perms, dict):
    data["permissions"] = {"defaultMode": "bypassPermissions"}
else:
    data["permissions"]["defaultMode"] = "bypassPermissions"

with open(path, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
print("merged")
PYEOF
)
    echo "${_py_result:-error}"
}
_claude_status=$(_seed_claude_settings)

# OpenAI Codex CLI — ~/.codex/config.toml
# approval_policy=never + sandbox_mode=danger-full-access entspricht
# exakt --dangerously-bypass-approvals-and-sandbox. Beide Keys sind
# Teil des offiziellen Config-Schemas (codex-rs/core/config.schema.json).
_codex_default='# agentbox-Default: Sandbox ist die Vertrauensgrenze, kein Approval-Prompting.
approval_policy = "never"
sandbox_mode    = "danger-full-access"'
_codex_status=$(_seed_if_empty "$AUTH_BASE/codex/config.toml" "$_codex_default")

# Goose — ~/.config/goose/config.yaml
# GOOSE_MODE=auto: "Completely Autonomous, no approval required"
# (siehe goose docs/guides/goose-permissions).
_goose_default='# agentbox-Default: fully autonomous mode, keine Tool-/File-/Extension-Approvals.
GOOSE_MODE: auto'
_goose_status=$(_seed_if_empty "$AUTH_BASE/goose/config.yaml" "$_goose_default")

log_ok "Auto-Approve-Seeds: claude=$_claude_status codex=$_codex_status goose=$_goose_status"

log_ok "Auth-Cache: $AUTH_BASE (Logins persistiert: $AGENTBOX_AUTH_IDS)"

# --- Alte status_*.json loeschen ---
find "$TASKS_DIR" -name "status_*.json" -type f -delete 2>/dev/null || true
log_ok "Alte Status-Dateien bereinigt"

# --- Agent auswaehlen (mit Config-Menue) ---
# Hilfsfunktion: aktivierte Agents aus config.json laden
_load_enabled_agents() {
    agents=()
    agent_cmds=()
    agent_ids=()
    if type cfg_get_agents &> /dev/null; then
        while IFS=: read -r _aid _aname _acmd; do
            if [ -n "$_acmd" ]; then
                agents+=("$_aname")
                agent_cmds+=("$_acmd")
                agent_ids+=("$_aid")
            fi
        done < <(cfg_get_agents)
    fi
    # Fallback: hardcoded falls config.sh nicht geladen
    if [ ${#agents[@]} -eq 0 ]; then
        agents=("Claude Code" "OpenAI Codex")
        agent_cmds=("claude" "codex")
        agent_ids=("claude" "codex")
    fi
}

# Config-Untermenue: Agents toggle + Projekte verstecken + Benchmark
_config_menu() {
    while true; do
        echo ""
        echo -e "${CYAN}=== Konfiguration ===${NC}"
        echo ""
        echo "  [1] Agents aktivieren/deaktivieren"
        echo "  [2] Projekte verstecken/einblenden"
        echo "  [3] Benchmark ausfuehren"
        echo "  [q] Zurueck"
        echo ""
        read -r -p "Auswahl: " _cfg_choice
        case "$_cfg_choice" in
            1) _toggle_agents_menu ;;
            2) _toggle_projects_menu ;;
            3) _run_benchmark_menu ;;
            q|Q|"") return ;;
            *) echo "Ungueltige Auswahl." ;;
        esac
    done
}

# Benchmark-Menu: misst Sandbox-Seite synchron, legt ein Task-JSON fuer den
# Host-Runner in <demo-benchmark>/_tasks/ an und emittiert dann ein
# Trigger-Event (Source=AIProjects, EventID=2000) via powershell.exe-Interop.
# Der Scheduled-Task agentbox-task-runner hat dieses Event als Trigger:
# feuert das Event, startet der Runner im -once-Mode, verarbeitet das
# Task-File via Process-AllTasks, ruft bench.ps1 via build.command, HTML
# oeffnet sich im Host-Browser. Audit-Trail ueber dieselbe EventSource
# 'AIProjects' mit IDs 1001/1002/1003 fuer start/done/fail.
_run_benchmark_menu() {
    local _demo_dir="$AI_PROJECTS_ROOT/demo-benchmark"
    echo ""
    echo -e "${CYAN}--- Benchmark ---${NC}"
    if [ ! -d "$_demo_dir" ]; then
        log_error "Demo-Projekt nicht gefunden: $_demo_dir"
        echo "  Fuehre install.ps1 erneut als Admin aus, um demo-benchmark/ zu seeden."
        return
    fi
    if [ ! -x "$_demo_dir/bench.sh" ]; then
        log_error "bench.sh nicht gefunden oder nicht ausfuehrbar in $_demo_dir"
        return
    fi
    if [ ! -f "$_demo_dir/bench.ps1" ]; then
        log_error "bench.ps1 nicht gefunden in $_demo_dir"
        return
    fi

    local _out_file="$_demo_dir/bench-results.json"
    # Honest label: das Config-Submenue laeuft aus agentbox-host heraus,
    # NICHT aus einer ephemeren session-getunten Sandbox. Der
    # BENCH_PLATFORM=agentbox_host-Key macht das in bench-results.json
    # explizit sichtbar.
    echo "agentbox-host-Seite messen (schreibt in $_out_file, Schluessel .agentbox_host)..."
    echo ""
    if ! BENCH_PLATFORM=agentbox_host BENCH_OUT="$_out_file" bash "$_demo_dir/bench.sh"; then
        log_error "bench.sh fehlgeschlagen."
        return
    fi

    local _ts
    _ts=$(date +%s)
    local _tasks_dir="$_demo_dir/_tasks"
    mkdir -p "$_tasks_dir" 2>/dev/null || true
    local _task_file="$_tasks_dir/bench-$_ts.json"
    printf '{"project":"demo-benchmark","action":"build","timestamp":%s}\n' "$_ts" > "$_task_file"

    echo ""
    log_ok "Task angelegt: $_task_file"

    # Trigger-Event emittieren, damit Task Scheduler den Runner sofort
    # startet. EventSource 'AIProjects' existiert seit Install
    # (Register-AgentboxTaskRunner). Write-EventLog auf bestehende Source
    # braucht keine Admin-Rechte, laeuft also im normalen User-Kontext.
    # Fehler werden ignoriert -- im Worst Case wartet der Task auf den
    # naechsten Logon-Sweep.
    local _event_src="${AGENTBOX_EVENT_SOURCE:-AIProjects}"
    if command -v powershell.exe &>/dev/null; then
        powershell.exe -NoProfile -Command \
            "Write-EventLog -LogName Application -Source '$_event_src' -EntryType Information -EventId 2000 -Message 'agentbox Task queued: demo-benchmark build ($_ts)'" \
            >/dev/null 2>&1 || true
        log_ok "Trigger-Event emittiert (Source=$_event_src, EventID=2000)"
    else
        echo "  [WARN] powershell.exe nicht verfuegbar -- Task wird erst beim naechsten Logon verarbeitet."
    fi

    echo ""
    echo "  Task Scheduler startet win-task-runner.ps1 -once, der verarbeitet"
    echo "  das Task-File, fuehrt bench.ps1 aus und oeffnet index.html im"
    echo "  Standard-Browser."
    echo "  Audit-Trail: Event-Log > Application > Source 'AIProjects'"
    echo "               (EventID 2000 = getriggert, 1001 = gestartet,"
    echo "                1002 = erledigt, 1003 = Fehler)"
    echo ""
    read -r -p "[Enter] zurueck ins Konfigurations-Menu..." _
}

_toggle_agents_menu() {
    echo ""
    echo -e "${CYAN}--- Agents ---${NC}"
    echo "Aenderungen werden in config.json gespeichert."
    echo "Fuer neue Agent-Binaries muss install.ps1 in einer Admin-PowerShell"
    echo "neu ausgefuehrt werden (Template-Rebuild):"
    echo "  irm https://raw.githubusercontent.com/ChrisRudi/agentbox/main/install.ps1 | iex"
    echo ""
    local _aids=("claude" "codex" "gemini" "aider" "goose")
    local _names=("Claude Code" "OpenAI Codex" "Gemini CLI" "Aider" "Goose")
    for i in "${!_aids[@]}"; do
        local _aid="${_aids[$i]}"
        local _name="${_names[$i]}"
        local _enabled
        _enabled=$(python3 -c "
import json
try:
    with open('$AGENTBOX_CONFIG') as f: print('on' if json.load(f).get('agent_${_aid}_enabled') else 'off')
except: print('off')
" 2>/dev/null)
        local _mark="[ ]"
        [ "$_enabled" = "on" ] && _mark="[x]"
        echo "  [$((i+1))] $_mark $_name"
    done
    echo "  [q] Zurueck"
    echo ""
    read -r -p "Nummer zum Umschalten: " _ag_choice
    case "$_ag_choice" in
        q|Q|"") return ;;
        *)
            if [[ "$_ag_choice" =~ ^[0-9]+$ ]] && [ "$_ag_choice" -ge 1 ] && [ "$_ag_choice" -le ${#_aids[@]} ]; then
                local _aid="${_aids[$((_ag_choice-1))]}"
                python3 -c "
import json
with open('$AGENTBOX_CONFIG') as f: cfg = json.load(f)
key = 'agent_${_aid}_enabled'
cfg[key] = not cfg.get(key, False)
with open('$AGENTBOX_CONFIG', 'w') as f: json.dump(cfg, f, indent=2, ensure_ascii=False)
print(f'[OK] {key} = {cfg[key]}')
" 2>&1
                _toggle_agents_menu
            fi
            ;;
    esac
}

_toggle_projects_menu() {
    echo ""
    echo -e "${CYAN}--- Projekte ---${NC}"
    echo "[x] = sichtbar, [ ] = versteckt"
    echo ""
    local _all=()
    while IFS= read -r _dir; do
        [ -n "$_dir" ] && _all+=("$_dir")
    done < <(_list_projects_sorted)

    if [ ${#_all[@]} -eq 0 ]; then
        echo "Keine Projektordner gefunden."
        return
    fi

    for i in "${!_all[@]}"; do
        local _p="${_all[$i]}"
        local _pname
        _pname=$(basename "$_p")
        local _mark="[x]"
        [ -f "$_p/.agentbox-hidden" ] && _mark="[ ]"
        echo "  [$((i+1))] $_mark $_pname"
    done
    echo "  [q] Zurueck"
    echo ""
    read -r -p "Nummer zum Umschalten: " _proj_choice
    case "$_proj_choice" in
        q|Q|"") return ;;
        *)
            if [[ "$_proj_choice" =~ ^[0-9]+$ ]] && [ "$_proj_choice" -ge 1 ] && [ "$_proj_choice" -le ${#_all[@]} ]; then
                local _target="${_all[$((_proj_choice-1))]}"
                if [ -f "$_target/.agentbox-hidden" ]; then
                    rm -f "$_target/.agentbox-hidden"
                    echo "[OK] $(basename "$_target") wieder sichtbar"
                else
                    touch "$_target/.agentbox-hidden"
                    echo "[OK] $(basename "$_target") versteckt"
                fi
                _toggle_projects_menu
            fi
            ;;
    esac
}

# Agent-Auswahl-Loop (mit Config-Menue)
echo ""
while true; do
    _load_enabled_agents

    if [ ${#agents[@]} -eq 0 ]; then
        log_error "Kein AI-Agent in config.json aktiviert."
        echo "Bitte mit [c] in der Konfiguration aktivieren."
        agents=("(keine)")
        agent_cmds=("")
    fi

    # Auto-Select wenn nur ein Agent verfuegbar
    if [ ${#agents[@]} -eq 1 ] && [ -n "${agent_cmds[0]}" ]; then
        AGENT_NAME="${agents[0]}"
        AGENT_CMD="${agent_cmds[0]}"
        AGENT_ID="${agent_ids[0]}"
        log_ok "Agent: $AGENT_NAME (automatisch gewaehlt — einziger aktiver Agent)"
        break
    fi

    echo "Welcher Agent?"
    echo ""
    for i in "${!agents[@]}"; do
        echo "  [$((i+1))] ${agents[$i]}"
    done
    echo "  [c] Konfiguration"
    echo ""

    read -r -p "Auswahl [1]: " agent_choice
    agent_choice=${agent_choice:-1}

    if [ "$agent_choice" = "c" ] || [ "$agent_choice" = "C" ]; then
        _config_menu
        continue
    fi

    if ! [[ "$agent_choice" =~ ^[0-9]+$ ]] || [ "$agent_choice" -lt 1 ] || [ "$agent_choice" -gt ${#agents[@]} ]; then
        echo "Ungueltige Auswahl."
        continue
    fi

    if [ -z "${agent_cmds[$((agent_choice-1))]}" ]; then
        echo "Dieser Agent ist nicht aktiv. Bitte [c] Konfiguration nutzen."
        continue
    fi

    AGENT_NAME="${agents[$((agent_choice-1))]}"
    AGENT_CMD="${agent_cmds[$((agent_choice-1))]}"
    AGENT_ID="${agent_ids[$((agent_choice-1))]}"
    log_ok "Agent: $AGENT_NAME"
    break
done

# Install-Command des gewaehlten Agents nachschlagen — wird gleich an
# wsl-sandbox-init.sh weitergereicht, damit das Self-Update als root vor
# dem Drop auf $SANDBOX_USER laufen kann (umgeht den EACCES auf
# /usr/lib/node_modules bzw. /usr/lib/python3/dist-packages).
AGENT_INSTALL=""
if [ -n "${AGENT_ID:-}" ] && type cfg_get &> /dev/null; then
    AGENT_INSTALL=$(cfg_get "agent_${AGENT_ID}_install" "")
fi

# --- Session-Lock pruefen ---
# Bewusst _running statt _exists: ein abgebrochener wsl --import (z.B.
# weil das Import-Ziel-Verzeichnis fehlt) hinterlaesst eine registrierte
# aber nicht laufende Distro. Die wollen wir NICHT als "Session laeuft"
# missinterpretieren — sonst klemmt der naechste Start an einem stale
# Lock fest und der Stale-Cleanup unten wird nie erreicht. Wirklich
# laufende Sessions blockieren uns weiter wie gehabt.
DISTRO_NAME="agentbox-${PROJECT_NAME}"

if _wsl_distro_running "$DISTRO_NAME"; then
    log_error "Session laeuft bereits: $DISTRO_NAME"
    echo "Es kann nur eine Session pro Projekt gleichzeitig laufen."
    echo "Beende die bestehende Session zuerst oder warte bis sie fertig ist."
    echo "Notfall-Stop: wsl.exe --terminate $DISTRO_NAME"
    exit 1
fi

# Cleanup-Trap aktivieren, sobald DISTRO_NAME steht und der Lock-Check
# passiert ist. Faengt jeden Exit-Pfad ab — Strg+C im Agent, Terminal-
# Close, partiell gescheiterter wsl --import, watchdog-OOM, etc. — und
# raeumt die Distro garantiert weg, sodass der naechste Start nicht an
# einem stale-running-Zustand klemmt.
trap _agentbox_cleanup EXIT INT TERM HUP

# --- Session-Snapshot erstellen (fuer Replay-Modus) ---
# SESSIONS_DIR wurde bereits oben aus AGENTBOX_LOCAL_ROOT abgeleitet.
SESSION_ID="$(date +%Y%m%d_%H%M%S)_${AGENT_CMD}_${PROJECT_NAME}"
SESSION_DIR="$SESSIONS_DIR/$SESSION_ID"

# Replay-Modus: Snapshot wiederherstellen statt neuen erstellen
if [ -n "$REPLAY_SESSION" ]; then
    REPLAY_DIR="$SESSIONS_DIR/$REPLAY_SESSION"
    if [ ! -d "$REPLAY_DIR" ]; then
        log_error "Replay-Session nicht gefunden: $REPLAY_SESSION"
        echo "Verfuegbare Sessions: agentbox --list-sessions"
        exit 1
    fi
    if [ ! -f "$REPLAY_DIR/snapshot.tar.gz" ]; then
        log_error "Kein Snapshot in Session: $REPLAY_SESSION"
        exit 1
    fi

    echo ""
    log_info "Replay-Modus: Stelle Snapshot wieder her..."

    # Projekt-src/ zuruecksetzen auf Snapshot-Stand
    if [ -d "$PROJECT_DIR/src" ]; then
        rm -rf "$PROJECT_DIR/src"
    fi
    tar -xzf "$REPLAY_DIR/snapshot.tar.gz" -C "$PROJECT_DIR" 2>/dev/null

    # CLAUDE.md aus Snapshot wiederherstellen
    if [ -f "$REPLAY_DIR/CLAUDE.md" ]; then
        cp "$REPLAY_DIR/CLAUDE.md" "$PROJECT_DIR/CLAUDE.md"
    fi

    log_ok "Snapshot von '$REPLAY_SESSION' wiederhergestellt"
    log_info "Replay mit Agent: $AGENT_NAME"
fi

# Snapshot erstellen (src/ + CLAUDE.md)
mkdir -p "$SESSION_DIR"
if [ -d "$PROJECT_DIR/src" ]; then
    tar -czf "$SESSION_DIR/snapshot.tar.gz" -C "$PROJECT_DIR" src 2>/dev/null || true
elif [ -d "$PROJECT_DIR" ]; then
    # Kein src/ Ordner — Projektroot sichern (ohne _tasks, assets, cache)
    tar -czf "$SESSION_DIR/snapshot.tar.gz" -C "$PROJECT_DIR" \
        --exclude='_tasks' --exclude='assets' --exclude='.git' . 2>/dev/null || true
fi

# CLAUDE.md sichern
if [ -f "$PROJECT_DIR/CLAUDE.md" ]; then
    cp "$PROJECT_DIR/CLAUDE.md" "$SESSION_DIR/CLAUDE.md"
fi

# Session-Metadaten speichern
cat > "$SESSION_DIR/meta.json" << METAEOF
{
  "id": "$SESSION_ID",
  "project": "$PROJECT_NAME",
  "agent": "$AGENT_NAME",
  "agent_cmd": "$AGENT_CMD",
  "timestamp": "$(date -Iseconds)",
  "replay_of": "${REPLAY_SESSION:-}"
}
METAEOF

log_ok "Session-Snapshot erstellt: $SESSION_ID"

# --- Sandbox-Distro importieren ---
# agentbox 2.0: Zwei Pfade je nach Template-Format.
#
# Fast-Path (vhdx): existiert template.vhdx, kopieren wir sie auf einen
# session-spezifischen Pfad (~3-5s File-Copy auf SSD) und registrieren sie
# per `wsl --import-in-place` (<1s). Gesamt: ~5s Sandbox-Start.
#
# Legacy-Path (tar.gz): `wsl --import` extrahiert template.tar.gz in das
# Ziel-Verzeichnis — 30-120s pro Start, weil tar.gz-Extract I/O-gebunden
# und auf DrvFs besonders langsam ist. Bleibt als Fallback fuer WSL-
# Versionen ohne --import-in-place / ohne vhdx-Export.
echo ""

# Windows-Pfad fuer WSL-Import
WIN_PROJECT_DIR=$(wslpath -w "$PROJECT_DIR" 2>/dev/null || echo "$PROJECT_DIR")
WIN_TEMPLATE=$(wslpath -w "$TEMPLATE_PATH" 2>/dev/null || echo "$TEMPLATE_PATH")
WIN_TEMPLATE_VHD=""
if [ -f "$TEMPLATE_VHD_PATH" ]; then
    WIN_TEMPLATE_VHD=$(wslpath -w "$TEMPLATE_VHD_PATH" 2>/dev/null || echo "$TEMPLATE_VHD_PATH")
fi

# Windows-Temp-Verzeichnis ermitteln (USERNAME in WSL != Windows).
# Mehrstufig wie _resolve_agentbox_local_root: PowerShell zuerst (UTF-8-faehig,
# robust gegen Umlaut-Usernamen), cmd.exe als Fallback (kann an OEM-Codepage
# scheitern, wenn der Username einen Umlaut enthaelt), und am Ende /tmp.
WIN_TEMP_BASE=""
if command -v powershell.exe >/dev/null 2>&1; then
    WIN_TEMP_BASE=$(powershell.exe -NoProfile -NonInteractive -Command '[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; Write-Output $env:TEMP' 2>/dev/null | tr -d '\r\n' | tr -d '\000' || true)
fi
if [ -z "$WIN_TEMP_BASE" ]; then
    WIN_TEMP_BASE=$(cmd.exe /c "echo %TEMP%" 2>/dev/null | tr -d '\r\n' | tr -d '\000' || true)
fi
if [ -z "$WIN_TEMP_BASE" ]; then
    # Letzter Fallback: WSL-Pfad via wslpath konvertieren
    WIN_TEMP_BASE=$(wslpath -w /tmp 2>/dev/null || echo "C:\\Temp")
fi
WIN_TEMP_DIR="${WIN_TEMP_BASE}\\agentbox\\${PROJECT_NAME}"

# Zielverzeichnis im Voraus aufraeumen UND sicherstellen, dass der Pfad
# existiert. wsl --import wirft Wsl/ERROR_PATH_NOT_FOUND wenn der Parent
# fehlt — und beim allerersten Run nach sauberem Setup existiert
# %TEMP%\agentbox\ noch nicht, weil ephemere Distros am Ende unregistered
# werden und kein Verzeichnis zuruecklassen. Frueher hat das nur deshalb
# funktioniert, weil Reste aus alten Laeufen den Parent zufaellig stehen
# liessen — nicht zuverlaessig.
LINUX_TEMP_DIR=$(wslpath -u "$WIN_TEMP_DIR" 2>/dev/null || echo "")
if [ -n "$LINUX_TEMP_DIR" ]; then
    if [ -d "$LINUX_TEMP_DIR" ]; then
        rm -rf "$LINUX_TEMP_DIR" 2>/dev/null || true
    fi
    mkdir -p "$LINUX_TEMP_DIR" 2>/dev/null || true
fi

echo "[INFO] Import-Ziel: $WIN_TEMP_DIR"
echo "[INFO] Template: $WIN_TEMPLATE"

# Stale Distro-Reste wegraeumen. Zielbezeichnung immer unregistern;
# zusaetzlich alte Build-Distros (agentbox-template-build*) einer
# abgebrochenen Setup-Session entfernen — agentbox-host bleibt stehen,
# die ist persistent als Default-Distro vorgesehen.
if _wsl_distro_exists "$DISTRO_NAME"; then
    log_info "Entferne alte Sandbox-Distro: $DISTRO_NAME"
    wsl.exe --unregister "$DISTRO_NAME" 2>&1 | tr -d '\000' || true
fi
wsl.exe -l -q 2>/dev/null | tr -d '\000\r' | while IFS= read -r _d; do
    _d="${_d// /}"
    case "$_d" in
        agentbox-template-build*)
            echo "[INFO] Entferne veraltete Build-Distro: $_d"
            wsl.exe --unregister "$_d" 2>&1 | tr -d '\000' || true
            ;;
    esac
done

# --- Import: Fast-Path (vhdx, import-in-place) bevorzugt, tar.gz-Fallback ---
_agentbox_import_ok=0
if [ -n "$WIN_TEMPLATE_VHD" ] && [ -f "$TEMPLATE_VHD_PATH" ]; then
    log_info "Importiere Sandbox-Distro (vhdx fast-path, ~5s)..."
    # Session-spezifische vhdx-Kopie im WIN_TEMP_DIR. Die Template-vhdx
    # selbst darf nicht direkt als Distro registriert werden — import-in-
    # place macht die Datei exklusiv-lock, parallele Sessions bzw. der
    # naechste Start wuerden dann EBUSY sehen.
    SESSION_VHD_LINUX="$LINUX_TEMP_DIR/session.vhdx"
    WIN_SESSION_VHD="${WIN_TEMP_DIR}\\session.vhdx"

    # Copy: via Linux cp, nicht via PowerShell — spart einen Interop-Hop
    # und nutzt Kernel-Copy direkt auf DrvFs.
    if cp -f "$TEMPLATE_VHD_PATH" "$SESSION_VHD_LINUX" 2>/dev/null; then
        # Exit-Code vor Pipe einfangen (`| tr` waere sonst last in pipe
        # und maskiert wsl-Failure). Output separat bereinigen.
        _vhd_import_out=$(wsl.exe --import-in-place "$DISTRO_NAME" "$WIN_SESSION_VHD" 2>&1 | tr -d '\000' || true)
        _vhd_import_rc=${PIPESTATUS[0]}
        if [ "$_vhd_import_rc" -eq 0 ]; then
            _agentbox_import_ok=1
            log_ok "Sandbox-Distro importiert (vhdx): $DISTRO_NAME"
        else
            log_info "import-in-place fehlgeschlagen (rc=$_vhd_import_rc) — fallback auf tar.gz"
            if [ -n "$_vhd_import_out" ]; then
                echo "$_vhd_import_out" | sed 's/^/       /'
            fi
            # Halb-registrierte Distro aufraeumen
            wsl.exe --unregister "$DISTRO_NAME" 2>&1 | tr -d '\000' >/dev/null || true
            rm -f "$SESSION_VHD_LINUX" 2>/dev/null || true
        fi
    else
        log_info "vhdx-Copy fehlgeschlagen — fallback auf tar.gz"
    fi
fi

if [ "$_agentbox_import_ok" -ne 1 ]; then
    # Seit 2.0 wird tar.gz nur noch gebaut wenn der vhdx-Export beim
    # Build-Schritt fehlschlug. Wenn vhdx hier schon einmal klemmt UND
    # kein tar.gz vorliegt, hat der User keinen Fallback — sauber abbrechen.
    if [ ! -f "$TEMPLATE_PATH" ]; then
        log_error "Kein Import-Pfad moeglich: vhdx-Import schlug fehl und es existiert"
        echo "       kein tar.gz-Fallback ($TEMPLATE_PATH)."
        echo "       Bitte win-setup.ps1 als Admin neu ausfuehren — der Template-"
        echo "       Build entscheidet dort automatisch welches Format nutzbar ist."
        exit 1
    fi
    log_info "Importiere Sandbox-Distro (extrahiert template.tar.gz, 30-120s)..."
    # `if !` statt `cmd; if [ $? -ne 0 ]` — letzteres waere unter set -e tot.
    if ! wsl.exe --import "$DISTRO_NAME" "$WIN_TEMP_DIR" "$WIN_TEMPLATE" 2>&1; then
        log_error "WSL-Import fehlgeschlagen."
        exit 1
    fi
    log_ok "Sandbox-Distro importiert (tar.gz): $DISTRO_NAME"
fi

# --- Sandbox-Init-Skript kopieren ---
# Zielpfad erst leeren, dann neu befuellen — so bleibt garantiert kein
# veraltetes /sandbox-init.sh aus dem Template zurueck.
log_info "Kopiere Sandbox-Init-Skript..."
wsl.exe -d "$DISTRO_NAME" -- rm -f /sandbox-init.sh /tmp/agentbox_*.sh 2>/dev/null
wsl.exe -d "$DISTRO_NAME" -- bash -c "cat > /sandbox-init.sh" < "$SANDBOX_INIT"
wsl.exe -d "$DISTRO_NAME" -- chmod +x /sandbox-init.sh

# --- RAM-Watchdog im Hintergrund starten ---
WATCHDOG_PID=""
(
    RAM_WARN_THRESHOLD=$(cfg_get "resources_ram_warn_percent" "90")
    WATCHDOG_INTERVAL=$(cfg_get "resources_watchdog_interval" "30")
    # Validierung
    if ! [[ "$RAM_WARN_THRESHOLD" =~ ^[0-9]+$ ]] || [ "$RAM_WARN_THRESHOLD" -lt 50 ] || [ "$RAM_WARN_THRESHOLD" -gt 99 ]; then
        RAM_WARN_THRESHOLD=90
    fi
    if ! [[ "$WATCHDOG_INTERVAL" =~ ^[0-9]+$ ]] || [ "$WATCHDOG_INTERVAL" -lt 5 ] || [ "$WATCHDOG_INTERVAL" -gt 300 ]; then
        WATCHDOG_INTERVAL=30
    fi
    WARN_SENT=false
    while true; do
        sleep "$WATCHDOG_INTERVAL"

        # RAM-Auslastung der Sandbox pruefen
        MEM_INFO=$(wsl.exe -d "$DISTRO_NAME" -- bash -c \
            "free -m 2>/dev/null | awk '/^Mem:/{printf \"%d %d\", \$3, \$2}'" 2>/dev/null || echo "")

        if [ -z "$MEM_INFO" ]; then
            # Sandbox nicht mehr erreichbar — Watchdog beenden
            break
        fi

        MEM_USED=$(echo "$MEM_INFO" | awk '{print $1}')
        MEM_TOTAL=$(echo "$MEM_INFO" | awk '{print $2}')

        if [ "$MEM_TOTAL" -gt 0 ] 2>/dev/null; then
            MEM_PERCENT=$(( MEM_USED * 100 / MEM_TOTAL ))

            if [ "$MEM_PERCENT" -ge "$RAM_WARN_THRESHOLD" ] && [ "$WARN_SENT" = false ]; then
                # Windows-Warnung anzeigen
                powershell.exe -NoProfile -Command "[void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms'); \
                    [System.Windows.Forms.MessageBox]::Show( \
                    'agentbox Sandbox \"$PROJECT_NAME\" nutzt ${MEM_PERCENT}% RAM (${MEM_USED}/${MEM_TOTAL} MB). \
Agent eventuell in einer Endlosschleife?', \
                    'agentbox — RAM-Warnung', \
                    'OK', 'Warning')" 2>/dev/null &
                WARN_SENT=true
            fi

            # Reset wenn RAM wieder unter Schwelle
            if [ "$MEM_PERCENT" -lt "$RAM_WARN_THRESHOLD" ]; then
                WARN_SENT=false
            fi
        fi
    done
) &
WATCHDOG_PID=$!

# --- Sandbox starten ---
echo ""
echo -e "${GREEN}=== Starte $AGENT_NAME fuer $PROJECT_NAME ===${NC}"
echo ""

# Config-Werte fuer Sandbox zusammenstellen
SANDBOX_USER=$(cfg_get "sandbox_user" "agent")

# Linux-Pfade (wsl.exe frisst Backslashes beim Argumentpassing).
# `|| EXIT_CODE=$?` statt `; EXIT_CODE=$?` — sonst killt set -e den
# Script vor Watchdog/Session-Diff/Sandbox-Cleanup (Schritte 17-19).
# Unsafe-Mode-Marker (geheim, siehe CLAUDE.md): wenn install.ps1 mit
# `-Unsafe` lief, existiert die Datei und sandbox-init skippt Firewall,
# /mnt-Isolation + Host-IP-DROPs. Loeschen = Safe-Mode wiederherstellen.
UNSAFE_MODE=0
if [ -f "$AGENTBOX_LOCAL_ROOT/unsafe.flag" ]; then
    UNSAFE_MODE=1
    log_info "unsafe_mode aktiv (Firewall/Mount-Isolation aus)"
fi

EXIT_CODE=0
wsl.exe -d "$DISTRO_NAME" -- /sandbox-init.sh \
    "$PROJECT_DIR" "$AGENT_CMD" "$CACHE_DIR" \
    "$SANDBOX_USER" "$AUTH_BASE" "$AGENT_INSTALL" \
    "$AGENTBOX_AUTH_SPEC" "$UNSAFE_MODE" || EXIT_CODE=$?

# --- Watchdog beenden ---
if [ -n "$WATCHDOG_PID" ]; then
    kill "$WATCHDOG_PID" 2>/dev/null || true
    wait "$WATCHDOG_PID" 2>/dev/null || true
fi

# --- Session-Diff erfassen ---
if [ -d "$SESSION_DIR" ] && [ -f "$SESSION_DIR/snapshot.tar.gz" ]; then
    _diff_tmp="/tmp/agentbox_diff_$$"
    mkdir -p "$_diff_tmp"
    tar -xzf "$SESSION_DIR/snapshot.tar.gz" -C "$_diff_tmp" 2>/dev/null || true

    # Diff: Snapshot vs. aktueller Stand
    if [ -d "$PROJECT_DIR/src" ]; then
        diff -ruN "$_diff_tmp/src" "$PROJECT_DIR/src" > "$SESSION_DIR/changes.diff" 2>/dev/null || true
    else
        diff -ruN "$_diff_tmp" "$PROJECT_DIR" \
            --exclude='_tasks' --exclude='assets' --exclude='.git' \
            > "$SESSION_DIR/changes.diff" 2>/dev/null || true
    fi

    # CLAUDE.md-Diff
    if [ -f "$SESSION_DIR/CLAUDE.md" ] && [ -f "$PROJECT_DIR/CLAUDE.md" ]; then
        diff -u "$SESSION_DIR/CLAUDE.md" "$PROJECT_DIR/CLAUDE.md" \
            > "$SESSION_DIR/claude_md.diff" 2>/dev/null || true
    fi

    _diff_lines=$(wc -l < "$SESSION_DIR/changes.diff" 2>/dev/null || echo "0")
    rm -rf "$_diff_tmp"
fi

# --- Sandbox entfernen ---
echo ""
log_info "Entferne Sandbox-Distro..."
wsl.exe --unregister "$DISTRO_NAME" 2>/dev/null || true
log_ok "Sandbox entfernt: $DISTRO_NAME"

echo ""
echo -e "${GREEN}Session beendet.${NC} Code und CLAUDE.md bleiben in: $PROJECT_DIR"

# Session-Info anzeigen
if [ -d "$SESSION_DIR" ]; then
    echo ""
    echo -e "${CYAN}Session-ID:${NC} $SESSION_ID"
    echo -e "${CYAN}Diff:${NC}       ${_diff_lines:-0} Zeilen geaendert"
    echo ""
    echo "Replay mit anderem Agent:"
    echo "  agentbox --replay $SESSION_ID"
    echo ""
    echo "Zwei Sessions vergleichen:"
    echo "  agentbox --compare <session1> <session2>"
fi
echo ""

exit $EXIT_CODE
