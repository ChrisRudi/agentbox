<p align="center">
  <h1 align="center">agentbox</h1>
  <p align="center">
    <strong>AI-Coding-Agenten haben vollen Zugriff auf dein Dateisystem.<br>agentbox aendert das.</strong>
  </p>
  <p align="center">
    <a href="#installation">Installation</a> · <a href="#unterstuetzte-agenten">Agenten</a> · <a href="#taegliche-nutzung">Nutzung</a> · <a href="#sicherheitsmodell">Sicherheit</a> · <a href="#konfiguration">Config</a>
  </p>
  <p align="center">
    🌍 <a href="../README.md">English</a>
  </p>
</p>

---

**KI-Coding-Agenten loesen Probleme — und zerstoeren dabei dein System:**

- Sie machen deinen Rechner lahm — fressen RAM und CPU ohne Limit
- Sie ruinieren dein OS — Caches, Reste, irgendwann startet Windows nicht mehr sauber
- Sie stehlen deine Secrets — SSH-Keys, `.env`-Dateien, Passwoerter
- Sie liegen offen im Netzwerk — dein Host und LAN sind erreichbar
- Sie vergessen alles — nach der Session ist der Kontext weg
- Sie fragen staendig nach — weil dein System auf dem Spiel steht

**In einer Sandbox nicht.**

Ein Befehl. Saubere Umgebung. Volle Kontrolle.
Windows nativ. Kein Docker. Kein Kubernetes.

**agentbox** startet KI-Coding-Agenten in **wegwerfbaren WSL2-Distributionen** mit echter Dateisystem- und Netzwerkisolation — und gibt dir die Produktivitaet von KI-Agenten **ohne das Risiko**.

## Unterstuetzte Agenten

| Agent | Standard | Paketmanager | Aktivieren |
|-------|----------|-------------|------------|
| **Claude Code** (Anthropic) | Aktiviert | npm | — |
| **OpenAI Codex** (OpenAI) | Aktiviert | npm | — |
| **Gemini CLI** (Google) | Aktiviert | pip | — |
| **Aider** | Deaktiviert | pip | `agent_aider_enabled` in `config.json` auf `true` setzen |
| **Goose** (Block) | Deaktiviert | pip | `agent_goose_enabled` in `config.json` auf `true` setzen |

Zusaetzliche Agenten aktivieren → `config.json` editieren → `install.ps1` erneut ausfuehren (Template-Rebuild).

## Installation

Ein Befehl in einer Admin-PowerShell:

```powershell
irm https://raw.githubusercontent.com/ChrisRudi/agentbox/main/install.ps1 | iex
```

Das wars. WSL-Terminal oeffnen — agentbox startet automatisch.

### Update

Gleicher Befehl. Wenn agentbox bereits installiert ist, wird die neueste Version gezogen und das Template neu gebaut (inklusive neu aktivierter Agenten).

<details>
<summary>Was passiert bei der Installation?</summary>

1. Repository wird nach `AI_Projects_Source\_control` geklont (oder eigener Pfad)
2. WSL2-Template wird gebaut (Ubuntu-Minimal + Node.js + Python3 + aktivierte AI-CLIs)
3. Windows Event-Source und Scheduled Task werden angelegt
4. WSL `.bashrc` wird konfiguriert (Auto-Start)
5. Desktop-Shortcut `agentbox.lnk` wird erstellt
6. `.wslconfig` mit Ressourcen-Limits gesetzt (konfigurierbar ueber `config.json`)

Dauer: ca. 3-5 Minuten, einmalig. Updates sind schneller.
</details>

### Speicherort

Standardmaessig nutzt agentbox `OneDrive\AI_Projects_Source\`. Du kannst **jeden beliebigen Ordner** verwenden:

| Speicher | Konfiguration |
|----------|--------------|
| **OneDrive** (Standard) | Funktioniert sofort |
| **Google Drive** | `base_path_override` in `config.json` auf deinen Google Drive-Pfad setzen |
| **Dropbox** | `base_path_override` in `config.json` auf deinen Dropbox-Pfad setzen |
| **Lokaler Ordner** | `base_path_override` auf beliebigen Pfad setzen, z.B. `D:\Dev\AgentProjects` |

Beispiel in `config.json`:
```json
"base_path_override": "D:\\GoogleDrive\\AI_Projects"
```

## Schnellstart: Projekte einrichten

### Neues Projekt

Erstelle einen Ordner im Projektverzeichnis — agentbox erkennt den Typ beim ersten Start automatisch:

```
AI_Projects_Source\
+-- MeineNeueApp\
    +-- src\
        +-- index.js      ← agentbox erkennt "node"
```

Eine `project.json` wird automatisch generiert. Du kannst sie auch manuell erstellen:

```json
{
  "name": "MeineNeueApp",
  "type": "node",
  "version": "1.0.0",
  "build": { "command": "npm run build", "output_dir": "build_out" },
  "deploy": { "target": "", "url": "" },
  "agent": { "working_dir": "src", "entry_point": "index.js" }
}
```

### Bestehendes Projekt einbinden

Verschiebe oder kopiere deinen Projektordner nach `AI_Projects_Source\`:

```powershell
# PowerShell — bestehendes Projekt kopieren
Copy-Item -Recurse "D:\Dev\mein-projekt" "$env:OneDrive\AI_Projects_Source\mein-projekt"
```

agentbox erwartet diese Struktur (nur `src/` ist Pflicht):

```
mein-projekt\
+-- src\              ← dein Code (read-write in der Sandbox)
+-- assets\           ← statische Dateien (read-only in der Sandbox, optional)
```

Falls dein Projekt keinen `src/`-Ordner hat, wird stattdessen der Projekt-Root als `src/` gemountet.

### project.json Referenz

| Feld | Pflicht | Beschreibung |
|------|---------|-------------|
| `name` | Ja | Projektname (entspricht dem Ordnernamen) |
| `type` | Ja | `node`, `python`, `html`, `powershell` oder `generic` |
| `version` | Nein | Semantische Version (Standard: `1.0.0`) |
| `build.command` | Nein | Muss in der Build-Whitelist stehen (siehe `config.json`) |
| `build.output_dir` | Nein | Build-Ausgabeverzeichnis (Standard: `build_out`) |
| `deploy.target` | Nein | `local` oder `github` (muss in der Deploy-Whitelist stehen) |
| `agent.working_dir` | Nein | Arbeitsverzeichnis im Projekt (Standard: `src`) |
| `agent.entry_point` | Nein | Hauptdatei (informativ, fuer den Agenten) |

Automatisch erkannte Typen und ihre Defaults:

| Gefundene Dateien | Erkannter Typ | Standard-Build-Befehl |
|-------------------|--------------|----------------------|
| `package.json` | `node` | `npm run build` |
| `*.py` | `python` | `pip install -r requirements.txt` |
| `*.ps1` | `powershell` | — |
| `*.html` | `html` | — |
| (nichts davon) | `generic` | — |

## Taegliche Nutzung

WSL-Terminal oeffnen (oder Doppelklick auf den Desktop-Shortcut):

```
agentbox starten? [J/n] (automatisch in 5s)

=== agentbox ===

Welches Projekt?
  [1] MeinProjekt (zuletzt)
  [2] AnderesProjekt
Auswahl [1]: 1

Welcher Agent?
  [1] Claude Code
  [2] OpenAI Codex
  [3] Gemini CLI
Auswahl [1]: 1

=== Starte Claude Code fuer MeinProjekt ===
```

> **Agent arbeitet → Session endet → Sandbox wird geloescht → Code bleibt.**

Es werden nur Agenten angezeigt, die in `config.json` **aktiviert** und im Template **installiert** sind.

## Sicherheitsmodell

### Dateisystem-Isolation

Der Agent sieht **nur**:

```
/workspace/                    ← Projekt-Root und Startverzeichnis des Agenten
  src/           (read-write)   Dein Code
  assets/        (read-only)    Statische Dateien
  _tasks/        (read-write)   Task-Trigger
  CLAUDE.md      (read-write)   Session-Kontext
  project.json   (read-only)    Konfiguration
```

Der Agent startet in `/workspace/`, sodass das komplette Projekt-Layout beim ersten `ls` sichtbar ist. Projekte ohne `src/`-Unterordner bekommen ihren Projekt-Root als `/workspace/src/` bind-gemountet.

Der Agent sieht **nicht**: `/mnt/c/`, OneDrive, `~/.ssh/`, andere Projekte, `_control/`.

Verzeichnis-Mounts: `nosymfollow` + `nodev`; Hardlink-Schutz via `sysctl`.

### Netzwerk-Isolation — Was tatsaechlich passiert

**agentbox schuetzt deine Maschine vor dem Agent, nicht das Internet vor dem Agent.**

Die iptables-Regeln in der Sandbox setzen durch:

| Erlaubt | Blockiert |
|---------|-----------|
| Outbound HTTPS/HTTP zu public IPs | Zugriff auf private Netze (`10/8`, `172.16/12`, `192.168/16`, `169.254/16`, `127/8`) |
| DNS (Port 53) | Alle Nicht-HTTP(S)-Ports |

Das Wichtige sind die DROPs auf private Netze: sie verhindern, dass der Agent deinen Windows-Host, LAN-Dienste, Metadata-Endpoints oder andere WSL-Distros erreicht. Das ist das Client-Protection-Threat-Model.

**Was agentbox NICHT macht:** Per-Domain-Egress-Filtering. iptables kann Hostnamen nicht zuverlaessig matchen (CDNs rotieren IPs mitten im Request), also gibt es kein tatsaechlich durchgesetztes Whitelist. Ein Agent mit Netzwerk-Zugriff *kann* waehrend einer Session jeden oeffentlichen HTTPS-Endpunkt erreichen. Wer das im Threat-Model hat, braucht einen Egress-Proxy — agentbox liefert keinen mit.

Die Keys `firewall_ai_apis` / `firewall_registries_node` / `firewall_registries_python` in der `config.json` sind **Altlasten aus einem frueheren Design** und haben **keinen Runtime-Effekt**. Sie bleiben im Schema nur um bestehende Configs nicht zu brechen — behandle sie als ungenutzt.

### Ressourcen-Limits

- `.wslconfig`: konfigurierbar ueber `config.json` (Standard: 4 GB RAM, 2 CPUs, 1 GB Swap)
- **RAM-Watchdog**: Warnt per Windows-Dialog wenn Sandbox Schwellwert ueberschreitet (Standard: 90%)
- Schutz vor Endlosschleifen die den Host lahmlegen

### Build/Deploy-Kontrolle

Der Agent kann **nichts selbst ausfuehren**. Er schreibt eine Task-Datei, ein Windows-Runner prueft:

- Build-Kommando in Whitelist? → Ausfuehren
- Deploy-Target in Whitelist? → Ausfuehren
- Alles andere → **Abgelehnt. Kein Wildcard, kein Prefix-Match.**

Beide Whitelists sind konfigurierbar in `config.json`.

### Was ueber Sessions hinweg persistiert

Die Sandbox-Distro selbst ist wegwerfbar, aber zwei Schichten auf der Windows-Seite ueberleben Session-Grenzen und werden in jede neue Sandbox gebind-mountet:

- **Paket-Caches**: `_control/cache/npm` und `_control/cache/pip` — damit `npm install` / `pip install` zwischen Sessions nicht neu laden. Trade-off: ein Agent koennte den Cache theoretisch fuer eine spaetere Session vergiften.
- **Agent-Auth-Ordner**: `%LOCALAPPDATA%\agentbox\auth\{claude,codex,gemini,aider,goose}` — damit du dich nicht bei jeder Session neu einloggen musst. Jeder Agent hat seinen eigenen Unterordner; waehrend einer Session wird nur der des aktiven Agents gemountet, sie sehen sich also gegenseitig nicht.

Loesche einen der beiden Trees auf der Windows-Seite fuer einen komplett frischen Start.

## Konfiguration

Alle Einstellungen in `config.json` (optional — alle Werte haben eingebaute Defaults):

| Einstellung | Standard | Beschreibung |
|-------------|----------|-------------|
| `base_path_override` | `""` (OneDrive) | Eigener Projektordner-Pfad |
| `base_dir_name` | `AI_Projects_Source` | Name des Projektordners |
| `control_dir_name` | `_control` | Name des Steuerungsordners |
| `sandbox_user` | `agent` | Unprivilegierter User in der Sandbox |
| `resources_memory` | `4GB` | WSL2-Speicherlimit |
| `resources_processors` | `2` | WSL2-CPU-Kerne |
| `resources_swap` | `1GB` | WSL2-Swap-Groesse |
| `resources_ram_warn_percent` | `90` | RAM-Watchdog-Schwelle (%) |
| `resources_watchdog_interval` | `30` | Watchdog-Pruefintervall (Sekunden) |
| `build_whitelist` | 8 Kommandos | Erlaubte Build-Befehle |
| `deploy_whitelist` | `local`, `github` | Erlaubte Deploy-Ziele |
| `firewall_ai_apis` | 3 Endpoints | Altlast, kein Runtime-Effekt (siehe Netzwerk-Isolation) |
| `firewall_registries_node` | `npmjs.org` | Altlast, kein Runtime-Effekt |
| `firewall_registries_python` | `pypi.org`, `pythonhosted.org` | Altlast, kein Runtime-Effekt |
| `agent_*_enabled` | Big 3 an | Agenten aktivieren/deaktivieren |
| `auto_start_timeout` | `5` | Auto-Start-Countdown (Sekunden) |
| `auto_update` | `true` | Beim Start nach Updates suchen |
| `auto_update_interval_hours` | `24` | Stunden zwischen Update-Checks |
| `event_log_source` | `AIProjects` | Windows Event-Log-Quellname |
| `scheduled_task_name` | `agentbox-task-runner` | Windows Scheduled-Task-Name |

Siehe [`config.json`](../config.json) fuer die vollstaendige Liste mit allen Defaults.

## Vergleich

|                          | Docker Dev Container | GitHub Codespaces | **agentbox** |
|--------------------------|:-------------------:|:-----------------:|:------------:|
| Braucht Docker           | Ja                  | Nein (Cloud)      | **Nein**     |
| One-Liner Install        | Nein                | Nein              | **Ja**       |
| Agent-Isolation          | Manuell             | Teilweise         | **Automatisch** |
| Netzwerk-Beschraenkung   | Manuell             | Nein              | **Automatisch** |
| Build/Deploy-Whitelist   | Nein                | Nein              | **Ja**       |
| Session wegwerfbar       | Manuell             | Nein              | **Automatisch** |
| Funktioniert offline     | Ja                  | Nein              | **Ja**       |
| Kosten                   | Gratis              | Ab $0/Monat       | **Gratis**   |
| Setup-Zeit               | 10-30 Min           | 5 Min             | **3-5 Min**  |

## Session-Kontinuitaet

Agenten lesen `CLAUDE.md` zu Beginn und aktualisieren sie am Ende jeder Session. Kein Kontext geht verloren. Vor jeder Session wird automatisch ein Backup (`CLAUDE.md.bak`) erstellt.

## Replay-Modus: Agenten-Vergleich

Fuehre die gleiche Aufgabe mit verschiedenen Agenten aus und vergleiche die Ergebnisse — deterministisch.

### So funktioniert es

Jede Session erstellt automatisch einen **Snapshot** (Code + CLAUDE.md vor Agent-Start) und einen **Diff** (alle Aenderungen des Agenten). Das ermoeglicht:

```bash
# 1. Aufgabe mit Claude Code ausfuehren
agentbox
#    → Session-ID: 20260411_143000_claude_MeinProjekt

# 2. Gleichen Ausgangszustand mit anderem Agent wiederholen
agentbox --replay 20260411_143000_claude_MeinProjekt
#    → Anderen Agent waehlen (z.B. Codex oder Aider)
#    → Session-ID: 20260411_150000_codex_MeinProjekt

# 3. Vergleichen was jeder Agent gemacht hat
agentbox --compare 20260411_143000_claude_MeinProjekt 20260411_150000_codex_MeinProjekt
```

### Befehle

| Befehl | Beschreibung |
|--------|-------------|
| `agentbox --list-sessions` | Alle aufgezeichneten Sessions auflisten |
| `agentbox --replay <session-id>` | Snapshot wiederherstellen, mit anderem Agent ausfuehren |
| `agentbox --compare <id1> <id2>` | Zwei Sessions nebeneinander vergleichen |

### Was verglichen wird

- **Code-Aenderungen**: Vollstaendiger Unified-Diff aller geaenderten Dateien
- **CLAUDE.md-Aenderungen**: Wie jeder Agent seine Arbeit dokumentiert hat
- **Session-Metadaten**: Agent-Name, Zeitstempel, Projekt

Nuetzlich um zu evaluieren, welcher Agent bestimmte Aufgaben besser loest, oder um zu verifizieren, dass ein Refactoring bei verschiedenen Agenten aequivalente Ergebnisse liefert.

## Post-Session-Diagnostik

Nach jeder Session listet agentbox die Verbindungsversuche, die von den Host-Protection-Regeln verworfen wurden — alles was nicht HTTPS/HTTP auf public IPs war:

```
=== Blockierte Verbindungsversuche ===
(nicht 443/80 oder in private Netze — Host-Protection-Regeln haben gegriffen)

  [BLOCKED] internal-service.local (10.0.0.42)
  [BLOCKED] 203.0.113.42
```

Typische Eintraege: der Agent hat versucht, deinen Windows-Host (`172.x`, `127.0.0.1`), dein LAN (`192.168.x`) oder einen Nicht-Web-Port zu erreichen. Wenn du einen Treffer auf eine Domain siehst, die du wirklich brauchst — z.B. ein privater Artifact-Mirror — dann hat der aktuelle Build von agentbox keinen per-Host-Whitelist-Knopf; die iptables-Regeln in `wsl-sandbox-init.sh` musst du dann selber aufweichen.

## Dateistruktur

```
AI_Projects_Source\                (oder eigener Pfad)
+-- _control\
|   +-- config.json                # Zentrale Konfiguration
|   +-- install.ps1                # Bootstrap von GitHub
|   +-- win-setup.ps1              # Einmalig: Template bauen
|   +-- win-task-runner.ps1        # Build/Deploy Runner
|   +-- wsl-ai-start.sh            # Projekt/Agent-Auswahl
|   +-- wsl-sandbox-init.sh        # Sandbox-Initialisierung
|   +-- type_defaults.json         # Typ-Erkennung + Defaults
|   +-- SYSTEM_META_PROMPT.md      # Arbeitsvertrag fuer Agenten
|   +-- lib\
|   |   +-- config.sh              # Bash-Config-Helper
|   +-- sandbox\
|   |   +-- template.tar.gz        # Template-Distro
|   +-- sessions\                   # Replay-Snapshots + Diffs
|   +-- cache\
|       +-- npm\                    # Persistenter npm-Cache
|       +-- pip\                    # Persistenter pip-Cache
+-- MeinProjekt\
|   +-- project.json
|   +-- CLAUDE.md
|   +-- src\
|   +-- assets\
|   +-- _tasks\
```

## Voraussetzungen

- Windows 10 (2004+) oder Windows 11 + WSL2 (wird automatisch installiert falls nicht vorhanden)
- Admin-Rechte (nur einmalig)
- Git (optional — wird fuer schnellere Updates genutzt, nicht zwingend erforderlich)
- **Kein Docker. Kein Kubernetes. Keine Cloud.**

## Ehrlichkeit

### Was agentbox NICHT schuetzt

- WSL2-Kernel-Exploits (Microsoft-Verantwortung)
- Boesartiger Code im Projektordner (Agent hat dort r/w — das ist beabsichtigt)
- DNS-Tunneling (theoretisch moeglich, praktisch irrelevant)
- Kein Multi-User-System (ein Entwickler, ein Rechner)

Wir dokumentieren das, weil Sicherheitsversprechen nur zaehlen, wenn man ehrlich sagt wo die Grenzen sind.
