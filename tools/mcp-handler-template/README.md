# mcp-handler-template — Quickstart

Du hast gerade diesen Ordner nach `<AI_Projects_Source>\<dein-mcp-name>\`
kopiert. Gut. So kommst du von hier bis zum funktionierenden MCP-Server:

## 1. Umbenennen im Kopfblock

- `project.json`: `name` auf den Ordnernamen setzen (z.B. `"name": "my-mcp"`).
  `build_whitelist` nur anpassen, wenn du `build.command` aenderst.

## 2. Tools deklarieren

- `tools.json`: das `echo`-Tool rauswerfen oder umbenennen, eigene Tools
  eintragen. Format ist JSON-Schema — siehe MCP-Spec:
  <https://modelcontextprotocol.io/specification/server/tools>
- `name`, `description`, `inputSchema` sind Pflicht pro Tool.
  `description` ist was der Agent sieht, um zu entscheiden wann er das
  Tool nutzt — also praegnant formulieren.

## 3. Handler-Logik schreiben

- `handler.ps1`: in `Invoke-McpTool` den `switch ($Tool) { ... }`-Block
  anpassen. Pro Tool in `tools.json` ein `case`-Zweig. Rueckgabe-Format:

  ```powershell
  return @{
      content = @(
          @{ type = "text"; text = "deine Antwort hier" }
      )
  }
  ```

  Fuer Fehler: `return @{ error = "was schiefging" }` — der Proxy wandelt
  das automatisch in ein `isError`-Tool-Result um, sodass der Agent die
  Meldung sieht.

- Alles rundherum (FileSystemWatcher, Queue-IO, Heartbeat, Logging) ist
  schon implementiert und muss **nicht** angefasst werden. Nur
  `Invoke-McpTool` ist dein Territorium.

## 4. In config.json registrieren

Im agentbox-Repo-Root (`_control/config.json`), Key `mcp_servers`
erweitern:

```json
"mcp_servers": [
  { "id": "my-mcp", "project": "my-mcp" }
]
```

- `id` ist der Name, unter dem der Agent den MCP sieht (also z.B.
  `/mcp` in Claude Code zeigt genau diesen String).
- `project` ist der **Ordnername** hier unter
  `<AI_Projects_Source>\`. Beide sind oft identisch — muessen aber
  nicht. Mehrere MCPs aus demselben Projekt gehen nicht.
- Optional `"agents": ["claude", "codex"]` um den MCP auf
  bestimmte Agenten zu beschraenken; ohne den Key kriegen alle
  aktivierten Agenten ihn.

## 5. `install.ps1` neu als Admin laufen lassen

```powershell
irm https://raw.githubusercontent.com/ChrisRudi/agentbox/main/install.ps1 | iex
```

Das registriert den Scheduled Task `agentbox-mcp-dispatcher` (AtLogon +
RestartOnFailure) und startet den Dispatcher, der deinen handler.ps1
als persistenten Daemon laufen laesst. Ohne diesen Step bleibt der
MCP "registriert aber nicht erreichbar" — der Sandbox-Proxy sieht
keinen Heartbeat und meldet "MCP daemon not running".

## 6. Testen

Sandbox starten (Desktop-Shortcut), Agent waehlen, und:

- **Claude Code**: `/mcp` in der Prompt-Zeile — dein MCP muss
  auftauchen mit den Tools aus `tools.json`.
- **Andere**: jeweilige CLI-Doku. Alle vier (Claude, Codex, Gemini,
  Goose) haben bei erfolgreicher Config einen `tools/list`-Call im
  Startup-Log.

## Debugging

| Symptom | Check |
|---------|-------|
| MCP taucht gar nicht auf | `%LOCALAPPDATA%\agentbox\mcp\proxy-mcp.js` existiert? Agent-Config unter `%LOCALAPPDATA%\agentbox\auth\<agent>\` enthaelt den MCP? |
| Tool-Call Timeout ("MCP daemon not running") | Scheduled Task `agentbox-mcp-dispatcher` laeuft? `Get-ScheduledTask agentbox-mcp-dispatcher` in PowerShell. Handler-Log: `%LOCALAPPDATA%\agentbox\mcp-runtime\<id>\handler.log`. Dispatcher-Log: `%LOCALAPPDATA%\agentbox\mcp-runtime\dispatcher.log`. |
| Tool-Call gibt "handler exception" | `handler.log` in der Runtime zeigt den Stack-Trace. Haeufige Ursache: `Invoke-McpTool` wirft auf unerwartetem Input. |
| Daemon startet nicht | Dispatcher-Log zeigt Whitelist- oder Projekt.json-Validierungs-Fehler. Der Dispatcher refused jeden `build.command`, der nicht **exakt** in `build_whitelist` steht. |

## Weiter-Entwickeln im agentbox-Stil

Du kannst diesen Ordner **als ganz normales agentbox-Projekt** in einer
Sandbox-Session oeffnen — Claude Code sieht `handler.ps1`, `tools.json`,
diese README, und arbeitet wie bei jedem anderen Projekt dran. Dogfood
as intended.

Nach Handler-Aenderungen muss der Daemon aber neu starten — entweder:

- `Stop-ScheduledTask agentbox-mcp-dispatcher; Start-ScheduledTask agentbox-mcp-dispatcher` (Admin-PS)
- oder Logoff/Logon

Die Sandbox-Seite (Proxy) muss **nicht** neu gestartet werden, die
liest Requests jederzeit neu.
