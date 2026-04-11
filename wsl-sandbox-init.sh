#!/bin/bash
# wsl-sandbox-init.sh
# agentbox — Sandbox-Initialisierung (laeuft INNERHALB der wegwerfbaren Distro)
# Parameter: $1 = Windows-Pfad zum Projekt, $2 = Agent-Kommando
# Version: 3.2

set -euo pipefail

# --- Parameter ---
WIN_PROJECT_PATH="${1:-}"
AGENT_CMD="${2:-claude}"
WIN_CACHE_PATH="${3:-}"
SANDBOX_USER="${4:-agent}"
AI_API_DOMAINS="${5:-api.anthropic.com api.openai.com generativelanguage.googleapis.com}"
CFG_REG_NODE="${6:-registry.npmjs.org}"
CFG_REG_PYTHON="${7:-pypi.org files.pythonhosted.org}"

if [ -z "$WIN_PROJECT_PATH" ]; then
    echo "FEHLER: Kein Projektpfad angegeben."
    echo "Verwendung: wsl-sandbox-init.sh <WIN_PROJEKT_PFAD> <AGENT_CMD> [CACHE_PFAD] [SANDBOX_USER] [AI_APIS] [REG_NODE] [REG_PYTHON]"
    exit 1
fi

# Windows-Pfade in Linux-Pfade konvertieren
PROJECT_PATH=$(wslpath -u "$WIN_PROJECT_PATH" 2>/dev/null || echo "$WIN_PROJECT_PATH")
CACHE_PATH=""
if [ -n "$WIN_CACHE_PATH" ]; then
    CACHE_PATH=$(wslpath -u "$WIN_CACHE_PATH" 2>/dev/null || echo "$WIN_CACHE_PATH")
fi

echo "=== agentbox Sandbox-Init ==="
echo "Projekt: $PROJECT_PATH"
echo "Agent: $AGENT_CMD"
echo ""

# --- 1. Sandbox-User anlegen (kein sudo) ---
# SANDBOX_USER kommt aus Parameter $4 (Default: "agent")
# Sicherheit: root und system-User verbieten
if [ "$SANDBOX_USER" = "root" ] || [ "$(id -u "$SANDBOX_USER" 2>/dev/null)" = "0" ] 2>/dev/null; then
    echo "FEHLER: Sandbox-User darf nicht 'root' sein — verwende Default 'agent'."
    SANDBOX_USER="agent"
fi
SANDBOX_HOME="/home/$SANDBOX_USER"

if ! id "$SANDBOX_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$SANDBOX_USER" 2>/dev/null || true
    echo "[OK] Sandbox-User '$SANDBOX_USER' angelegt"
fi

# --- 2. Windows-Automount deaktivieren ---
cat > /etc/wsl.conf << 'EOF'
[automount]
enabled = false
mountFsTab = false

[interop]
enabled = false
appendWindowsPath = false
EOF
echo "[OK] Windows-Automount deaktiviert"

# --- 3. Mount-Punkte erstellen ---
WORKSPACE="/workspace"
mkdir -p "$WORKSPACE/src"
mkdir -p "$WORKSPACE/assets"
mkdir -p "$WORKSPACE/_tasks"

# --- 4. Bind-Mounts mit nosymfollow ---

# src/ (read-write)
if [ -d "$PROJECT_PATH/src" ]; then
    mount --bind "$PROJECT_PATH/src" "$WORKSPACE/src"
    mount -o remount,nosymfollow,nodev "$WORKSPACE/src"
    echo "[OK] Mount: src/ (read-write, nosymfollow, nodev)"
else
    # Falls kein src/ Ordner existiert, Projektroot mounten
    mount --bind "$PROJECT_PATH" "$WORKSPACE/src"
    mount -o remount,nosymfollow,nodev "$WORKSPACE/src"
    echo "[OK] Mount: Projektroot -> src/ (read-write, nosymfollow, nodev)"
fi

# assets/ (read-only)
if [ -d "$PROJECT_PATH/assets" ]; then
    mount --bind "$PROJECT_PATH/assets" "$WORKSPACE/assets"
    mount -o remount,ro,nosymfollow,nodev "$WORKSPACE/assets"
    echo "[OK] Mount: assets/ (read-only, nosymfollow, nodev)"
else
    echo "[INFO] Kein assets/ Ordner — ueberspringe Mount"
fi

# _tasks/ (read-write)
if [ -d "$PROJECT_PATH/_tasks" ]; then
    mount --bind "$PROJECT_PATH/_tasks" "$WORKSPACE/_tasks"
    mount -o remount,nosymfollow,nodev "$WORKSPACE/_tasks"
    echo "[OK] Mount: _tasks/ (read-write, nosymfollow, nodev)"
fi

# CLAUDE.md (read-write, Einzeldatei-Mount)
if [ -f "$PROJECT_PATH/CLAUDE.md" ]; then
    touch "$WORKSPACE/CLAUDE.md"
    mount --bind "$PROJECT_PATH/CLAUDE.md" "$WORKSPACE/CLAUDE.md"
    echo "[OK] Mount: CLAUDE.md (read-write)"
fi

# project.json (read-only)
if [ -f "$PROJECT_PATH/project.json" ]; then
    touch "$WORKSPACE/project.json"
    mount --bind "$PROJECT_PATH/project.json" "$WORKSPACE/project.json"
    mount -o remount,ro "$WORKSPACE/project.json"
    echo "[OK] Mount: project.json (read-only)"
fi

# --- 4b. Paket-Cache mounten (persistiert ueber Sessions) ---
if [ -n "$CACHE_PATH" ] && [ -d "$CACHE_PATH" ]; then
    # npm-Cache
    if [ -d "$CACHE_PATH/npm" ]; then
        NPM_CACHE="/home/$SANDBOX_USER/.npm"
        mkdir -p "$NPM_CACHE"
        mount --bind "$CACHE_PATH/npm" "$NPM_CACHE"
        mount -o remount,nosymfollow,nodev "$NPM_CACHE"
        chown -R "$SANDBOX_USER:$SANDBOX_USER" "$NPM_CACHE" 2>/dev/null || true
        echo "[OK] Mount: npm-Cache (persistent)"
    fi

    # pip-Cache
    if [ -d "$CACHE_PATH/pip" ]; then
        PIP_CACHE="/home/$SANDBOX_USER/.cache/pip"
        mkdir -p "$PIP_CACHE"
        mount --bind "$CACHE_PATH/pip" "$PIP_CACHE"
        mount -o remount,nosymfollow,nodev "$PIP_CACHE"
        chown -R "$SANDBOX_USER:$SANDBOX_USER" "$PIP_CACHE" 2>/dev/null || true
        echo "[OK] Mount: pip-Cache (persistent)"
    fi
else
    echo "[INFO] Kein Paket-Cache — Pakete werden bei Bedarf neu geladen"
fi

# --- 5. iptables-Regeln anwenden ---
echo ""
echo "Wende Firewall-Regeln an..."

# Projekttyp aus project.json lesen fuer dynamische Paketquellen
PROJECT_TYPE="generic"
if [ -f "$WORKSPACE/project.json" ] && command -v python3 &> /dev/null; then
    PROJECT_TYPE=$(python3 -c "
import json
try:
    with open('/workspace/project.json') as f:
        print(json.load(f).get('type', 'generic'))
except:
    print('generic')
" 2>/dev/null || echo "generic")
elif [ -f "$WORKSPACE/project.json" ]; then
    # Fallback ohne Python: grep
    PROJECT_TYPE=$(grep -o '"type"[[:space:]]*:[[:space:]]*"[^"]*"' "$WORKSPACE/project.json" \
        | head -1 | sed 's/.*"type"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || echo "generic")
fi

echo "[INFO] Projekttyp: $PROJECT_TYPE"

# Paketquellen basierend auf Projekttyp bestimmen (aus Config-Parametern)
PACKAGE_DOMAINS=""
case "$PROJECT_TYPE" in
    node)
        PACKAGE_DOMAINS="$CFG_REG_NODE"
        echo "[INFO] Paketquelle: $CFG_REG_NODE (Node.js)"
        ;;
    python)
        PACKAGE_DOMAINS="$CFG_REG_PYTHON"
        echo "[INFO] Paketquelle: $CFG_REG_PYTHON (Python)"
        ;;
    *)
        # generic, html, powershell — keine Paketquellen noetig
        echo "[INFO] Keine Paketquellen fuer Typ '$PROJECT_TYPE'"
        ;;
esac

# Basis-Regeln setzen (immer)
iptables -F OUTPUT 2>/dev/null || true
iptables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || true
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT 2>/dev/null || true
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true

# AI-API-Endpoints (immer erlaubt, aus Config)
for domain in $AI_API_DOMAINS; do
    # Domain-Validierung (nur Hostnamen, keine Injection)
    if [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
        for ip in $(dig +short "$domain" 2>/dev/null); do
            if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                iptables -A OUTPUT -p tcp --dport 443 -d "$ip" -j ACCEPT 2>/dev/null || true
            fi
        done
    fi
done

# Paketquellen nur wenn fuer Projekttyp relevant
if [ -n "$PACKAGE_DOMAINS" ]; then
    for domain in $PACKAGE_DOMAINS; do
        for ip in $(dig +short "$domain" 2>/dev/null); do
            if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                iptables -A OUTPUT -p tcp --dport 443 -d "$ip" -j ACCEPT 2>/dev/null || true
            fi
        done
    done
fi

# Alles andere loggen und blockieren
iptables -A OUTPUT -j LOG --log-prefix "agentbox-blocked: " --log-level 4 2>/dev/null || true
iptables -A OUTPUT -j DROP 2>/dev/null || true

echo "[OK] Firewall-Regeln angewendet"

# --- 6. CLI-Update-Check (schnell, max 10s) ---
echo ""
echo "Pruefe CLI-Version..."

if command -v "$AGENT_CMD" &> /dev/null; then
    timeout 10 "$AGENT_CMD" --version 2>/dev/null || echo "[INFO] $AGENT_CMD Version-Check uebersprungen"
else
    echo "[WARN] Agent '$AGENT_CMD' nicht gefunden — ist er installiert?"
fi

# --- 7. SYSTEM_META_PROMPT.md kopieren falls vorhanden ---
META_PROMPT="/etc/agentbox/SYSTEM_META_PROMPT.md"
if [ -f "$META_PROMPT" ]; then
    cp "$META_PROMPT" "$WORKSPACE/SYSTEM_META_PROMPT.md"
    chown "$SANDBOX_USER:$SANDBOX_USER" "$WORKSPACE/SYSTEM_META_PROMPT.md"
fi

# --- 8. Workspace-Berechtigungen setzen ---
chown -R "$SANDBOX_USER:$SANDBOX_USER" "$WORKSPACE" 2>/dev/null || true

# --- 9. Agent starten als Sandbox-User ---
echo ""
echo "======================================"
echo " Starte $AGENT_CMD in /workspace"
echo "======================================"
echo ""

cd "$WORKSPACE"

# Agent-Kommando validieren (nur alphanumerisch + Bindestrich, keine Sonderzeichen)
if ! [[ "$AGENT_CMD" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "FEHLER: Ungueltiges Agent-Kommando '$AGENT_CMD' — nur Buchstaben, Zahlen, Bindestrich erlaubt."
    exit 1
fi

# Agent als unprivilegierter User starten
if command -v "$AGENT_CMD" &> /dev/null; then
    su - "$SANDBOX_USER" -c "cd /workspace && exec $AGENT_CMD"
else
    echo "FEHLER: Agent '$AGENT_CMD' nicht in der Sandbox installiert."
    echo "Bitte Agent in config.json aktivieren und win-setup.ps1 erneut ausfuehren (Template-Rebuild)."
    exit 1
fi

EXIT_CODE=$?

# --- 10. Blockierte Verbindungen analysieren ---
echo ""
echo "Agent beendet (Exit-Code: $EXIT_CODE)"

# Blockierte IPs aus Kernel-Log extrahieren und als Domains aufloesen
BLOCKED_IPS=$(dmesg 2>/dev/null | grep "agentbox-blocked:" | grep -oP 'DST=\K[0-9.]+' | sort -u)

if [ -n "$BLOCKED_IPS" ]; then
    echo ""
    echo "=== Blockierte Verbindungen ==="
    echo ""

    BLOCKED_DOMAINS=""
    for ip in $BLOCKED_IPS; do
        # Reverse-DNS-Lookup
        domain=$(dig +short -x "$ip" 2>/dev/null | head -1 | sed 's/\.$//')
        if [ -n "$domain" ]; then
            echo "  [BLOCKED] $domain ($ip)"
            BLOCKED_DOMAINS="$BLOCKED_DOMAINS $domain"
        else
            echo "  [BLOCKED] $ip (kein Reverse-DNS)"
        fi
    done

    # Vorschlaege fuer config.json
    if [ -n "$BLOCKED_DOMAINS" ]; then
        echo ""
        echo "Falls Pakete nicht installiert werden konnten, ergaenze"
        echo "die fehlenden Domains in config.json:"
        echo ""
        echo "  Fuer Node.js:  \"firewall_registries_node\""
        echo "  Fuer Python:   \"firewall_registries_python\""
        echo "  Fuer AI-APIs:  \"firewall_ai_apis\""
        echo ""
        echo "  Blockierte Domains:$BLOCKED_DOMAINS"
        echo ""
        echo "Danach: win-setup.ps1 erneut ausfuehren (Template-Rebuild)."
    fi
fi

exit $EXIT_CODE
