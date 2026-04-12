#!/bin/bash
# wsl-ai-start.sh
# agentbox — Agent/Projekt-Auswahl und Sandbox-Lifecycle
# Laeuft in der normalen Host-WSL
# Version: 3.2

set -euo pipefail

# --- Modus-Erkennung ---
AUTO_MODE=false
REPLAY_SESSION=""
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
                echo "FEHLER: --replay braucht eine Session-ID."
                echo "Verfuegbare Sessions: agentbox --list-sessions"
                exit 1
            fi
            shift 2
            ;;
        --list-sessions)
            _sessions_dir="${AI_PROJECTS_ROOT:-}/_control/sessions"
            if [ -d "$_sessions_dir" ]; then
                echo "=== agentbox Sessions ==="
                for s in "$_sessions_dir"/*/; do
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
            ;;
        --compare)
            COMPARE_MODE=true
            COMPARE_SESSIONS=("${2:-}" "${3:-}")
            if [ -z "${COMPARE_SESSIONS[0]}" ] || [ -z "${COMPARE_SESSIONS[1]}" ]; then
                echo "FEHLER: --compare braucht zwei Session-IDs."
                echo "Verwendung: agentbox --compare <session1> <session2>"
                exit 1
            fi
            shift 3
            ;;
        *)
            shift
            ;;
    esac
done

# --- Compare-Modus: Zwei Sessions vergleichen ---
if [ "$COMPARE_MODE" = true ]; then
    _sessions_dir="${AI_PROJECTS_ROOT:-$(echo $HOME)}/_control/sessions"
    _s1="$_sessions_dir/${COMPARE_SESSIONS[0]}"
    _s2="$_sessions_dir/${COMPARE_SESSIONS[1]}"

    if [ ! -d "$_s1" ] || [ ! -d "$_s2" ]; then
        echo "FEHLER: Session nicht gefunden."
        [ ! -d "$_s1" ] && echo "  Nicht gefunden: ${COMPARE_SESSIONS[0]}"
        [ ! -d "$_s2" ] && echo "  Nicht gefunden: ${COMPARE_SESSIONS[1]}"
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

# --- Auto-Modus (aus .bashrc) ---
if [ "$AUTO_MODE" = true ]; then

    # Auto-Start-Timeout aus Config (Fallback: 5s)
    _auto_timeout=5
    _cfg_file="${AI_PROJECTS_ROOT:-}/_control/config.json"
    if [ -f "$_cfg_file" ] && command -v python3 &> /dev/null; then
        _auto_timeout=$(python3 -c "
import json
try:
    with open('$_cfg_file') as f:
        v = json.load(f).get('auto_start_timeout', 5)
    print(int(v) if 1 <= int(v) <= 60 else 5)
except:
    print(5)
" 2>/dev/null || echo 5)
    fi

    echo ""
    echo -e "\033[0;36magentbox starten? [J/n]\033[0m (automatisch in ${_auto_timeout}s)"
    if read -r -t "$_auto_timeout" answer; then
        case "$answer" in
            n|N|nein|Nein) echo "OK — normales Terminal."; exit 0 ;;
        esac
    fi
    echo ""
fi

# --- Konfiguration ---
AI_PROJECTS_ROOT="${AI_PROJECTS_ROOT:-}"
if [ -z "$AI_PROJECTS_ROOT" ]; then
    echo "FEHLER: AI_PROJECTS_ROOT ist nicht gesetzt."
    echo "Bitte zuerst install.ps1 ausfuehren."
    exit 1
fi

CONTROL_DIR="$AI_PROJECTS_ROOT/_control"

# --- config.json laden ---
CONFIG_LIB="$CONTROL_DIR/lib/config.sh"
if [ -f "$CONFIG_LIB" ]; then
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

TEMPLATE_PATH="$CONTROL_DIR/sandbox/template.tar.gz"
SANDBOX_INIT="$CONTROL_DIR/wsl-sandbox-init.sh"
TYPE_DEFAULTS="$CONTROL_DIR/type_defaults.json"
AGENTBOX_CONFIG="$CONTROL_DIR/config.json"

# Farben
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- Hilfsfunktionen ---

log_info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[FEHLER]${NC} $1"; }

# --- 1. Auto-Update pruefen ---
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

        date +%s > "$_last_check_file"

        # Nur updaten wenn remote tatsaechlich neuer ist (lexikografischer Vergleich
        # reicht bei semver-artigen Versionen wie 3.4.5)
        _need_update=false
        if [ -n "$_remote_version" ] && [ -n "$_local_version" ] && [ "$_local_version" != "$_remote_version" ]; then
            _newer=$(printf '%s\n%s\n' "$_local_version" "$_remote_version" | sort -V | tail -1)
            if [ "$_newer" = "$_remote_version" ]; then
                _need_update=true
            fi
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
                echo -e "         ${CYAN}Aktualisiere...${NC}"
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
                            # Dateien kopieren (sandbox/ und cache/ nicht ueberschreiben)
                            find "$_extracted" -maxdepth 1 -mindepth 1 -not -name "sandbox" -not -name "cache" | while read -r item; do
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

                if [ "$_update_ok" = true ]; then
                    echo -e "         ${GREEN}[OK] Update auf Version $_remote_version erfolgreich.${NC}"

                    # Pruefen ob Template-Rebuild noetig (Agent-Config geaendert?)
                    _cfg_hash_file="$CONTROL_DIR/sandbox/.config_hash"
                    _current_hash=""
                    if command -v python3 &> /dev/null && [ -f "$AGENTBOX_CONFIG" ]; then
                        _current_hash=$(python3 -c "
import json, hashlib
try:
    with open('$AGENTBOX_CONFIG') as f:
        data = json.load(f)
    keys = sorted(k for k in data if k.startswith('agent_') or k in ('ubuntu_image_url','nodejs_setup_url'))
    h = hashlib.md5(json.dumps({k: data[k] for k in keys}).encode()).hexdigest()
    print(h)
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

# --- 2. Template pruefen ---
if [ ! -f "$TEMPLATE_PATH" ]; then
    log_error "template.tar.gz nicht gefunden: $TEMPLATE_PATH"
    echo "Bitte zuerst win-setup.ps1 als Admin in PowerShell ausfuehren."
    exit 1
fi

# --- 3. Projektordner scannen ---
echo ""
echo -e "${CYAN}=== agentbox ===${NC}"
echo ""

# Alle Projektordner (ohne _control), sortiert nach letzter Aenderung
projects=()
while IFS= read -r dir; do
    dirname=$(basename "$dir")
    if [ "$dirname" != "_control" ] && [ -d "$dir" ]; then
        projects+=("$dir")
    fi
done < <(find "$AI_PROJECTS_ROOT" -maxdepth 1 -mindepth 1 -type d \
    -not -name "_control" -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)

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

# --- 4. Projekt auswaehlen ---
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

# --- 4b. OneDrive Files-On-Demand: Projektordner lokal pinnen + hydrieren ---
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

# --- 5. project.json pruefen/generieren ---
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

# --- 6. CLAUDE.md generieren falls nicht vorhanden ---
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

# --- 7. CLAUDE.md Backup ---
cp "$CLAUDE_MD" "${CLAUDE_MD}.bak"
log_ok "CLAUDE.md Backup erstellt"

# --- 8. _tasks/ Ordner anlegen ---
TASKS_DIR="$PROJECT_DIR/_tasks"
if [ ! -d "$TASKS_DIR" ]; then
    mkdir -p "$TASKS_DIR"
fi

# --- 8b. Paket-Cache anlegen (persistiert ueber Sessions) ---
CACHE_DIR="$CONTROL_DIR/cache"
mkdir -p "$CACHE_DIR/npm" "$CACHE_DIR/pip"

# --- 8c. Auth-State anlegen (persistiert Agent-Logins ueber Sessions) ---
# Problem: jede agentbox-Session importiert eine frische Sandbox-Distro
# und unregistriert sie hinterher. Die Auth-Ordner der Agent-CLIs
# (~/.claude/, ~/.codex/, ~/.gemini/ etc.) sind damit jedes Mal leer →
# der User muesste bei jedem Start neu einloggen.
#
# Loesung: wir halten den Auth-State auf Host-Seite unter
# %LOCALAPPDATA%\agentbox\auth\<agent>\ vor und bind-mounten ihn in die
# Sandbox. Bewusst NICHT unter _control/cache/, weil _control in OneDrive
# liegt — OAuth-Tokens haben in einem Cloud-synchronisierten Ordner nichts
# verloren.
#
# Agent-IDs dieser Liste muessen zu den Keys in _auth_mount_agent()
# in wsl-sandbox-init.sh passen (Home-relative Pfade stehen dort).
AGENTBOX_AUTH_AGENTS="claude codex gemini aider goose"

AUTH_BASE=""
_win_lad=$(cmd.exe /c "echo %LOCALAPPDATA%" 2>/dev/null | tr -d '\r\n' | tr -d '\000' || true)
if [ -n "$_win_lad" ]; then
    _lin_lad=$(wslpath -u "$_win_lad" 2>/dev/null || true)
    if [ -n "$_lin_lad" ] && [ -d "$_lin_lad" ]; then
        AUTH_BASE="$_lin_lad/agentbox/auth"
        for _aid in $AGENTBOX_AUTH_AGENTS; do
            mkdir -p "$AUTH_BASE/$_aid"
        done
        # SYSTEM_META_PROMPT.md als globale Claude-Code-Memory im
        # Claude-Auth-Ordner ablegen (Claude Code laedt ~/.claude/CLAUDE.md
        # automatisch als globalen Kontext). Ueberschreiben ist bewusst:
        # das ist der agentbox-Vertrag, nicht user-editierbar — bei einem
        # agentbox-Update soll der Agent die neue Version sehen.
        if [ -f /etc/agentbox/SYSTEM_META_PROMPT.md ]; then
            cp /etc/agentbox/SYSTEM_META_PROMPT.md "$AUTH_BASE/claude/CLAUDE.md" 2>/dev/null || true
        fi
        log_ok "Auth-Cache: $AUTH_BASE (Logins persistiert: $AGENTBOX_AUTH_AGENTS)"
    fi
fi
if [ -z "$AUTH_BASE" ]; then
    log_warn "LOCALAPPDATA nicht ermittelbar — Agent-Logins werden NICHT persistiert"
fi

# --- 9. Alte status_*.json loeschen ---
find "$TASKS_DIR" -name "status_*.json" -type f -delete 2>/dev/null || true
log_ok "Alte Status-Dateien bereinigt"

# --- 10. Agent auswaehlen (mit Config-Menue) ---
# Hilfsfunktion: aktivierte Agents aus config.json laden
_load_enabled_agents() {
    agents=()
    agent_cmds=()
    if type cfg_get_agents &> /dev/null; then
        while IFS=: read -r _aid _aname _acmd; do
            if [ -n "$_acmd" ]; then
                agents+=("$_aname")
                agent_cmds+=("$_acmd")
            fi
        done < <(cfg_get_agents)
    fi
    # Fallback: hardcoded falls config.sh nicht geladen
    if [ ${#agents[@]} -eq 0 ]; then
        agents=("Claude Code" "OpenAI Codex")
        agent_cmds=("claude" "codex")
    fi
}

# Config-Untermenue: Agents toggle + Projekte verstecken
_config_menu() {
    while true; do
        echo ""
        echo -e "${CYAN}=== Konfiguration ===${NC}"
        echo ""
        echo "  [1] Agents aktivieren/deaktivieren"
        echo "  [2] Projekte verstecken/einblenden"
        echo "  [q] Zurueck"
        echo ""
        read -r -p "Auswahl: " _cfg_choice
        case "$_cfg_choice" in
            1) _toggle_agents_menu ;;
            2) _toggle_projects_menu ;;
            q|Q|"") return ;;
            *) echo "Ungueltige Auswahl." ;;
        esac
    done
}

_toggle_agents_menu() {
    echo ""
    echo -e "${CYAN}--- Agents ---${NC}"
    echo "Aenderungen werden in config.json gespeichert. Template-Rebuild folgt beim naechsten Start."
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
    done < <(find "$AI_PROJECTS_ROOT" -maxdepth 1 -mindepth 1 -type d \
        -not -name "_control" -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)

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
    log_ok "Agent: $AGENT_NAME"
    break
done

# --- 11. Session-Lock pruefen ---
DISTRO_NAME="agentbox-${PROJECT_NAME}"

existing=$(wsl.exe -l -q 2>/dev/null | tr -d '\r' | grep -c "^${DISTRO_NAME}$" || true)
if [ "$existing" -gt 0 ]; then
    log_error "Session laeuft bereits: $DISTRO_NAME"
    echo "Es kann nur eine Session pro Projekt gleichzeitig laufen."
    echo "Beende die bestehende Session zuerst oder warte bis sie fertig ist."
    exit 1
fi

# --- 12. Session-Snapshot erstellen (fuer Replay-Modus) ---
SESSIONS_DIR="$CONTROL_DIR/sessions"
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

# --- 13. Sandbox-Distro importieren ---
echo ""
log_info "Importiere Sandbox-Distro..."

# Windows-Pfad fuer WSL-Import
WIN_PROJECT_DIR=$(wslpath -w "$PROJECT_DIR" 2>/dev/null || echo "$PROJECT_DIR")
WIN_TEMPLATE=$(wslpath -w "$TEMPLATE_PATH" 2>/dev/null || echo "$TEMPLATE_PATH")

# Windows-Temp-Verzeichnis via cmd.exe ermitteln (USERNAME in WSL != Windows)
WIN_TEMP_BASE=$(cmd.exe /c "echo %TEMP%" 2>/dev/null | tr -d '\r\n' | tr -d '\000')
if [ -z "$WIN_TEMP_BASE" ]; then
    # Fallback: WSL-Pfad via wslpath konvertieren
    WIN_TEMP_BASE=$(wslpath -w /tmp 2>/dev/null || echo "C:\\Temp")
fi
WIN_TEMP_DIR="${WIN_TEMP_BASE}\\agentbox\\${PROJECT_NAME}"

# Zielverzeichnis im Voraus aufraeumen falls existiert
LINUX_TEMP_DIR=$(wslpath -u "$WIN_TEMP_DIR" 2>/dev/null || echo "")
if [ -n "$LINUX_TEMP_DIR" ] && [ -d "$LINUX_TEMP_DIR" ]; then
    rm -rf "$LINUX_TEMP_DIR" 2>/dev/null || true
fi

echo "[INFO] Import-Ziel: $WIN_TEMP_DIR"
echo "[INFO] Template: $WIN_TEMPLATE"

# Alte Sandbox-Distro mit demselben Namen entfernen falls vorhanden
_existing=$(wsl.exe -l -q 2>/dev/null | tr -d '\000' | tr -d '\r' | grep -Fx "$DISTRO_NAME" || true)
if [ -n "$_existing" ]; then
    log_info "Entferne alte Sandbox-Distro: $DISTRO_NAME"
    wsl.exe --unregister "$DISTRO_NAME" 2>&1 | tr -d '\000' || true
fi

wsl.exe --import "$DISTRO_NAME" "$WIN_TEMP_DIR" "$WIN_TEMPLATE" 2>&1
if [ $? -ne 0 ]; then
    log_error "WSL-Import fehlgeschlagen."
    exit 1
fi
log_ok "Sandbox-Distro importiert: $DISTRO_NAME"

# --- 14. Sandbox-Init-Skript kopieren ---
log_info "Kopiere Sandbox-Init-Skript..."
wsl.exe -d "$DISTRO_NAME" -- bash -c "cat > /sandbox-init.sh" < "$SANDBOX_INIT"
wsl.exe -d "$DISTRO_NAME" -- chmod +x /sandbox-init.sh

# --- 15. RAM-Watchdog im Hintergrund starten ---
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

# --- 16. Sandbox starten ---
echo ""
echo -e "${GREEN}=== Starte $AGENT_NAME fuer $PROJECT_NAME ===${NC}"
echo ""

# Config-Werte fuer Sandbox zusammenstellen
SANDBOX_USER=$(cfg_get "sandbox_user" "agent")
CFG_AI_APIS=$(cfg_get_array "firewall_ai_apis" | tr '\n' ' ')
CFG_REG_NODE=$(cfg_get_array "firewall_registries_node" | tr '\n' ' ')
CFG_REG_PYTHON=$(cfg_get_array "firewall_registries_python" | tr '\n' ' ')
# Defaults nur wenn config.json fehlt oder nicht lesbar (nicht bei leeren Arrays)
if [ ! -f "$AGENTBOX_CONFIG" ]; then
    : "${CFG_AI_APIS:=api.anthropic.com api.openai.com generativelanguage.googleapis.com}"
    : "${CFG_REG_NODE:=registry.npmjs.org}"
    : "${CFG_REG_PYTHON:=pypi.org files.pythonhosted.org}"
fi

# Linux-Pfade an sandbox-init.sh uebergeben (Backslashes wuerden beim
# Argumentpassing durch wsl.exe teilweise verschluckt)
wsl.exe -d "$DISTRO_NAME" -- /sandbox-init.sh \
    "$PROJECT_DIR" "$AGENT_CMD" "$CACHE_DIR" \
    "$SANDBOX_USER" "$CFG_AI_APIS" "$CFG_REG_NODE" "$CFG_REG_PYTHON" \
    "$AUTH_BASE"
EXIT_CODE=$?

# --- 17. Watchdog beenden ---
if [ -n "$WATCHDOG_PID" ]; then
    kill "$WATCHDOG_PID" 2>/dev/null || true
    wait "$WATCHDOG_PID" 2>/dev/null || true
fi

# --- 18. Session-Diff erfassen ---
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

# --- 19. Sandbox entfernen ---
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
