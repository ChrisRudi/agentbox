#!/bin/bash
# wsl-ai-start.sh
# agentbox — Agent/Projekt-Auswahl und Sandbox-Lifecycle
# Laeuft in der normalen Host-WSL
# Version: 3.2

set -euo pipefail

# --- Konfiguration ---
AI_PROJECTS_ROOT="${AI_PROJECTS_ROOT:-}"
if [ -z "$AI_PROJECTS_ROOT" ]; then
    echo "FEHLER: AI_PROJECTS_ROOT ist nicht gesetzt."
    echo "Bitte zuerst install.ps1 ausfuehren."
    exit 1
fi

CONTROL_DIR="$AI_PROJECTS_ROOT/_control"
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

# --- 1. Template pruefen ---
if [ ! -f "$TEMPLATE_PATH" ]; then
    log_error "template.tar.gz nicht gefunden: $TEMPLATE_PATH"
    echo "Bitte zuerst win-setup.ps1 als Admin in PowerShell ausfuehren."
    exit 1
fi

# --- 2. Projektordner scannen ---
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

# --- 3. Projekt auswaehlen ---
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

# --- 4. project.json pruefen/generieren ---
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

# --- 5. CLAUDE.md generieren falls nicht vorhanden ---
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

# --- 6. CLAUDE.md Backup ---
cp "$CLAUDE_MD" "${CLAUDE_MD}.bak"
log_ok "CLAUDE.md Backup erstellt"

# --- 7. _tasks/ Ordner anlegen ---
TASKS_DIR="$PROJECT_DIR/_tasks"
if [ ! -d "$TASKS_DIR" ]; then
    mkdir -p "$TASKS_DIR"
fi

# --- 8. Alte status_*.json loeschen ---
find "$TASKS_DIR" -name "status_*.json" -type f -delete 2>/dev/null || true
log_ok "Alte Status-Dateien bereinigt"

# --- 9. Agent auswaehlen ---
echo ""
echo "Welcher Agent?"
echo ""

agents=()
agent_cmds=()

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

if [ ${#agents[@]} -eq 0 ]; then
    log_error "Kein AI-Agent installiert."
    echo "Bitte zuerst win-setup.ps1 ausfuehren."
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

# --- 10. Session-Lock pruefen ---
DISTRO_NAME="agentbox-${PROJECT_NAME}"

existing=$(wsl.exe -l -q 2>/dev/null | tr -d '\r' | grep -c "^${DISTRO_NAME}$" || true)
if [ "$existing" -gt 0 ]; then
    log_error "Session laeuft bereits: $DISTRO_NAME"
    echo "Es kann nur eine Session pro Projekt gleichzeitig laufen."
    echo "Beende die bestehende Session zuerst oder warte bis sie fertig ist."
    exit 1
fi

# --- 11. Sandbox-Distro importieren ---
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

# --- 12. Sandbox-Init-Skript kopieren ---
log_info "Kopiere Sandbox-Init-Skript..."
wsl.exe -d "$DISTRO_NAME" -- bash -c "cat > /sandbox-init.sh" < "$SANDBOX_INIT"
wsl.exe -d "$DISTRO_NAME" -- chmod +x /sandbox-init.sh

# --- 13. Sandbox starten ---
echo ""
echo -e "${GREEN}=== Starte $AGENT_NAME fuer $PROJECT_NAME ===${NC}"
echo ""

wsl.exe -d "$DISTRO_NAME" -- /sandbox-init.sh "$WIN_PROJECT_DIR" "$AGENT_CMD"
EXIT_CODE=$?

# --- 14. Sandbox entfernen ---
echo ""
log_info "Entferne Sandbox-Distro..."
wsl.exe --unregister "$DISTRO_NAME" 2>/dev/null || true
log_ok "Sandbox entfernt: $DISTRO_NAME"

echo ""
echo -e "${GREEN}Session beendet.${NC} Code und CLAUDE.md bleiben in: $PROJECT_DIR"
echo ""

exit $EXIT_CODE
