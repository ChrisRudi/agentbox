# agentbox MCP-Architektur 2.5.0 — Plan

> Status: **Entwurf vor Implementierung**, 2026-04-19.
> Baut auf Commit `b9538ee` (Revert 2.4.0–2.4.3 auf 2.3.0-Stand) auf.
> Ersetzt die File-Queue-Architektur aus 2.4.x komplett.

## 1. Ziel

**Eine einzige Komponente, ein einziges Protokoll, direkter Weg vom
Agent zum MCP-Server.** Alles andere ist Komplexität.

Der Agent in der Sandbox spricht **direkt HTTP/SSE** mit einem
MCP-Server, der auf dem Windows-Host läuft. Keine proxy-Layer, keine
Request/Response-Files, kein Heartbeat-Polling, keine
FileSystemWatcher-Kaskade.

## 2. Begründung des Wegs

**Was 2.4.x falsch gemacht hat:** File-IPC zwischen Sandbox und Host
aufgebaut, weil die Sandbox-Firewall keinen Host-Zugriff erlaubte.
Daraus wuchs:

- `proxy-mcp.js` in der Sandbox (Stdio → File-Queue)
- `passthrough-handler.ps1` auf dem Host (File-Queue → Stdio → MCP)
- Scheduled Task + Supervisor für Handler-Lifecycle
- Heartbeat-Files + PID-Files + Watchers
- ~1800 LOC für einen Call-Roundtrip durch 8 Stationen

Das war **puristisch richtig** (Null Netzwerk-Perforation), aber
**praktisch Overkill**.

**Was sich 2024–2025 in der MCP-Welt geändert hat:**
- MCP-Spec 2025-03-26 machte HTTP-SSE zum offiziellen, gleichwertigen
  Transport neben Stdio
- Alle vier agentbox-Agenten (Claude Code, Codex, Gemini, Goose)
  unterstützen HTTP-MCP nativ in ihrer Config
- Breite Tooling-Unterstützung (mcp-inspector, curl-Debugging)

**Richtiger Trade-off:** eine **gezielte Perforation** pro vom User
aktiviertem MCP-Server. Analog zu "Firefox darf auf Port 443 raus" —
wohldefiniert, vom User autorisiert, auditierbar. Die generelle
Host-/LAN-Isolation bleibt sonst komplett erhalten.

## 3. Architektur-Bild

```
┌────────────────────────────── Windows-Host ──────────────────────┐
│                                                                   │
│   Scheduled Task "agentbox-mcp-dispatcher" (AtLogon)              │
│         │                                                         │
│         ▼                                                         │
│   win-mcp-dispatcher.ps1                                          │
│     ├─► node host-bridge.js  --port 9000  --  python main.py      │
│     │      └─► spawnt MCP-Server als Child (stdio)                │
│     │      └─► exposed SSE auf http://<host-ip>:9000/sse          │
│     │                                                             │
│     └─► node host-bridge.js  --port 9001  --  npx @mcp/github     │
│                                                                   │
└───────────────────────────────────┬───────────────────────────────┘
                                    │ HTTP/SSE
                                    │ (iptables ACCEPT pro Port)
                                    ▼
┌─────────────────────────── WSL2-Sandbox ──────────────────────────┐
│                                                                   │
│   Agent (Claude Code / Codex / Gemini / Goose)                    │
│      │                                                            │
│      └─► liest MCP-Config:                                        │
│              { "kicad": { "url": "http://172.x.x.x:9000/sse" } }  │
│              { "github":{ "url": "http://172.x.x.x:9001/sse" } }  │
│      │                                                            │
│      └─► HTTP/SSE direkt mit host-bridge.js                       │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

Pro Tool-Call: **1 HTTP-Request, 1 SSE-Event**. Fertig.

## 4. Komponenten (Endzustand)

| Datei | Zweck | Sprache | LOC (Ziel) |
|-------|-------|---------|-----------|
| `proxy-mcp/host-bridge.js` | Node-HTTP-Server pro MCP. Spawnt stdio-Child, bridged auf HTTP/SSE gemäß MCP-Spec. Ein Prozess pro MCP. | Node.js (builtins only: `http`, `child_process`, `crypto`) | ~200 |
| `proxy-mcp/setup-mcp.ps1` | Generischer Wizard. Auto-Detect Typ (Python/Node), Entry, Dependencies, .env.example; User gibt Ordner an + Secrets. Schreibt Eintrag in `config.json`. Keine manuellen Prompts. | PowerShell | ~350 |
| `win-mcp-dispatcher.ps1` | Scheduled-Task-Script. Liest `mcp_servers`, weist Ports zu (`ports.json`), spawnt `node host-bridge.js` pro Eintrag, supervised (Restart-on-Crash). | PowerShell | ~150 |
| `wsl-ai-start.sh` (Agent-Config-Inject) | Liest `config.json` + `ports.json` beim Sandbox-Start, schreibt URLs in Agent-Auth-Dirs. **Keine** Mount-Choreografie mehr. | Bash | ~120 (Delta) |
| `wsl-sandbox-init.sh` (Firewall-Erweiterung) | Pro aktiviertem MCP eine iptables-ACCEPT-Regel `<host-ip>:<port>` vor den DROP-Regeln. Keine MCP-Mounts. | Bash | ~30 (Delta) |
| `win-setup-core.ps1` | Prüft Node auf dem Host (winget install OpenJS.NodeJS.LTS wenn fehlt). Registriert Scheduled Task (gleich wie 2.4.x — Task-Name + Trigger unverändert, nur der Inhalt hinter dem Task ist jetzt der neue Dispatcher). Install-Prompt "MCP einbinden?". | PowerShell | ~40 (Delta) |
| `lib/config.sh` (`cfg_get_mcp_servers`) | Parst `mcp_servers` zu `id\|agents_csv`-Zeilen. Keine Tier-Unterscheidung mehr. | Bash | ~30 |

**Neue Dateien (Runtime-State):** `%LOCALAPPDATA%\agentbox\mcp-runtime\ports.json` — Zuordnung id→port, wird vom Dispatcher geschrieben, von wsl-ai-start.sh gelesen.

**Summe neuer Code:** ca. **400–500 LOC netto**, verteilt über die Dateien. Zum Vergleich: 2.4.3 hatte ca. 1800 LOC.

## 5. config.json Schema

```json
"mcp_servers": [
  {
    "id": "kicad",
    "command": "C:\\Program Files\\KiCad\\10.0\\bin\\python.exe",
    "args": ["main.py"],
    "cwd": "C:\\Users\\me\\Projects\\KiCad_MCP",
    "env": {
      "KICAD_CLI_PATH": "C:\\Program Files\\KiCad\\10.0\\bin\\kicad-cli.exe"
    }
  }
]
```

- Identisch zu Claude-Desktop / Cursor-Format
- `agents: [...]` optional — schränkt MCP auf bestimmte Agenten ein (Default: alle)
- Kein `port`-Feld — Ports werden vom Dispatcher automatisch vergeben
- Kein `project`-Feld — Tier 2 ist komplett weg

## 6. host-bridge.js — Vertrag

Aufruf: `node host-bridge.js --id <mcp-id> --port <number> -- <command> [args...]`

Verhalten:
1. Spawnt `<command> [args...]` als Child-Prozess mit Stdin/Stdout-Pipes, `env` vom Parent (Dispatcher reicht Env durch) plus ggf. zusätzliche Env-Variablen per `--env KEY=VALUE`
2. Startet HTTP-Server auf `0.0.0.0:<port>` (horcht auf alle Interfaces, damit WSL-Sandbox ihn über die Host-IP erreicht)
3. **Routes (MCP-Spec 2025-03-26):**
   - `GET /sse` → SSE-Stream, sendet `endpoint`-Event mit `/messages?session_id=...`, dann alle child-stdout-Responses als `message`-Events
   - `POST /messages?session_id=...` → liest JSON-RPC-Body, schreibt an child-stdin
4. **Session-Verwaltung:** eine aktive SSE-Connection pro Session. Neue Connection → neue Session, alte Session wird verworfen.
5. **Stdout-Reader-Line-Mode:** jede vollständige Zeile aus child-stdout ist eine JSON-RPC-Message → zum aktiven SSE-Stream weitergeben
6. **Heartbeat:** alle 30s ein SSE-Comment `: ping` damit Proxies/Firewalls die Verbindung nicht idle-droppen
7. **Child-Crash:** HTTP-Server exitet mit Code 1, Dispatcher restartet uns
8. **Minimal-Security:** Server bindet an Host-IP (nicht 127.0.0.1), aber verlangt `X-MCP-Token` Header? **Nein** — die Sandbox-Firewall ist die Access-Control. Token wäre doppelte Belt-and-suspenders. KISS.

**Warum eigenen Bridge statt npm-`mcp-proxy`:**
- Null neue npm-Dependencies
- Volle Kontrolle über Logging und Restart-Verhalten
- Gleicher Stil wie der alte `proxy-mcp.js` (der gelöschte Sandbox-Proxy) — der Code ist uns vertraut
- Node-HTTP-Spec ist stabil; wir müssen hier nichts exotisches machen

## 7. Port-Management

- Dispatcher ermittelt bei jedem Start freie Ports ab **9000** in der Reihenfolge der `mcp_servers`-Einträge
- Schreibt `%LOCALAPPDATA%\agentbox\mcp-runtime\ports.json`:
  ```json
  { "kicad": 9000, "github": 9001 }
  ```
- `wsl-ai-start.sh` liest diese Datei beim Sandbox-Start; injiziert URLs + iptables-Regeln entsprechend
- Ports werden **neu vergeben** bei jedem Dispatcher-Restart → nach `--reload-mcp` können sich Ports verschieben, aber für die Sandbox ist das transparent (lese-Zeitpunkt ist beim Sandbox-Start)

**Kollisions-Handling:** wenn 9000 belegt (fremder Service), wandern wir hoch bis ein Port frei ist. Max 100 Versuche, dann Fehler.

## 8. Firewall-Regel in der Sandbox

In `wsl-sandbox-init.sh`, **nach** dem `_host_ip`-Detect und **vor** der `iptables -A OUTPUT -d ${_host_ip}/32 -j DROP`-Regel:

```bash
# Pro konfiguriertem MCP eine ACCEPT-Regel fuer Host-IP + spezifischem Port
while IFS='|' read -r _mcp_id _mcp_port; do
    [ -z "$_mcp_id" ] && continue
    [ -z "$_mcp_port" ] && continue
    iptables -A OUTPUT -d "${_host_ip}/32" -p tcp --dport "$_mcp_port" -j ACCEPT 2>/dev/null || true
    log_ok "MCP '$_mcp_id' erreichbar: ${_host_ip}:${_mcp_port}"
done < <(python3 -c "import json; ..." < ports.json)
```

**Kritisch:** Reihenfolge der iptables-Rules. ACCEPT kommt **vor** DROP, sonst sind wir geblockt.

## 9. Agent-Config-Injection

Für die vier Agenten sieht der Eintrag im Auth-Dir unterschiedlich aus:

**Claude Code** (`~/.claude.json` via Backup-Restore):
```json
{
  "mcpServers": {
    "kicad": { "type": "sse", "url": "http://172.x.x.x:9000/sse" }
  }
}
```

**Codex** (`~/.codex/config.toml`):
```toml
[mcp_servers.kicad]
type = "sse"
url  = "http://172.x.x.x:9000/sse"
```

**Gemini CLI** (`~/.gemini/settings.json`):
```json
{
  "mcpServers": {
    "kicad": { "httpUrl": "http://172.x.x.x:9000/sse" }
  }
}
```

**Goose** (`~/.config/goose/config.yaml`):
```yaml
extensions:
  kicad:
    type: sse
    uri: http://172.x.x.x:9000/sse
    enabled: true
```

**Aider** → kein MCP-Support (seit 2.4.0 schon ausgeklammert).

Anchor-Kommentare (`# agentbox-mcp-auto-managed`) markieren unsere
Blöcke für idempotentes Remove, User-eigene MCPs bleiben unberührt.

## 10. User-Flow (End-to-End)

**Einrichtung eines neuen MCPs (am Beispiel eines beliebigen Python-MCP):**

1. User legt MCP-Repo irgendwo auf dem Host ab (z.B. `C:\Projects\MyMcp\`)
2. Startet `agentbox` in einer WSL-Shell → `[c] Konfiguration` → `[4] MCP-Server einbinden`
3. Wizard fragt nach dem Ordner, findet Python-Entry-Point und Dependencies, installiert sie, fragt nach Secrets
4. Schreibt Eintrag in `config.json`, triggert `--reload-mcp`
5. Dispatcher weist Port 9000 zu, startet `host-bridge.js --port 9000 -- python main.py`
6. User startet Sandbox-Session → `wsl-ai-start.sh` liest `ports.json` + `config.json`, injiziert Agent-Configs, baut Firewall-Regel
7. Agent sieht MCP in `/mcp`, Tool-Calls gehen via HTTP direkt an den Host

**Debugging** (wenn was nicht geht):
- `%LOCALAPPDATA%\agentbox\mcp-runtime\dispatcher.log` — Dispatcher-Lifecycle
- `%LOCALAPPDATA%\agentbox\mcp-runtime\<id>\bridge.log` — pro-MCP Bridge-Log
- `curl -N http://127.0.0.1:9000/sse` vom Host aus — roher SSE-Stream, zeigt ob der MCP-Server antwortet
- iptables-Regeln im Sandbox-Log: `log_ok "MCP 'kicad' erreichbar: 172.x.x.x:9000"`

## 11. Migration von 2.4.x

**Nicht nötig**, weil 2.4.x durch den Revert komplett entfernt ist.
User die 2.4.x-Einträge in `mcp_servers` hatten (mit `project`-Key
statt `command`) müssten ihren MCP nochmal via Wizard einbinden — das
trifft aber vermutlich niemanden, weil 2.4.x nur wenige Stunden
produktiv war.

## 12. Release-Klasse

**`minor`.** Kein Template-Rebuild (neue Node-Dependency am Host läuft
via `winget`-Check in `win-setup-core.ps1`, nicht im WSL-Template).
Schema-Bruch in `config.json` ist uncritical, weil 2.4.x eh draußen
ist.

## 13. Implementierungs-Reihenfolge

So, dass der Baum nie in einem "halb-kaputt"-Zustand ist:

1. **`proxy-mcp/host-bridge.js`** schreiben und standalone testbar machen (kein agentbox-Kontext nötig: `node host-bridge.js --id x --port 9000 -- <cmd>` sollte einfach funktionieren)
2. **`win-mcp-dispatcher.ps1`** schreiben — ruft `node host-bridge.js`, verwaltet `ports.json`
3. **`config.json` `_doc_mcp_servers`** dokumentieren + leere `mcp_servers: []` hinzufügen
4. **`lib/config.sh cfg_get_mcp_servers`** hinzufügen
5. **`wsl-ai-start.sh`** erweitern: Agent-Config-Inject + `--reload-mcp` Subcommand + `[4]` im Config-Menü
6. **`wsl-sandbox-init.sh`** erweitern: Firewall-Regeln aus `ports.json` + Host-IP-Auswertung
7. **`win-setup-core.ps1`** erweitern: Node-Check, `Register-AgentboxMcpDispatcher`, `Invoke-AgentboxMcpSetupPrompt`
8. **`proxy-mcp/setup-mcp.ps1`** — der Wizard (letzter Schritt, weil er alle Vorgänger braucht)
9. **README.md + docs/README.de.md** — MCP-Section einfügen
10. **CHANGELOG.md + `.version` = 2.5.0**

Jeder Commit ist für sich kompilierbar und lässt bestehende agentbox-
Features (Projekt-Auswahl, Sandbox-Start ohne MCP, Build/Deploy) intakt.

## 14. Verifikations-Plan

Vor Release auf echtem Windows-Host:

1. **Leerer `mcp_servers`:** Dispatcher läuft durch und exitet clean, keine Host-Services, keine Firewall-Änderung in der Sandbox
2. **Ein Python-MCP eingebunden:** `curl http://127.0.0.1:9000/sse` vom Host zeigt SSE-Stream, `tools/list` über curl liefert Tools
3. **Sandbox-Start:** iptables-Regeln zeigen `ACCEPT` für die spezifischen Ports **vor** dem DROP, Firewall-Seal-Test bleibt grün (RFC1918-Canaries sind immer noch hart geblockt)
4. **Cross-Agent-Test:** gleicher MCP sichtbar in Claude Code, Codex, Gemini, Goose (auch in Aider darf er nicht erscheinen)
5. **`--reload-mcp`:** Dispatcher stoppt und startet neu, Ports werden konsistent wieder zugewiesen, host-bridge.js-Prozesse sind neu, sichtbar via Task-Manager
6. **MCP-Server-Crash:** Dispatcher-Supervisor startet `host-bridge.js` neu innerhalb 5s

## 15. Offene Fragen (vor Implementierung)

Nichts blockierend, aber beim Implementieren zu klären:

- **Wie genau reicht der Dispatcher die `env` aus `config.json` an den Child weiter?** Via Prozess-Environment (Standard) — der Dispatcher setzt die Env auf dem `host-bridge.js`-Prozess, der reicht sie an seinen Child durch. Direkt und sauber.
- **Was wenn Node nicht auf dem Host ist?** `win-setup-core.ps1` prüft `node --version` beim Install, bietet bei Miss `winget install OpenJS.NodeJS.LTS` an.
- **Wie verhält sich host-bridge.js bei Sandbox-Reconnect?** Neue SSE-Connection → alte Session wird discarded. Sollte reichen; MCP-State ist sowieso client-getrieben.
- **SSE statt Streamable HTTP?** Die 2025-03-26-Spec hat beide. SSE ist simpler zu implementieren, alle vier Agenten unterstützen es. Streamable HTTP wäre die "modernere" Variante, aber das ist Future-Work wenn's nötig wird.

---

**Status:** Plan ist vollständig, wartet auf "go" zur Implementierung.
Sobald das gesetzt ist: Punkt 1 (`host-bridge.js`) ist der Start.
