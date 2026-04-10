#!/bin/bash
# wsl-sandbox-init.sh
# agentbox — Sandbox-Initialisierung (laeuft INNERHALB der wegwerfbaren Distro)
# Parameter: $1 = Windows-Pfad zum Projekt, $2 = Agent-Kommando
# Version: 3.2

set -euo pipefail

# --- Parameter ---
WIN_PROJECT_PATH="${1:-}"
AGENT_CMD="${2:-claude}"

if [ -z "$WIN_PROJECT_PATH" ]; then
    echo "FEHLER: Kein Projektpfad angegeben."
    echo "Verwendung: wsl-sandbox-init.sh <WIN_PROJEKT_PFAD> <AGENT_CMD>"
    exit 1
fi

# Windows-Pfad in Linux-Pfad konvertieren
PROJECT_PATH=$(wslpath -u "$WIN_PROJECT_PATH" 2>/dev/null || echo "$WIN_PROJECT_PATH")

echo "=== agentbox Sandbox-Init ==="
echo "Projekt: $PROJECT_PATH"
echo "Agent: $AGENT_CMD"
echo ""

# --- 1. Sandbox-User anlegen (kein sudo) ---
SANDBOX_USER="agent"
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

# --- 5. iptables-Regeln anwenden ---
echo ""
echo "Wende Firewall-Regeln an..."

FIREWALL_SCRIPT="/etc/agentbox/firewall.sh"
if [ -f "$FIREWALL_SCRIPT" ]; then
    bash "$FIREWALL_SCRIPT" 2>/dev/null || {
        echo "[WARN] Firewall-Regeln konnten nicht vollstaendig angewendet werden."
        echo "       (iptables braucht root in der Sandbox — wird beim Start ausgefuehrt)"
    }
else
    # Fallback: Inline-Regeln
    echo "[WARN] firewall.sh nicht gefunden — setze Basis-Regeln inline"

    iptables -F OUTPUT 2>/dev/null || true

    # Loopback
    iptables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true

    # DNS
    iptables -A OUTPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || true
    iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT 2>/dev/null || true

    # Bestehende Verbindungen
    iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true

    # AI-APIs + Package-Registries (ueber DNS aufgeloest)
    for domain in api.anthropic.com api.openai.com generativelanguage.googleapis.com \
                  registry.npmjs.org pypi.org files.pythonhosted.org; do
        for ip in $(dig +short "$domain" 2>/dev/null); do
            if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                iptables -A OUTPUT -p tcp --dport 443 -d "$ip" -j ACCEPT 2>/dev/null || true
            fi
        done
    done

    # Alles andere blockieren
    iptables -A OUTPUT -j DROP 2>/dev/null || true
fi

echo "[OK] Firewall-Regeln angewendet"

# --- 6. CLI-Update-Check (schnell, max 10s) ---
echo ""
echo "Pruefe CLI-Version..."

case "$AGENT_CMD" in
    claude)
        timeout 10 claude --version 2>/dev/null || echo "[INFO] Claude Code Version-Check uebersprungen"
        ;;
    codex)
        timeout 10 codex --version 2>/dev/null || echo "[INFO] Codex Version-Check uebersprungen"
        ;;
    gemini)
        timeout 10 gemini --version 2>/dev/null || echo "[INFO] Gemini CLI Version-Check uebersprungen"
        ;;
esac

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

# Agent als unprivilegierter User starten
case "$AGENT_CMD" in
    claude)
        su - "$SANDBOX_USER" -c "cd /workspace && claude"
        ;;
    codex)
        su - "$SANDBOX_USER" -c "cd /workspace && codex"
        ;;
    gemini)
        su - "$SANDBOX_USER" -c "cd /workspace && gemini"
        ;;
    *)
        echo "FEHLER: Unbekannter Agent '$AGENT_CMD'"
        echo "Erlaubt: claude, codex, gemini"
        exit 1
        ;;
esac

EXIT_CODE=$?

echo ""
echo "Agent beendet (Exit-Code: $EXIT_CODE)"
exit $EXIT_CODE
