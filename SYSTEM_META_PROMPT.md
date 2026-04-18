# SYSTEM_META_PROMPT.md
# Arbeitsvertrag fuer AI-Agenten in der agentbox-Sandbox

## Dein Arbeitsbereich

Du arbeitest in `/workspace/` — das ist dein Projekt-Root und dein
Startverzeichnis. Hier liegt das komplette Projekt-Layout direkt sichtbar,
unabhaengig davon, wie die Ordnerstruktur auf dem Host heisst.

Die Struktur sieht so aus:

```
/workspace/              ← Projekt-Root (hier startet der Agent)
  src/                   ← Quellcode-Verzeichnis (read-write)
  assets/                ← Statische Dateien (read-only)
  _tasks/                ← Task-Trigger fuer Build/Deploy (read-write)
  CLAUDE.md              ← Session-Kontinuitaet (read-write)
  project.json           ← Projektkonfiguration (read-only)
  SYSTEM_META_PROMPT.md  ← dieser Arbeitsvertrag (read-only)
```

Der Code liegt ueblicherweise unter `src/`; bei Projekten ohne eigenen
`src/`-Unterordner ist `/workspace/src/` direkt der Projektroot. Alle
Aenderungen innerhalb der Bind-Mounts werden direkt auf dem Host-Dateisystem
persistiert (auch nach Sandbox-Loeschung).

Dein Projekt ist beschrieben in `project.json` im Projektroot.
Lies diese Datei zu Beginn, um den Projekttyp und die Konfiguration zu verstehen.

## Netzwerk — was du erreichst und was nicht

Du hast **Internet-Zugriff**, aber nicht unbeschraenkt. Die Firewall
der Sandbox (iptables default-deny OUTPUT) erlaubt nur:

- **TCP/443 (HTTPS)** und **TCP/80 (HTTP)** raus zu **oeffentlichen
  IPs** — `curl`, `wget`, `git clone https://…`, `npm install`,
  `pip install`, Dokumentations-Seiten, GitHub, Registry-APIs
  funktionieren also.
- **DNS (UDP/53 + TCP/53)** fuer Namensaufloesung.

Geblockt (per `iptables -j DROP`):

- **Private Netze**: `10/8`, `172.16/12`, `192.168/16`, `169.254/16`,
  `127/8`, Multicast `224/4`, explizit die Host-Gateway-IP. Du
  erreichst also weder den Windows-Host noch andere LAN-Geraete,
  keinen Cloud-Metadata-Endpoint, keine anderen WSL-Distros.
- **Alle Ports ausser 80/443/53.** SSH (22), SMTP (25), IRC,
  IMAP etc. sind zu.
- **IPv6** gleich behandelt (ULA `fc00::/7`, link-local `fe80::/10`,
  loopback blockiert; Public-IPv6 ueber 443/80/53 offen).

Woran du's merkst: `curl -sS https://api.github.com` = OK.
`curl http://192.168.1.1` = timeout/DROP. `ssh foo@host` = timeout.

Was du trotzdem NICHT kannst:

- Zugriff auf **andere Projekte** am Host.
- Zugriff auf das **Host-Dateisystem** (kein `/mnt/c`).
- `sudo` oder Adminrechte.
- Symlinks nach ausserhalb der Bind-Mounts anlegen.

## Build und Deploy

Du kannst Build/Deploy **nicht selbst** ausfuehren — in der Sandbox
sind bewusst keine Build-Tools (node, python, dotnet, make, pwsh …)
installiert. Das ist Security-Design: dein einziger Weg zu Host-
Execution ist der Task-Runner mit Whitelist-Validierung.

### Wie der Build-Flow laeuft (End-to-End)

```
  [du in der Sandbox]                   [Windows-Host, ausserhalb Sandbox]
  ───────────────────────               ──────────────────────────────────
  1. schreibe _tasks/build_001.tmp
  2. mv .tmp → .json                    3. win-task-runner.ps1 sieht .json
                                        4. liest project.json:build.command
                                        5. prueft gegen build_whitelist
                                           (exakter String-Match in config.json)
                                        6. cmd.exe /c cd /d <ProjectDir>
                                              && <build.command>
                                           ↑ laeuft auf dem Host, nicht hier!
                                        7. schreibt _tasks/status_build.json
  8. pollst status_build.json
  9. liest Ergebnis + evtl. Output-
     Dateien im Projekt-Root
```

Kernpunkt: **Der Build laeuft auf dem Host, nicht in der Sandbox.**
Der Runner `cd`t vorher ins Projekt-Verzeichnis, daher kannst du in
`build.command` relative Pfade verwenden (`build.ps1`, `package.json`-
Scripts, etc.).

### So triggerst du einen Build (kanonisch)

1. Erstelle die Task-Datei zuerst als `.tmp` (der Runner ueberwacht
   nur `.json` — der Rename sorgt fuer atomar vollstaendige Datei):

```bash
cat > /workspace/_tasks/build_001.tmp << 'EOF'
{
  "project": "PROJEKTNAME",
  "action": "build",
  "timestamp": "2025-01-15T14:30:00"
}
EOF
```

2. Rename zu `.json`:

```bash
mv /workspace/_tasks/build_001.tmp /workspace/_tasks/build_001.json
```

3. Poll das Status-File, bis fertig:

```bash
while [ ! -f /workspace/_tasks/status_build.json ] || \
      grep -q '"status": "running"' /workspace/_tasks/status_build.json; do
    sleep 1
done
cat /workspace/_tasks/status_build.json
```

### Erlaubte Aktionen

- `"action": "build"` — fuehrt `project.json:build.command` aus.
  Command muss in `config.json:build_whitelist` stehen (exakter
  Match). Typische Whitelist-Eintraege: `npm run build`, `npm install`,
  `pip install -r requirements.txt`, `make`, `dotnet build`,
  `powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1`.
- `"action": "deploy"` — fuehrt `project.json:deploy.target` aus.
  Target muss in `config.json:deploy_whitelist` stehen (`local` |
  `github`).

Andere Aktionen werden abgelehnt. Du kannst `project.json` nicht
editieren (read-only fuer dich) — der gueltige Build-Command wurde
vom Host-User oder per Auto-Detect gesetzt.

### Ergebnis pruefen

- `/workspace/_tasks/status_build.json` (nach build)
- `/workspace/_tasks/status_deploy.json` (nach deploy)

| Status    | Bedeutung                               |
|-----------|-----------------------------------------|
| `running` | Aktion wird gerade ausgefuehrt          |
| `done`    | Aktion erfolgreich abgeschlossen        |
| `failed`  | Aktion fehlgeschlagen (mit Fehlerdetail)|

Beispiel (Erfolg):

```json
{ "status": "done", "timestamp": "2025-01-15T14:30:05" }
```

Beispiel (Fehler):

```json
{
  "status": "failed",
  "timestamp": "2025-01-15T14:30:05",
  "error": "Build-Kommando nicht in Whitelist: '...'"
}
```

Haeufige Fehler:
- `"Build-Kommando nicht in Whitelist"`: `project.json:build.command`
  matched keinen Whitelist-Eintrag character-fuer-character. Du
  kannst das nicht selbst fixen — User muss `config.json` erweitern.
- `"Build fehlgeschlagen mit Exit-Code N"`: das Build-Script selbst
  hat einen Fehler. Debug via Projekt-Code, nicht via Infrastruktur.

## Session-Kontinuitaet mit CLAUDE.md

`CLAUDE.md` liegt in `/workspace/CLAUDE.md` — lies sie zu Beginn jeder Session.

Sie enthaelt den Stand der letzten Session:
- Offene Punkte
- Getroffene Entscheidungen
- Naechste Schritte

**Aktualisiere CLAUDE.md am Ende jeder Session** mit deinem aktuellen Stand,
damit die naechste Session nahtlos weitermachen kann.

Regeln fuer CLAUDE.md:
- Schreibe keine Session-History, sondern nur den **aktuellen Stand**.
- CLAUDE.md ist ein lebendes Dokument, kein Log.
- Halte es kurz und praegnant: Was ist der Stand? Was fehlt noch? Was wurde entschieden?
