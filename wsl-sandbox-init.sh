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
AGENT_INSTALL="${9:-}"

if [ -z "$WIN_PROJECT_PATH" ]; then
    echo "FEHLER: Kein Projektpfad angegeben."
    echo "Verwendung: wsl-sandbox-init.sh <WIN_PROJEKT_PFAD> <AGENT_CMD> [CACHE_PFAD] [SANDBOX_USER] [AI_APIS] [REG_NODE] [REG_PYTHON] [AUTH_BASE] [AGENT_INSTALL]"
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

# --- Sandbox-User anlegen (kein sudo) ---
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

# Kein /etc/wsl.conf-Write hier: die Datei greift erst nach Distro-Neustart,
# und die Sandbox-Distro wird nach der Session verworfen — sie startet nie
# neu. Die tatsaechliche Isolation vom Host-Dateisystem passiert weiter
# unten per manuellem `umount -f /mnt/*` + tmpfs-over-/mnt.

# --- Mount-Punkte erstellen ---
WORKSPACE="/workspace"
mkdir -p "$WORKSPACE/src"
mkdir -p "$WORKSPACE/assets"
mkdir -p "$WORKSPACE/_tasks"

# --- Bind-Mounts mit nosymfollow ---
#
# Wichtig zur remount-Syntax: das `bind` keyword im remount ist
# notwendig, sonst versucht Linux den UNDERLYING-Filesystem zu
# remounten (statt den bind-mount selbst), was bei DrvFs/9P im besten
# Fall ein No-Op und im schlechtesten Fall einen read-only-Downgrade
# triggert. Plus: `rw` muss explizit gesetzt sein — ohne wird der
# bind-mount mit Default-Flags neu aufgesetzt, und die Defaults
# enthalten je nach Kernel-Version kein rw.

# src/ (read-write)
if [ -d "$PROJECT_PATH/src" ]; then
    mount --bind "$PROJECT_PATH/src" "$WORKSPACE/src"
    mount -o remount,bind,rw,nosymfollow,nodev "$WORKSPACE/src"
    echo "[OK] Mount: src/ (read-write, nosymfollow, nodev)"
else
    # Falls kein src/ Ordner existiert, Projektroot mounten
    mount --bind "$PROJECT_PATH" "$WORKSPACE/src"
    mount -o remount,bind,rw,nosymfollow,nodev "$WORKSPACE/src"
    echo "[OK] Mount: Projektroot -> src/ (read-write, nosymfollow, nodev)"
fi

# assets/ (read-only)
if [ -d "$PROJECT_PATH/assets" ]; then
    mount --bind "$PROJECT_PATH/assets" "$WORKSPACE/assets"
    mount -o remount,bind,ro,nosymfollow,nodev "$WORKSPACE/assets"
    echo "[OK] Mount: assets/ (read-only, nosymfollow, nodev)"
else
    echo "[INFO] Kein assets/ Ordner — ueberspringe Mount"
fi

# _tasks/ (read-write)
if [ -d "$PROJECT_PATH/_tasks" ]; then
    mount --bind "$PROJECT_PATH/_tasks" "$WORKSPACE/_tasks"
    mount -o remount,bind,rw,nosymfollow,nodev "$WORKSPACE/_tasks"
    echo "[OK] Mount: _tasks/ (read-write, nosymfollow, nodev)"
fi

# CLAUDE.md (read-write, Einzeldatei-Mount)
if [ -f "$PROJECT_PATH/CLAUDE.md" ]; then
    touch "$WORKSPACE/CLAUDE.md"
    mount --bind "$PROJECT_PATH/CLAUDE.md" "$WORKSPACE/CLAUDE.md"
    mount -o remount,bind,rw "$WORKSPACE/CLAUDE.md" 2>/dev/null || true
    echo "[OK] Mount: CLAUDE.md (read-write)"
fi

# project.json (read-only)
if [ -f "$PROJECT_PATH/project.json" ]; then
    touch "$WORKSPACE/project.json"
    mount --bind "$PROJECT_PATH/project.json" "$WORKSPACE/project.json"
    mount -o remount,bind,ro "$WORKSPACE/project.json"
    echo "[OK] Mount: project.json (read-only)"
fi

# Sanity-Check: kann in /workspace/src tatsaechlich geschrieben werden?
# Wenn dieser Test fehlschlaegt, ist der bind-mount-Pfad kaputt — der
# Agent wuerde sonst spaeter mit "Read-only file system" auflaufen, ohne
# dass die Ursache offensichtlich ist (der [OK] Mount-Output oben sagt
# nichts ueber die tatsaechliche Beschreibbarkeit aus).
_ws_test="$WORKSPACE/src/.workspace_write_test_$$"
if (echo agentbox-test > "$_ws_test") 2>/dev/null; then
    echo "[OK] Workspace-Write-Test: src/ ist beschreibbar"
    rm -f "$_ws_test" 2>/dev/null
else
    echo "[FEHLER] Workspace-Write-Test: src/ ist nicht beschreibbar (Read-only filesystem?)"
    echo "         mount-Ausgabe fuer /workspace/src:"
    mount | grep -F "$WORKSPACE/src" | sed 's/^/           /'
fi

# --- Paket-Cache mounten (persistiert ueber Sessions) ---
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

# --- Auth-State der Agent-CLIs bind-mounten (persistiert Logins) ---
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
    chown "$SANDBOX_USER:$SANDBOX_USER" "$_dst" 2>/dev/null || true

    # Direkter DrvFs-Mount mit explizitem uid/gid + metadata-Flag.
    # Bewusst NICHT mount --bind, weil das die DrvFs-Mount-Properties des
    # /mnt/c-Parent erbt — der ist in importierten Distros normalerweise
    # OHNE metadata gemounted. Dann sind chown/chmod stille No-Ops, der
    # bind-Mount bleibt effektiv root-owned und Claude Code's
    # writeFileSync auf .credentials.json scheitert mit EACCES → Login
    # wird nie persistiert ("Not logged in" direkt nach erfolgreichem
    # OAuth-Flow). Eigener drvfs-Mount mit metadata + uid des Sandbox-
    # Users umgeht das vollstaendig.
    local _uid _gid _win_src
    _uid=$(id -u "$SANDBOX_USER" 2>/dev/null || echo 1000)
    _gid=$(id -g "$SANDBOX_USER" 2>/dev/null || echo 1000)
    _win_src=$(wslpath -w "$_src" 2>/dev/null || echo "")

    if [ -n "$_win_src" ] && \
       mount -t drvfs "$_win_src" "$_dst" \
             -o "metadata,uid=$_uid,gid=$_gid,umask=077" 2>/dev/null; then
        echo "[OK] Mount: $_agent Auth-State ($_home_rel) [drvfs uid=$_uid]"
        return 0
    fi

    # Fallback: bind-mount + chown. Behalten als Sicherheitsnetz fuer
    # Setups, auf denen drvfs metadata aus irgendeinem Grund nicht greift.
    # Wenn der Bind aktiv ist aber chown silent failt, wird der Login
    # nicht persistieren — die erweiterte Diagnostik unten zeigt das.
    if mount --bind "$_src" "$_dst" 2>/dev/null; then
        mount -o remount,nosymfollow,nodev "$_dst" 2>/dev/null || true
        chown -R "$SANDBOX_USER:$SANDBOX_USER" "$_dst" 2>/dev/null || true
        echo "[WARN] Mount: $_agent Auth-State ($_home_rel) [bind-Fallback — Permissions ggf. broken]"
        return 0
    fi
    echo "[WARN] $_agent Auth-Mount fehlgeschlagen — Login wird nicht persistiert"
    return 1
}

# Flag fuer den spaeteren SYSTEM_META_PROMPT.md-Kopier-Schritt: unterdrueckt
# dort das Kopieren von CLAUDE.md, weil die Datei im gemounteten Claude-
# Ordner bereits liegt und wir die User-Session-History nicht ueberschreiben.
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

# --- ~/.claude.json aus Backup wiederherstellen ---
# Claude Code speichert seine Settings (Theme, UserID, Feature-Flags,
# gesehene Tipps — KEINE Credentials) in /home/<user>/.claude.json,
# einer Single-File eine Ebene UEBER dem persistierten .claude/-Mount.
# Die Datei selbst ist deshalb in jeder neuen Sandbox-Distro initial weg.
# Claude Code legt aber automatisch ein Backup unter
# .claude/backups/.claude.json.backup.<timestamp> ab — und das landet
# durch unseren Auth-Mount im persistenten Auth-Cache. Beim naechsten
# Sandbox-Start kopieren wir das neueste Backup zurueck, damit Theme +
# Settings + UI-State ueber Sessions erhalten bleiben und die
# "configuration file not found" Warnungs-Flut beim Start verschwindet.
_CLAUDE_JSON="/home/$SANDBOX_USER/.claude.json"
_CLAUDE_BACKUPS="/home/$SANDBOX_USER/.claude/backups"
if [ ! -f "$_CLAUDE_JSON" ] && [ -d "$_CLAUDE_BACKUPS" ]; then
    _newest_backup=$(ls -t "$_CLAUDE_BACKUPS"/.claude.json.backup.* 2>/dev/null | head -1)
    if [ -n "$_newest_backup" ] && [ -f "$_newest_backup" ]; then
        cp "$_newest_backup" "$_CLAUDE_JSON" 2>/dev/null || true
        chown "$SANDBOX_USER:$SANDBOX_USER" "$_CLAUDE_JSON" 2>/dev/null || true
        chmod 600 "$_CLAUDE_JSON" 2>/dev/null || true
        echo "[OK] .claude.json aus Backup wiederhergestellt: $(basename "$_newest_backup")"
    fi
fi

# --- Auth-Diagnostik (Claude Code .credentials.json) ---
# Claude Code speichert OAuth-Tokens im plaintext-Backend unter
# ~/.claude/.credentials.json (via writeFileSync + chmod 0o600). Dieser
# Pfad liegt im bind-mounted .claude/-Ordner und sollte ueber Sessions
# hinweg persistieren. Falls der Login NICHT erhalten bleibt, zeigt dieser
# Block den Zustand beim Sandbox-Start — damit wir beim Debugging sehen,
# ob die Datei da ist, wem sie gehoert und welche Permissions sie hat.
_CLAUDE_CREDS="/home/$SANDBOX_USER/.claude/.credentials.json"
_CLAUDE_DIR="/home/$SANDBOX_USER/.claude"
echo ""
echo "Claude-Auth-Diagnostik (Start):"
echo "  Mount: $(mountpoint -q "$_CLAUDE_DIR" && echo "ja" || echo "NEIN") → $AUTH_BASE/claude"
echo "  Mount-Owner: $(stat -c '%U:%G mode=%a' "$_CLAUDE_DIR" 2>/dev/null || echo 'stat fehlgeschlagen')"
# Echter Write-Test als Sandbox-User: deckt auf, ob das gemountete
# Verzeichnis tatsaechlich von dem User beschreibbar ist, der gleich
# Claude Code laeuft. Wenn das hier FEHLGESCHLAGEN sagt, scheitert
# auch jeder /login-Versuch danach mit "Not logged in".
_perm_test="$_CLAUDE_DIR/.permission_test_$$"
if su - "$SANDBOX_USER" -c "echo agentbox-test > '$_perm_test'" 2>/dev/null; then
    echo "  Write-Test als $SANDBOX_USER: OK"
    rm -f "$_perm_test" 2>/dev/null
else
    echo "  Write-Test als $SANDBOX_USER: FEHLGESCHLAGEN — Login wird nicht persistieren"
fi
if [ -e "$_CLAUDE_CREDS" ]; then
    echo "  .credentials.json: vorhanden ($(stat -c '%s bytes, mode=%a, owner=%U:%G' "$_CLAUDE_CREDS" 2>/dev/null || echo 'stat fehlgeschlagen'))"
else
    echo "  .credentials.json: FEHLT → erster Login erforderlich"
fi

# --- Windows-Laufwerke isolieren (Sandbox-Isolation) ---
#
# Strategie: tmpfs als OVERMOUNT direkt ueber /mnt legen, OHNE die
# darunter liegenden /mnt/c, /mnt/wsl etc. erst zu unmounten. Linux
# erlaubt covered mounts — die Submounts bleiben im Mount-Tree am Leben
# (refcounts +1, DrvFs-9P-Channel intakt, unsere Bind-Mounts in
# /workspace voll funktionsfaehig), sind aber im Filesystem-Namespace
# nicht mehr ueber /mnt/c... erreichbar, weil das tmpfs den Pfad
# verdeckt. Sandbox-Isolation ist also identisch zum vorherigen
# unmount-Pfad, ohne den DrvFs in irgendeinen "going away"-Zustand
# zu zwingen, der writes mit EROFS abweist.
#
# Frueherer Versuch mit `umount -f` killte den 9P-Channel und brach
# alle Bind-Mounts mit EIO. `umount -l` (lazy) liess Reads zwar leben,
# aber WSL2's DrvFs-Implementation triggerte beim drained-Zustand
# read-only auf neue writes. Overmount umgeht beide Probleme.
echo ""
echo "Isoliere Sandbox von Windows-Dateisystem..."
mount -t tmpfs tmpfs_sandbox /mnt -o size=1k,mode=000,nosuid,nodev,noexec 2>/dev/null || true
# Verifizieren
if [ -e /mnt/c/Users ] 2>/dev/null; then
    echo "[FEHLER] Windows-Laufwerke NICHT isoliert — /mnt/c/Users noch erreichbar!"
    exit 1
else
    echo "[OK] Windows-Laufwerke isoliert (tmpfs ueber /mnt)"
fi

# --- DNS-Fallback sicherstellen ---
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

# --- iptables-Regeln anwenden ---
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

# --- Konnektivitaets-Test: beide Anthropic-Hosts ---
echo ""
echo "Teste Netzwerk-Konnektivitaet..."
for _host in api.anthropic.com platform.claude.com; do
    if getent hosts "$_host" >/dev/null 2>&1; then
        echo "[OK] DNS: $_host aufgeloest"
    else
        echo "[WARN] DNS: $_host NICHT aufgeloest"
    fi
done

# --- Agent Self-Update (als root, vor dem Drop auf $SANDBOX_USER) ---
# Hintergrund: Die eingebauten Auto-Updater von Claude Code, Codex, Gemini
# CLI etc. laufen im Sandbox als unprivilegierter $SANDBOX_USER und
# versuchen im Hintergrund `npm install -g ...` bzw.
# `pip3 install --upgrade ...` in die globalen Pfade — die wurden beim
# Template-Build als root angelegt und sind root-owned. Folge: EACCES,
# "Auto-update failed"-Meldung im Agent. "Manchmal", weil die Updater
# nur dann anschlagen, wenn upstream eine neue Version released wurde.
#
# Loesung: Update hier als root machen, BEVOR auf den Sandbox-User
# gewechselt wird. KEIN Skip-Marker: jeder Sandbox-Start importiert die
# Distro frisch aus dem gecachten Template, d.h. die installierte Agent-
# Version entspricht dem Stand des letzten Template-Builds — eine 24h-
# Skip-Logik wuerde fast jede Session auf einer veralteten Version
# laufen lassen, statt sie zu verhindern. Stattdessen: billiger Versions-
# Vergleich (npm view / pip index, ~1-2s) und das teure Install-Kommando
# nur dann, wenn lokal und remote tatsaechlich diff sind. Steady-state-
# Overhead pro Session: ~2s.
#
# Funktioniert generisch ueber alle Agents: AGENT_INSTALL (Param $9) ist
# der vom Host aus config.json gelesene Install-Cmd des gewaehlten Agents.
# Backend (npm/pip) und Package-Name werden daraus geparst.
_run_agent_update() {
    local _cmd="$AGENT_CMD"
    local _install="$AGENT_INSTALL"

    if [ -z "$_install" ]; then
        echo "[INFO] Kein Update-Command fuer $_cmd in config.json — Versions-Check uebersprungen"
        return
    fi

    # Backend (npm/pip) + Package-Name aus dem Install-Command parsen.
    # Erwartete Formate (Defaults aus config.json):
    #   npm install -g @anthropic-ai/claude-code@latest
    #   npm install -g @openai/codex@latest
    #   npm install -g @google/gemini-cli@latest
    #   pip3 install aider-chat
    #   pip3 install goose-ai
    local _type _last _pkg
    case "$_install" in
        npm*) _type="npm" ;;
        pip*) _type="pip" ;;
        *)
            echo "[INFO] $_cmd: unbekannter Install-Backend-Typ ('$_install') — Versions-Check uebersprungen"
            return
            ;;
    esac

    _last=$(echo "$_install" | awk '{print $NF}')
    _pkg="$_last"
    # @scope/pkg@version  -> @scope/pkg
    if [[ "$_pkg" == @*/*@* ]]; then
        _pkg="${_pkg%@*}"
    # pkg@version (unscoped) -> pkg ; aber NICHT @scope/pkg ohne version anfassen
    elif [[ "$_pkg" == *@* && "$_pkg" != @* ]]; then
        _pkg="${_pkg%@*}"
    fi
    # pip-style version-pin
    _pkg="${_pkg%%==*}"

    if [ -z "$_pkg" ]; then
        echo "[INFO] $_cmd: konnte Package-Name nicht aus '$_install' extrahieren — Versions-Check uebersprungen"
        return
    fi

    # Lokale Version (vom CLI selbst)
    local _local _remote
    _local=$(timeout 5 "$_cmd" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")

    # Remote-Version (cheap, ~1-2s)
    case "$_type" in
        npm)
            command -v npm &> /dev/null || {
                echo "[INFO] $_cmd: npm fehlt im Sandbox — Versions-Check uebersprungen"
                return
            }
            _remote=$(timeout 10 npm view "$_pkg" version 2>/dev/null | tr -d '[:space:]' || echo "")
            ;;
        pip)
            command -v pip3 &> /dev/null || {
                echo "[INFO] $_cmd: pip3 fehlt im Sandbox — Versions-Check uebersprungen"
                return
            }
            _remote=$(timeout 10 pip3 index versions "$_pkg" 2>/dev/null \
                       | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
            # Fallback ueber PyPI-JSON-API, falls `pip index versions`
            # nicht greift (haengt von der pip-Version ab, ist Pre-Release-API).
            if [ -z "$_remote" ] && command -v curl &> /dev/null && command -v python3 &> /dev/null; then
                _remote=$(timeout 10 curl -fsSL "https://pypi.org/pypi/${_pkg}/json" 2>/dev/null \
                           | python3 -c 'import json,sys;print(json.load(sys.stdin)["info"]["version"])' 2>/dev/null \
                           | tr -d '[:space:]' || echo "")
            fi
            ;;
    esac

    if [ -z "$_remote" ]; then
        echo "[INFO] $_cmd: $_type-Registry nicht erreichbar — Versions-Check uebersprungen (lokal: ${_local:-?})"
        return
    fi

    if [ -n "$_local" ] && [ "$_local" = "$_remote" ]; then
        echo "[OK] $_cmd aktuell ($_local)"
        return
    fi

    echo "  $_cmd: ${_local:-?} -> $_remote"
    # Install-Command vom Host weitergegeben → wir respektieren User-Custom-
    # isations (z.B. eine andere npm-Registry oder ein Version-Pin).
    if timeout 120 bash -c "$_install" >/tmp/agent-update.log 2>&1; then
        echo "[OK] $_cmd aktualisiert auf $_remote"
    else
        echo "[WARN] $_cmd Update fehlgeschlagen — Sandbox bleibt auf ${_local:-?}. Letzte Log-Zeilen:"
        tail -5 /tmp/agent-update.log 2>/dev/null | sed 's/^/         /' || true
    fi
    rm -f /tmp/agent-update.log
}

echo ""
echo "Pruefe $AGENT_CMD auf Updates..."
_run_agent_update

# --- SYSTEM_META_PROMPT.md kopieren falls vorhanden ---
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

# --- Workspace-Berechtigungen setzen ---
chown -R "$SANDBOX_USER:$SANDBOX_USER" "$WORKSPACE" 2>/dev/null || true

# --- Agent starten als Sandbox-User ---
# Startverzeichnis: /workspace — das ist der sichtbare Projekt-Root. Alle
# Bind-Mounts (CLAUDE.md, project.json, src/, assets/, _tasks/) haengen
# direkt dort, damit der Agent beim ersten `ls` das komplette Projekt-
# Layout sieht. Frueher war das /workspace/src, was bei Projekten ohne
# eigenen src/-Unterordner dazu fuehrte, dass der Projektcode als
# "Verzeichnis im Verzeichnis" unter /workspace/src versteckt war und
# der User ihn vom Startpunkt aus nicht mehr fand.
START_DIR="$WORKSPACE"

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

# --- Per-Agent Auto-Approve-Flags ---
# Claude/Codex/Goose regeln Auto-Approve ueber ihre persistenten
# Config-Files (in wsl-ai-start.sh geseedet), brauchen hier nichts.
# Gemini und Aider dagegen akzeptieren "alles erlauben" nur per CLI-Flag:
#   - Gemini: settings.json kann laut Docs kein YOLO, nur --approval-mode=yolo
#   - Aider:  ~/.aider.conf.yml liegt ausserhalb des gemounteten .aider/-
#             Ordners und wuerde beim Seeden nicht persistieren
# Hardcoded -> kein Injection-Risiko (AGENT_CMD ist oben alphanumerisch
# validiert, AGENT_FLAGS-Werte sind hier fest verdrahtet).
AGENT_FLAGS=""
case "$AGENT_CMD" in
    gemini) AGENT_FLAGS="--approval-mode=yolo" ;;
    aider)  AGENT_FLAGS="--yes-always" ;;
esac

# Agent als unprivilegierter User starten. `|| EXIT_CODE=$?` statt
# `; EXIT_CODE=$?` — sonst killt set -e den Script vor der
# Blockierte-Verbindungen-Diagnostik (fuer die sie gerade gedacht ist).
EXIT_CODE=0
if command -v "$AGENT_CMD" &> /dev/null; then
    su - "$SANDBOX_USER" -c "cd '$START_DIR' && exec $AGENT_CMD $AGENT_FLAGS" || EXIT_CODE=$?
else
    echo "FEHLER: Agent '$AGENT_CMD' nicht in der Sandbox installiert."
    echo "Bitte Agent in config.json aktivieren und win-setup.ps1 erneut ausfuehren (Template-Rebuild)."
    exit 1
fi

# --- Claude-Auth-Diagnostik (Ende) + sync ---
# Zweite Diagnostik nach Agent-Exit: zeigt, ob Claude Code eine neue
# .credentials.json geschrieben hat (z.B. frischer Login in dieser Session).
# Danach explizit `sync`, damit DrvFs alle Writes gegen den Windows-Host
# flushed, bevor die Distro unregistered wird — sonst koennen neue Tokens
# in der Page-Cache haengen bleiben und beim naechsten Start fehlen.
echo ""
echo "Claude-Auth-Diagnostik (Ende):"
if [ -e "$_CLAUDE_CREDS" ]; then
    echo "  .credentials.json: vorhanden ($(stat -c '%s bytes, mode=%a, owner=%U:%G, mtime=%y' "$_CLAUDE_CREDS" 2>/dev/null || echo 'stat fehlgeschlagen'))"
else
    echo "  .credentials.json: FEHLT — Login wurde nicht persistiert"
fi
sync 2>/dev/null || true

# --- Blockierte Verbindungen analysieren ---
echo ""
echo "Agent beendet (Exit-Code: $EXIT_CODE)"

# Blockierte Pakete aus dem Kernel-Log (unsere LOG-Regel vor dem Final-DROP).
# Das sind Verbindungen, die NICHT 443/80 auf public IPs waren — also entweder
# Versuche in private Netze (Host/LAN-Services) oder auf Nicht-Web-Ports.
BLOCKED_IPS=$(dmesg 2>/dev/null | grep "agentbox-blocked:" | grep -oP 'DST=\K[0-9.]+' | sort -u)

if [ -n "$BLOCKED_IPS" ]; then
    echo ""
    echo "=== Blockierte Verbindungsversuche ==="
    echo "(nicht 443/80 oder in private Netze — Host-Protection-Regeln haben gegriffen)"
    echo ""
    for ip in $BLOCKED_IPS; do
        domain=$(dig +short -x "$ip" 2>/dev/null | head -1 | sed 's/\.$//')
        if [ -n "$domain" ]; then
            echo "  [BLOCKED] $domain ($ip)"
        else
            echo "  [BLOCKED] $ip"
        fi
    done
fi

exit $EXIT_CODE
