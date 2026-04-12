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
AUTH_BASE_IN="${8:-}"

if [ -z "$WIN_PROJECT_PATH" ]; then
    echo "FEHLER: Kein Projektpfad angegeben."
    echo "Verwendung: wsl-sandbox-init.sh <WIN_PROJEKT_PFAD> <AGENT_CMD> [CACHE_PFAD] [SANDBOX_USER] [AI_APIS] [REG_NODE] [REG_PYTHON] [AUTH_BASE]"
    exit 1
fi

# Pfade normalisieren — akzeptiere sowohl Windows- als auch Linux-Pfade
_to_linux_path() {
    local _in="$1"
    if [ -z "$_in" ]; then
        echo ""
        return
    fi
    # Linux-Pfad (beginnt mit /) → unveraendert lassen
    if [ "${_in:0:1}" = "/" ]; then
        echo "$_in"
        return
    fi
    # Windows-Pfad (enthaelt : oder \) → via wslpath konvertieren
    if [[ "$_in" == *:* ]] || [[ "$_in" == *\\* ]]; then
        wslpath -u "$_in" 2>/dev/null || echo "$_in"
        return
    fi
    # Fallback
    echo "$_in"
}

PROJECT_PATH=$(_to_linux_path "$WIN_PROJECT_PATH")
CACHE_PATH=$(_to_linux_path "$WIN_CACHE_PATH")
AUTH_BASE=$(_to_linux_path "$AUTH_BASE_IN")

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

# --- 4b2. Auth-State der Agent-CLIs bind-mounten (persistiert Logins) ---
# Jede Agent-CLI legt OAuth/API-Keys und Konfig in einem eigenen Home-
# relativen Ordner ab. Ohne Persistierung waere der Ordner in jeder
# ephemeren Sandbox-Distro leer → bei jedem Start muesste der User neu
# einloggen. Mit dem Bind-Mount bleibt der Stand ueber Sessions erhalten.
#
# Mapping muss zu $AGENTBOX_AUTH_AGENTS in wsl-ai-start.sh passen
# (gleicher Satz an Agent-IDs, selbe Subdir-Namen unter $AUTH_BASE).
_auth_mount_agent() {
    local _agent="$1"
    local _home_rel="$2"
    local _src="$AUTH_BASE/$_agent"
    [ -d "$_src" ] || return 1
    local _dst="/home/$SANDBOX_USER/$_home_rel"
    mkdir -p "$_dst"
    if mount --bind "$_src" "$_dst" 2>/dev/null; then
        mount -o remount,nosymfollow,nodev "$_dst" 2>/dev/null || true
        chown -R "$SANDBOX_USER:$SANDBOX_USER" "$_dst" 2>/dev/null || true
        echo "[OK] Mount: $_agent Auth-State ($_home_rel)"
        return 0
    fi
    echo "[WARN] $_agent Auth-Mount fehlgeschlagen — Login wird nicht persistiert"
    return 1
}

# Flag fuer Schritt 7: unterdruecken dann das Kopieren von CLAUDE.md,
# weil die Datei im gemounteten Claude-Ordner bereits liegt und wir die
# User-Session-History nicht ueberschreiben wollen.
CLAUDE_AUTH_PERSISTED=false
if [ -n "$AUTH_BASE" ] && [ -d "$AUTH_BASE" ]; then
    if _auth_mount_agent claude ".claude"; then
        CLAUDE_AUTH_PERSISTED=true
    fi
    _auth_mount_agent codex  ".codex"  || true
    _auth_mount_agent gemini ".gemini" || true
    _auth_mount_agent aider  ".aider"  || true
    _auth_mount_agent goose  ".config/goose" || true
fi

# --- 4c. Windows-Laufwerke unmounten (Sandbox-Isolation) ---
# wsl.conf greift erst nach Distro-Neustart, daher hier manuell.
# WSL mountet /mnt/c u.U. automatisch wieder — daher am Ende tmpfs ueber /mnt.
echo ""
echo "Isoliere Sandbox von Windows-Dateisystem..."
# Alle /mnt Unterverzeichnisse unmounten (WSL DrvFs Automounts)
for _mnt in /mnt/*/; do
    umount -f "$_mnt" 2>/dev/null || umount -l "$_mnt" 2>/dev/null || true
    rmdir "$_mnt" 2>/dev/null || true
done
# tmpfs ueber /mnt — blockiert jeglichen Zugriff und verhindert WSL-Re-Mount
mount -t tmpfs tmpfs_sandbox /mnt -o size=1k,mode=000,nosuid,nodev,noexec 2>/dev/null || true
# Verifizieren
if [ -e /mnt/c/Users ] 2>/dev/null; then
    echo "[FEHLER] Windows-Laufwerke NICHT isoliert — /mnt/c/Users noch erreichbar!"
    exit 1
else
    echo "[OK] Windows-Laufwerke isoliert (tmpfs ueber /mnt)"
fi

# --- 4d. DNS-Fallback sicherstellen ---
# WSL2 generiert /etc/resolv.conf dynamisch, aber in einer importierten Distro
# mit modifiziertem wsl.conf kann das fehlen. Wir setzen einen expliziten Fallback.
echo ""
echo "Konfiguriere DNS..."

# IPv6 deaktivieren — verhindert getaddrinfo EAI_AGAIN auf Hosts die
# AAAA-Records haben aber ueber IPv6 nicht erreichbar sind (WSL2 default).
sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.lo.disable_ipv6=1 >/dev/null 2>&1 || true

# resolv.conf: explizit setzen, Symlink entfernen, immutable machen
rm -f /etc/resolv.conf 2>/dev/null || true
cat > /etc/resolv.conf << 'DNSEOF'
nameserver 1.1.1.1
nameserver 1.0.0.1
nameserver 8.8.8.8
nameserver 8.8.4.4
options timeout:2 attempts:3 single-request-reopen
DNSEOF
chmod 644 /etc/resolv.conf
# Immutable setzen damit WSL es nicht ueberschreibt
chattr +i /etc/resolv.conf 2>/dev/null || true

# /etc/gai.conf: IPv4 vor IPv6 bevorzugen (fallback falls IPv6 doch aktiv ist)
cat > /etc/gai.conf << 'GAIEOF'
precedence ::ffff:0:0/96  100
GAIEOF

# DNS testen
if getent hosts api.anthropic.com >/dev/null 2>&1; then
    echo "[OK] DNS funktioniert (api.anthropic.com aufgeloest)"
else
    echo "[WARN] DNS-Resolution schlaegt fehl — siehe Log"
    sed 's/^/       /' /etc/resolv.conf
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

# Private Netze blockieren (verhindert Zugriff auf Host/LAN-Services)
iptables -A OUTPUT -d 10.0.0.0/8      -j DROP 2>/dev/null || true
iptables -A OUTPUT -d 172.16.0.0/12   -j DROP 2>/dev/null || true
iptables -A OUTPUT -d 192.168.0.0/16  -j DROP 2>/dev/null || true
iptables -A OUTPUT -d 169.254.0.0/16  -j DROP 2>/dev/null || true
iptables -A OUTPUT -d 127.0.0.0/8     -j DROP 2>/dev/null || true

# HTTPS (Port 443) zu allen non-privaten Routen erlauben
# Hostname-basiertes Filtering ist mit reinem iptables nicht zuverlaessig machbar
# (Cloudflare/CDN rotieren IPs). Sicherheit kommt durch Sandbox-Isolation.
iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true

# HTTP (Port 80) nur fuer CA-Cert-Revocation-Checks (OCSP), sonst meistens nicht noetig
iptables -A OUTPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true

# Alles andere loggen und blockieren
iptables -A OUTPUT -j LOG --log-prefix "agentbox-blocked: " --log-level 4 2>/dev/null || true
iptables -A OUTPUT -j DROP 2>/dev/null || true

echo "[OK] Firewall-Regeln angewendet (HTTPS erlaubt, private Netze blockiert)"

# --- 5b. Konnektivitaets-Test: beide Anthropic-Hosts ---
echo ""
echo "Teste Netzwerk-Konnektivitaet..."
for _host in api.anthropic.com platform.claude.com; do
    if getent hosts "$_host" >/dev/null 2>&1; then
        echo "[OK] DNS: $_host aufgeloest"
    else
        echo "[WARN] DNS: $_host NICHT aufgeloest"
    fi
done

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

    # Globale Claude-Code-Memory: wenn Auth-State persistiert ist, liegt
    # CLAUDE.md bereits im gemounteten Ordner (wsl-ai-start.sh hat sie vor
    # dem Sandbox-Start reingeschrieben) und wir ueberschreiben sie NICHT —
    # sonst wuerden wir jeden Persistenz-Zyklus die User-Session-History
    # verwerfen. Im Fallback (kein AUTH_BASE) schreiben wir sie direkt in
    # den ephemeren ~/.claude/-Ordner, damit Claude den Sandbox-Vertrag
    # wenigstens waehrend der aktuellen Session sieht.
    if [ "$CLAUDE_AUTH_PERSISTED" != "true" ]; then
        CLAUDE_HOME="/home/$SANDBOX_USER/.claude"
        mkdir -p "$CLAUDE_HOME"
        cp "$META_PROMPT" "$CLAUDE_HOME/CLAUDE.md"
        chown -R "$SANDBOX_USER:$SANDBOX_USER" "$CLAUDE_HOME"
    fi
fi

# --- 8. Workspace-Berechtigungen setzen ---
chown -R "$SANDBOX_USER:$SANDBOX_USER" "$WORKSPACE" 2>/dev/null || true

# --- 9. Agent starten als Sandbox-User ---
# Startverzeichnis: /workspace/src — dort liegt der Projektcode. Claude Code
# findet CLAUDE.md und project.json per Parent-Directory-Traversal auf
# /workspace automatisch, also ohne Funktionsverlust.
START_DIR="$WORKSPACE/src"
if [ ! -d "$START_DIR" ]; then
    START_DIR="$WORKSPACE"
fi

echo ""
echo "======================================"
echo " Starte $AGENT_CMD in $START_DIR"
echo "======================================"
echo ""

cd "$START_DIR"

# Agent-Kommando validieren (nur alphanumerisch + Bindestrich, keine Sonderzeichen)
if ! [[ "$AGENT_CMD" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "FEHLER: Ungueltiges Agent-Kommando '$AGENT_CMD' — nur Buchstaben, Zahlen, Bindestrich erlaubt."
    exit 1
fi

# Agent als unprivilegierter User starten.
# Exit-Code ueber `|| EXIT_CODE=$?` einfangen: unter `set -e` wuerde ein
# Nicht-Null-Exit des Agents den Script abbrechen — und damit genau die
# Blockierte-Verbindungen-Diagnostik unten ueberspringen, die fuer den
# "npm/pip install ist an der Firewall gescheitert"-Fall gedacht ist.
EXIT_CODE=0
if command -v "$AGENT_CMD" &> /dev/null; then
    su - "$SANDBOX_USER" -c "cd '$START_DIR' && exec $AGENT_CMD" || EXIT_CODE=$?
else
    echo "FEHLER: Agent '$AGENT_CMD' nicht in der Sandbox installiert."
    echo "Bitte Agent in config.json aktivieren und win-setup.ps1 erneut ausfuehren (Template-Rebuild)."
    exit 1
fi

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
