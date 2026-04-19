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
| `proxy-mcp/setup-mcp.ps1` | Generischer Wizard. Auto-Detect Typ (Python/Node), Entry, Dependencies, .env.example; User gibt Ordner an + Secrets. Schreibt Eintrag in `config.json`. Keine manuellen Prompts. | PowerShell | ~350 |
| `win-mcp-dispatcher.ps1` | Scheduled-Task-Script. Liest `mcp_servers`, weist Ports zu (`ports.json`), spawnt `npx mcp-proxy --port X -- <command>` pro Eintrag, supervised (Restart-on-Crash). | PowerShell | ~150 |
| `wsl-ai-start.sh` (Agent-Config-Inject) | Liest `config.json` + `ports.json` beim Sandbox-Start, schreibt URLs in Agent-Auth-Dirs. **Keine** Mount-Choreografie mehr. | Bash | ~120 (Delta) |
| `wsl-sandbox-init.sh` (Firewall-Erweiterung) | Pro aktiviertem MCP eine iptables-ACCEPT-Regel `<host-ip>:<port>` vor den DROP-Regeln. Keine MCP-Mounts. | Bash | ~30 (Delta) |
| `win-setup-core.ps1` | Prüft Node + `mcp-proxy` auf dem Host, installiert stumm via `winget install OpenJS.NodeJS.LTS` + `npm install -g mcp-proxy` wenn fehlend. Registriert Scheduled Task (gleich wie 2.4.x). Install-Prompt "MCP einbinden?". | PowerShell | ~60 (Delta) |
| `lib/config.sh` (`cfg_get_mcp_servers`) | Parst `mcp_servers` zu `id\|port\|agents_csv`-Zeilen. Keine Tier-Unterscheidung mehr. | Bash | ~30 |

**Externe Abhängigkeit:** [`mcp-proxy`](https://www.npmjs.com/package/mcp-proxy) — npm-Paket, standard stdio→SSE-Wrapper für MCP. Wird beim Install automatisch installiert (winget → Node.js; npm → mcp-proxy). User muss nichts manuell machen.

**Neue Dateien (Runtime-State):** `%LOCALAPPDATA%\agentbox\mcp-runtime\ports.json` — Zuordnung id→port, wird vom Dispatcher geschrieben, von wsl-ai-start.sh gelesen.

**Summe neuer Code:** ca. **200–300 LOC netto** (ohne eigene host-bridge.js), verteilt über die Dateien. Zum Vergleich: 2.4.3 hatte ca. 1800 LOC.

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
    },
    "port": 9099
  }
]
```

- Identisch zu Claude-Desktop / Cursor-Format (plus `"port"`-Feld)
- `agents: [...]` optional — schränkt MCP auf bestimmte Agenten ein (Default: alle)
- `port` **optional** — wenn gesetzt, nutzt der Dispatcher exakt diesen Port (für User die Ports festpinnen wollen). Ohne `port` wird automatisch ab 9000 vergeben, gepinnte Ports übersprungen
- Kein `project`-Feld — Tier 2 ist komplett weg

## 6. Stdio→SSE Bridge — via `mcp-proxy` (npm)

Statt eigener Implementierung nutzen wir das etablierte
[`mcp-proxy`](https://www.npmjs.com/package/mcp-proxy) npm-Paket.
Dispatcher ruft es pro MCP als Child-Prozess:

```powershell
npx -y mcp-proxy --port 9000 --shell -- "<command>" <args>
# z.B.
npx -y mcp-proxy --port 9000 --shell -- "python" "main.py"
```

`mcp-proxy` bietet:
- HTTP/SSE-Server auf dem Port (MCP-Spec-konform, inkl. `/sse` + `/messages`)
- Stdio-Child-Spawn mit Pipe
- Session-Handling, Heartbeat, Reconnect
- Auto-Restart bei Child-Crash

**Warum `mcp-proxy` statt eigen:**
- ~200 LOC eigener Code eingespart
- MCP-Spec-Updates kommen via `npm update -g mcp-proxy` automatisch
- Ist in der Community etabliert (wird auch für Claude Desktop stdio→SSE-Wrapping genutzt)

**Auto-Install:** `win-setup-core.ps1` prüft beim Install ob `npm`
und `mcp-proxy` vorhanden sind. Fehlt `npm` → `winget install
OpenJS.NodeJS.LTS`. Fehlt `mcp-proxy` → `npm install -g mcp-proxy`.
Beide stumm (keine Rückfrage), Fehler bei Offline-Host werden klar
protokolliert.

**Minimal-Security:** Server bindet an `0.0.0.0` (damit Sandbox ihn via
Host-IP erreicht). Kein Token — die Sandbox-Firewall ist die
Access-Control (nur Host-IP:<port> geöffnet, nichts sonst).

## 7. Port-Management

Zwei-Phasen-Vergabe:

1. **Phase 1 — Pinned Ports:** alle Einträge mit explizitem `"port": N`
   in config.json bekommen exakt diesen Port. Konflikt (Port belegt von
   fremdem Service oder doppelt in config.json): dieser eine MCP startet
   nicht, Fehler in dispatcher.log; andere MCPs laufen weiter.
2. **Phase 2 — Auto-Assign:** für alle Einträge ohne `port`-Feld wird ab
   **9000** der erste freie Port gesucht, der nicht in Phase 1 belegt
   wurde und auch sonst frei ist (OS-Check via socket-bind-test).

**Ergebnis-Datei:** `%LOCALAPPDATA%\agentbox\mcp-runtime\ports.json`:
```json
{ "kicad": 9099, "github": 9000, "memory": 9001 }
```
(`kicad` hier gepinnt auf 9099, Rest auto.)

`wsl-ai-start.sh` liest diese Datei beim Sandbox-Start; injiziert URLs
+ iptables-Regeln entsprechend.

**Port-Stabilität:** gepinnte Ports bleiben stabil. Auto-Ports können
sich zwischen Reloads verschieben wenn der Vorgänger-Port anderweitig
belegt wurde — für die Sandbox transparent, weil sie Ports erst beim
nächsten Start aus `ports.json` liest.

**Kollisions-Handling:** max 100 Auto-Assign-Versuche pro MCP ab 9000.
Danach Fehler (unwahrscheinlich — würde bedeuten >100 Ports im Bereich
9000–9100 sind belegt).

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

**`major`.** Der Update-Flow soll garantiert `install.ps1` als Admin
neu ausführen, damit:
- Der Scheduled Task `agentbox-mcp-dispatcher` mit dem neuen Dispatcher-
  Inhalt registriert wird
- Node + mcp-proxy auf dem Host installiert werden (wenn nötig)
- Schema-Break in config.json sauber kommuniziert wird

Kein Template-Rebuild (WSL-Template selbst ändert sich nicht).

User-Flow beim Update von 2.4.x oder älter: `agentbox` startet → sieht
die 2.5.0-Änderung → Prompt `[1] Jetzt updaten (Admin) / [2] Spaeter` →
bei `[1]` wird `install.ps1` via WSL-interop + RunAs gestartet.

## 13. Implementierungs-Reihenfolge

Da `host-bridge.js` entfällt (npm mcp-proxy wird genutzt), reduziert
sich die Reihenfolge. Da alles zu einer 2.5.0-Einheit gehört, in einem
Commit bauen — ein einziger `major`-Release-Commit:

1. **`config.json`** — `_doc_mcp_servers` + leere `mcp_servers: []`
2. **`lib/config.sh`** — `cfg_get_mcp_servers` (Output: `id|port|agents_csv`, `port` leer wenn auto)
3. **`win-mcp-dispatcher.ps1`** — Liest config, Port-Assign (2 Phasen), spawnt `npx mcp-proxy`-Instanzen, Supervisor-Loop, schreibt `ports.json`
4. **`wsl-ai-start.sh`** — MCP-Runtime-Ordner, `--reload-mcp`, `_mcp_menu` mit allen Unterpunkten, `_inject_mcp_*` für vier Agent-Config-Formate (URLs via ports.json), weiterreichung von `AGENTBOX_MCP_PORTS` an Sandbox-Init
5. **`wsl-sandbox-init.sh`** — Neue Parameter ($8 MCP_PORTS_SPEC), Firewall-ACCEPT-Regeln **vor** den DROP-Regeln, Host-IP-Auswertung für URLs
6. **`win-setup-core.ps1`** — Node-Check via `Get-Command node`, winget install stumm, npm install -g mcp-proxy stumm, `Register-AgentboxMcpDispatcher` (Task registrieren immer), `Invoke-AgentboxMcpSetupPrompt`
7. **`proxy-mcp/setup-mcp.ps1`** — Wizard (Auto-Detect-Logik, schreibt config-Eintrag ohne `port`-Feld unless User per Flag; KiCad-Spezial-Erkennung)
8. **`README.md` + `docs/README.de.md`** — MCP-Sektion einfügen (Menü-Pfad als Primary, config.json als advanced)
9. **`CHANGELOG.md`** — 2.5.0 dokumentieren
10. **`.version` = 2.5.0**, **`.update_class` = major**
11. **Single commit, push main**

Optionale kleine Verifikation **vor dem Commit**: bash-Syntax-Check auf
allen .sh-Files, `ConvertFrom-Json` auf config.json.

## 14. Verifikations-Plan

Vor Release auf echtem Windows-Host:

1. **Leerer `mcp_servers`:** Dispatcher läuft durch und exitet clean, keine Host-Services, keine Firewall-Änderung in der Sandbox
2. **Ein Python-MCP eingebunden:** `curl http://127.0.0.1:9000/sse` vom Host zeigt SSE-Stream, `tools/list` über curl liefert Tools
3. **Sandbox-Start:** iptables-Regeln zeigen `ACCEPT` für die spezifischen Ports **vor** dem DROP, Firewall-Seal-Test bleibt grün (RFC1918-Canaries sind immer noch hart geblockt)
4. **Cross-Agent-Test:** gleicher MCP sichtbar in Claude Code, Codex, Gemini, Goose (auch in Aider darf er nicht erscheinen)
5. **`--reload-mcp`:** Dispatcher stoppt und startet neu, Ports werden konsistent wieder zugewiesen, host-bridge.js-Prozesse sind neu, sichtbar via Task-Manager
6. **MCP-Server-Crash:** Dispatcher-Supervisor startet `host-bridge.js` neu innerhalb 5s

## 15. Festgelegte Entscheidungen

- **npm `mcp-proxy` statt eigener Bridge** — Community-Tool, spart ~200 LOC
- **Optionaler `port`-Override in config.json** — User kann Ports festpinnen wenn er Host-Firewall-Regeln braucht
- **`.update_class = major`** — garantierter `install.ps1`-Rerun beim Update
- **Node + mcp-proxy Install stumm** — winget + npm laufen ohne Rückfrage durch; Fehler werden klar protokolliert
- **Env-Durchreichung:** Dispatcher setzt Env direkt auf `mcp-proxy`-Kindprozess, der reicht sie automatisch weiter
- **SSE statt Streamable HTTP** — breitere Client-Unterstützung (alle vier Agenten), simpler

---

## 16. Abweichungs-Log (wird während Implementation gefüllt)

Wenn während der Implementation etwas vom Plan abweicht (unerwartete
Constraints, fehlende Features in mcp-proxy, etc.), hier dokumentieren.

*(Aktuell keine Abweichungen — Implementation läuft.)*

---

**Status:** Plan finalisiert, Implementation läuft. Ergebnis kommt als
single 2.5.0-Commit auf main.
