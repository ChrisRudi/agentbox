#!/bin/bash
# wsl-ai-start.sh
# agentbox — Agent/Projekt-Auswahl und Sandbox-Lifecycle
# Laeuft in der normalen Host-WSL
# Version: 3.2

set -euo pipefail

# --- Auto-Modus (aus .bashrc) ---
AUTO_MODE=false
if [ "${1:-}" = "--auto" ]; then
    AUTO_MODE=true
    shift

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

        if [ -n "$_remote_version" ] && [ -n "$_local_version" ] && [ "$_local_version" != "$_remote_version" ]; then
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

# --- 4. Projekt auswaehlen ---
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

# --- 9. Alte status_*.json loeschen ---
find "$TASKS_DIR" -name "status_*.json" -type f -delete 2>/dev/null || true
log_ok "Alte Status-Dateien bereinigt"

# --- 10. Agent auswaehlen ---
echo ""
echo "Welcher Agent?"
echo ""

agents=()
agent_cmds=()

# Agents aus config.json laden (nur aktivierte + installierte)
if type cfg_get_agents &> /dev/null; then
    while IFS=: read -r _aid _aname _acmd; do
        if [ -n "$_acmd" ] && command -v "$_acmd" &> /dev/null; then
            agents+=("$_aname")
            agent_cmds+=("$_acmd")
        fi
    done < <(cfg_get_agents)
fi

# Fallback: hardcoded Discovery falls config.sh nicht geladen
if [ ${#agents[@]} -eq 0 ]; then
    if command -v claude &> /dev/null; then
        agents+=("Claude Code")
        agent_cmds+=("claude")
    fi
    if command -v codex &> /dev/null; then
        agents+=("OpenAI Codex")
        agent_cmds+=("codex")
    fi
    if command -v gemini &> /dev/null; then
        agents+=("Gemini CLI")
        agent_cmds+=("gemini")
    fi
fi

if [ ${#agents[@]} -eq 0 ]; then
    log_error "Kein AI-Agent installiert."
    echo "Bitte zuerst win-setup.ps1 ausfuehren oder Agents in config.json aktivieren."
    exit 1
fi

for i in "${!agents[@]}"; do
    echo "  [$((i+1))] ${agents[$i]}"
done
echo ""

read -r -p "Auswahl [1]: " agent_choice
agent_choice=${agent_choice:-1}

if ! [[ "$agent_choice" =~ ^[0-9]+$ ]] || [ "$agent_choice" -lt 1 ] || [ "$agent_choice" -gt ${#agents[@]} ]; then
    log_error "Ungueltige Auswahl."
    exit 1
fi

AGENT_CMD="${agent_cmds[$((agent_choice-1))]}"
AGENT_NAME="${agents[$((agent_choice-1))]}"
log_ok "Agent: $AGENT_NAME"

# --- 11. Session-Lock pruefen ---
DISTRO_NAME="agentbox-${PROJECT_NAME}"

existing=$(wsl.exe -l -q 2>/dev/null | tr -d '\r' | grep -c "^${DISTRO_NAME}$" || true)
if [ "$existing" -gt 0 ]; then
    log_error "Session laeuft bereits: $DISTRO_NAME"
    echo "Es kann nur eine Session pro Projekt gleichzeitig laufen."
    echo "Beende die bestehende Session zuerst oder warte bis sie fertig ist."
    exit 1
fi

# --- 12. Sandbox-Distro importieren ---
echo ""
log_info "Importiere Sandbox-Distro..."

# Windows-Pfad fuer WSL-Import
WIN_PROJECT_DIR=$(wslpath -w "$PROJECT_DIR" 2>/dev/null || echo "$PROJECT_DIR")
WIN_TEMPLATE=$(wslpath -w "$TEMPLATE_PATH" 2>/dev/null || echo "$TEMPLATE_PATH")
WIN_TEMP_DIR="${TEMP:-/mnt/c/Users/$USER/AppData/Local/Temp}/agentbox/${PROJECT_NAME}"

wsl.exe --import "$DISTRO_NAME" "$WIN_TEMP_DIR" "$WIN_TEMPLATE" 2>&1
if [ $? -ne 0 ]; then
    log_error "WSL-Import fehlgeschlagen."
    exit 1
fi
log_ok "Sandbox-Distro importiert: $DISTRO_NAME"

# --- 13. Sandbox-Init-Skript kopieren ---
log_info "Kopiere Sandbox-Init-Skript..."
wsl.exe -d "$DISTRO_NAME" -- bash -c "cat > /sandbox-init.sh" < "$SANDBOX_INIT"
wsl.exe -d "$DISTRO_NAME" -- chmod +x /sandbox-init.sh

# --- 14. RAM-Watchdog im Hintergrund starten ---
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

# --- 15. Sandbox starten ---
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

WIN_CACHE_DIR=$(wslpath -w "$CACHE_DIR" 2>/dev/null || echo "$CACHE_DIR")
wsl.exe -d "$DISTRO_NAME" -- /sandbox-init.sh \
    "$WIN_PROJECT_DIR" "$AGENT_CMD" "$WIN_CACHE_DIR" \
    "$SANDBOX_USER" "$CFG_AI_APIS" "$CFG_REG_NODE" "$CFG_REG_PYTHON"
EXIT_CODE=$?

# --- 16. Watchdog beenden ---
if [ -n "$WATCHDOG_PID" ]; then
    kill "$WATCHDOG_PID" 2>/dev/null || true
    wait "$WATCHDOG_PID" 2>/dev/null || true
fi

# --- 17. Sandbox entfernen ---
echo ""
log_info "Entferne Sandbox-Distro..."
wsl.exe --unregister "$DISTRO_NAME" 2>/dev/null || true
log_ok "Sandbox entfernt: $DISTRO_NAME"

echo ""
echo -e "${GREEN}Session beendet.${NC} Code und CLAUDE.md bleiben in: $PROJECT_DIR"
echo ""

exit $EXIT_CODE
