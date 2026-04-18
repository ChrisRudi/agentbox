<p align="center">
  <h1 align="center">agentbox</h1>
  <p align="center">
    <strong>AI-Coding-Agenten haben vollen Zugriff auf dein Dateisystem.<br>agentbox ändert das.</strong>
  </p>
  <p align="center">
    <a href="#installation">Installation</a> · <a href="#unterstützte-agenten">Agenten</a> · <a href="#tägliche-nutzung">Nutzung</a> · <a href="#vs-code-integration-optional">VS Code</a> · <a href="#sicherheitsmodell">Sicherheit</a> · <a href="#konfiguration">Config</a>
  </p>
  <p align="center">
    🌍 <a href="../README.md">English</a>
  </p>
</p>

---

**KI-Coding-Agenten lösen Probleme — und zerstören dabei dein System:**

- Sie machen deinen Rechner lahm — fressen RAM und CPU ohne Limit
- Sie ruinieren dein OS — Caches, Reste, irgendwann startet Windows nicht mehr sauber
- Sie stehlen deine Secrets — SSH-Keys, `.env`-Dateien, Passwörter
- Sie liegen offen im Netzwerk — dein Host und LAN sind erreichbar
- Sie vergessen alles — nach der Session ist der Kontext weg
- Sie fragen ständig nach — weil dein System auf dem Spiel steht

**In einer portablen Sandbox nicht.**

Ein Befehl. Saubere Umgebung. Volle Kontrolle. Komplett portabel.
Windows nativ. Kein Docker. Kein Kubernetes.

**agentbox** startet KI-Coding-Agenten in **wegwerfbaren WSL2-Distributionen** mit echter Dateisystem- und Netzwerkisolation — und gibt dir die Produktivität von KI-Agenten **ohne das Risiko**.

### Gemacht für digitale Nomaden

Rechnerwechsel soll nicht bedeuten, dass du dein komplettes KI-Dev-Setup neu aufbauen musst. Genau darauf ist agentbox ausgelegt:

- **Eine PowerShell-Zeile installiert alles** — auf jeder frischen Windows-Kiste, in unter zwei Minuten. Kein Image mitzuschleppen, keine Container-Registry abfragen.
- **Deine Projekte liegen in OneDrive** (oder Dropbox, oder in was auch immer du schon an Cloud-Sync nutzt). Der `_control/`-Ordner ist versioniert und synct per Default mit — Config, Agent-Seeds und Projektcode folgen dir also von selbst.
- **Sessions sind per Design wegwerfbar** — das ist der ganze Witz. Nichts zu migrieren, keinen State hinterherziehen.
- **Neuer Rechner = eine Zeile + einmal pro Agent einloggen.** Fertig. Weiter coden.

Laptop verloren? Neuen kaufen, einen Befehl, einloggen. Deine Arbeit ist schon da.

## Performance

agentbox ist nicht nur sicherer — sondern auch **schneller**. Beispiellauf auf modernem Laptop-SSD unter Windows 11 + WSL 2.x (2026-04-18):

| Metrik                       | agentbox vs Host |
|------------------------------|------------------|
| Netzwerk-Download            | 1.1x             |
| Disk seq write (1 GB)        | **18.7x**        |
| Disk small files (10k x 4 B) | **9.1x**         |
| CPU SHA256 (500 MB)          | 1.9x             |
| Process spawn (500 procs)    | **17.3x**        |

Die grossen Gewinne kommen von den ext4-on-vhdx-Overlays im Workspace (`node_modules`, `.next`, `__pycache__` etc.) und vom Linux-nativen fork/exec — aus demselben Grund fuehlen sich `npm install` und `pytest` in WSL schneller an als direkt auf Windows.

Ehrliche Einordnung: die Verhaeltnisse beziehen sich auf die **persistente Host-Distro** (`agentbox_host`), ohne Session-Time-Tuning. Die **ephemere Agent-Session** legt BBR, dnsmasq-Cache, `force-unsafe-io` fuer dpkg und zusaetzliche ext4-Overlays obendrauf — die tatsaechlichen In-Session-Zahlen liegen typischerweise noch hoeher.

Auf eigener Hardware nachstellbar via mitgeliefertem Demo-Projekt: agentbox → `[c] Konfiguration` → `[3] Benchmark ausfuehren` — Code liegt in [`tools/`](../tools/).

## Unterstützte Agenten

| Agent | Standard | Paketmanager | Aktivieren |
|-------|----------|-------------|------------|
| **Claude Code** (Anthropic) | Aktiviert | npm | — |
| **OpenAI Codex** (OpenAI) | Aktiviert | npm | — |
| **Gemini CLI** (Google) | Aktiviert | npm | — |
| **Aider** | Deaktiviert | pip | `agent_aider_enabled` in `config.json` auf `true` setzen |
| **Goose** (Block) | Deaktiviert | pip | `agent_goose_enabled` in `config.json` auf `true` setzen |

Zusätzliche Agenten aktivieren: beim Start im Agent-Auswahl-Menü **`[c] Konfiguration`** drücken und den gewünschten Agent umschalten — das schreibt direkt in `config.json`. Danach einmal `install.ps1` in einer Admin-PowerShell neu laufen lassen, damit das Template mit den neuen Agent-Binaries gebaut wird (`irm https://raw.githubusercontent.com/ChrisRudi/agentbox/main/install.ps1 | iex`).

## Installation

Ein Befehl in einer Admin-PowerShell:

```powershell
irm https://raw.githubusercontent.com/ChrisRudi/agentbox/main/install.ps1 | iex
```

Das wars. WSL-Terminal öffnen — agentbox startet automatisch.

### Update

Gleicher Befehl. Wenn agentbox bereits installiert ist, wird die neueste Version gezogen und das Template neu gebaut (inklusive neu aktivierter Agenten).

<details>
<summary>Was passiert bei der Installation?</summary>

1. Repository wird nach `AI_Projects_Source\_control` geklont (oder eigener Pfad)
2. WSL2-Template wird gebaut (Ubuntu-Minimal + Node.js + Python3 + aktivierte AI-CLIs)
3. Windows Event-Source und Scheduled Task werden angelegt
4. WSL `.bashrc` wird konfiguriert (Auto-Start)
5. Einmalige Abfrage: Windows Terminal / VS Code / beide? (siehe [VS Code Integration](#vs-code-integration-optional))
6. Desktop-Shortcut `agentbox.lnk` wird erstellt (plus `agentbox (VS Code).lnk` bei VS-Code-Wahl)
7. `.wslconfig` mit Ressourcen-Limits gesetzt (konfigurierbar über `config.json`)

Dauer: ca. 3-5 Minuten, einmalig. Updates sind schneller.
</details>

### Speicherort

Standardmäßig nutzt agentbox `OneDrive\AI_Projects_Source\`. Du kannst **jeden beliebigen Ordner** verwenden:

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
| `agent.entry_point` | Nein | Hauptdatei (informativ, für den Agenten) |

Automatisch erkannte Typen und ihre Defaults:

| Gefundene Dateien | Erkannter Typ | Standard-Build-Befehl |
|-------------------|--------------|----------------------|
| `package.json` | `node` | `npm run build` |
| `*.py` | `python` | `pip install -r requirements.txt` |
| `*.ps1` | `powershell` | — |
| `*.html` | `html` | — |
| (nichts davon) | `generic` | — |

## Tägliche Nutzung

WSL-Terminal öffnen (oder Doppelklick auf den Desktop-Shortcut):

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

=== Starte Claude Code für MeinProjekt ===
```

> **Agent arbeitet → Session endet → Sandbox wird gelöscht → Code bleibt.**

Es werden nur Agenten angezeigt, die in `config.json` **aktiviert** und im Template **installiert** sind.

## VS Code Integration (optional)

Du willst dem Agenten **live** zuschauen, wie er Dateien bearbeitet? agentbox kann VS Code als Launcher verwenden — statt oder parallel zu Windows Terminal.

Beim ersten `install.ps1`-Lauf wirst du einmalig gefragt:

```
Launcher fuer den agentbox-Shortcut waehlen:
  [1] Windows Terminal (Default, schlank, bewaehrt)
  [2] VS Code          (Live-Filewatch + Agent-Terminal im Editor)
  [3] Beide            (zwei Shortcuts — du entscheidest pro Klick)
```

Bei **[2]** (oder **[3]**) verdrahtet agentbox alles für dich — inklusive `winget`-Install von VS Code selbst falls nicht vorhanden (user-scope, kein Admin):

- Ein **Terminal-Profil `agentbox`** wird per Smart-Merge in deine User-`settings.json` geschrieben (bestehende Settings bleiben unangetastet; JSONC mit Kommentaren wird nicht verändert, stattdessen bekommst du das Snippet zum Selbst-Einfügen auf der Konsole).
- Eine **Workspace-Datei** (`agentbox.code-workspace`) öffnet in VS Code deinen Projekt-Root (`AI_Projects_Source\`).
- Ein Task mit `runOn: folderOpen` startet den Agent in einem **dedicated Terminal-Panel**, sobald das Workspace geöffnet wird — einmal "trust this workspace" bestätigen, danach läuft's ohne weitere Interaktion.

**Effekt beim Doppelklick:** VS Code öffnet sich → Agent läuft im Terminal-Panel → jede Datei die der Agent schreibt erscheint **live** im Explorer-Tree, reloaded sich automatisch im Editor, und zeigt Diffs in der Git-Gutter. Kein Container-Setup, kein VS Code Server, kein Browser-Tab — Windows-nativer fsnotify greift die Änderungen über den WSL-Bind-Mount ab.

Andere "agentbox"-Projekte setzen auf Docker-Devcontainer (Extension-Tanz, Trust-Prompts, `.devcontainer/devcontainer.json`-Pflege) oder VS Code Server im Browser-Tab. Hier ist's dein **lokaler nativer VS Code** — null Plugins nötig, null Container-Overhead beim File-I/O.

Später ändern: `launch_ui` in `config.json` (`wt` | `vscode` | `both`) setzen und `install.ps1` neu laufen lassen. Die Wahl überlebt Updates.

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

### Netzwerk-Isolation — Was tatsächlich passiert

**agentbox schützt deine Maschine vor dem Agent, nicht das Internet vor dem Agent.**

Die iptables-Regeln in der Sandbox setzen durch:

| Erlaubt | Blockiert |
|---------|-----------|
| Outbound HTTPS/HTTP zu public IPs | Zugriff auf private Netze (`10/8`, `172.16/12`, `192.168/16`, `169.254/16`, `127/8`) |
| DNS (Port 53) | Alle Nicht-HTTP(S)-Ports |

Das Wichtige sind die DROPs auf private Netze: sie verhindern, dass der Agent deinen Windows-Host, LAN-Dienste, Metadata-Endpoints oder andere WSL-Distros erreicht. Das ist das Client-Protection-Threat-Model.

**Was agentbox NICHT macht:** Per-Domain-Egress-Filtering. iptables kann Hostnamen nicht zuverlässig matchen (CDNs rotieren IPs mitten im Request), also gibt es kein tatsächlich durchgesetztes Whitelist. Ein Agent mit Netzwerk-Zugriff *kann* während einer Session jeden öffentlichen HTTPS-Endpunkt erreichen. Wer das im Threat-Model hat, braucht einen Egress-Proxy — agentbox liefert keinen mit.

### Ressourcen-Limits

- `.wslconfig`: konfigurierbar über `config.json` (Standard: 4 GB RAM, 2 CPUs, 1 GB Swap)
- **RAM-Watchdog**: Warnt per Windows-Dialog wenn Sandbox Schwellwert überschreitet (Standard: 90%)
- Schutz vor Endlosschleifen die den Host lahmlegen

### Build/Deploy-Kontrolle

Der Agent kann **nichts selbst ausführen**. Er schreibt eine Task-Datei, ein Windows-Runner prüft:

- Build-Kommando in Whitelist? → Ausführen
- Deploy-Target in Whitelist? → Ausführen
- Alles andere → **Abgelehnt. Kein Wildcard, kein Prefix-Match.**

Beide Whitelists sind konfigurierbar in `config.json`.

### Was über Sessions hinweg persistiert

Die Sandbox-Distro selbst ist wegwerfbar, aber zwei Schichten auf der Windows-Seite überleben Session-Grenzen und werden in jede neue Sandbox gebind-mountet:

- **Paket-Caches**: `%LOCALAPPDATA%\agentbox\cache\npm` und `…\cache\pip` — damit `npm install` / `pip install` zwischen Sessions nicht neu laden. Trade-off: ein Agent könnte den Cache theoretisch für eine spätere Session vergiften.
- **Agent-Auth-Ordner**: `%LOCALAPPDATA%\agentbox\auth\{claude,codex,gemini,aider,goose}` — damit du dich nicht bei jeder Session neu einloggen musst. Jeder Agent hat seinen eigenen Unterordner; während einer Session wird nur der des aktiven Agents gemountet, sie sehen sich also gegenseitig nicht.

Beide liegen unter `%LOCALAPPDATA%\agentbox\` (nicht in deinem `_control/`-Ordner), damit OneDrive keine Binär-Caches oder Tokens synchronisiert. Lösche einen der beiden Trees auf der Windows-Seite für einen komplett frischen Start.

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
| `resources_swap` | `1GB` | WSL2-Swap-Größe |
| `resources_ram_warn_percent` | `90` | RAM-Watchdog-Schwelle (%) |
| `resources_watchdog_interval` | `30` | Watchdog-Prüfintervall (Sekunden) |
| `build_whitelist` | 8 Kommandos | Erlaubte Build-Befehle |
| `deploy_whitelist` | `local`, `github` | Erlaubte Deploy-Ziele |
| `agent_*_enabled` | Big 3 an | Agenten aktivieren/deaktivieren |
| `auto_start_timeout` | `5` | Auto-Start-Countdown (Sekunden) |
| `auto_update` | `true` | Beim Start nach Updates suchen |
| `auto_update_interval_hours` | `24` | Stunden zwischen Update-Checks |
| `launch_ui` | `""` (Abfrage beim ersten Run) | Shortcut-Ziel: `wt` (Windows Terminal), `vscode` (VS Code mit Live-Filewatch) oder `both` |
| `event_log_source` | `AIProjects` | Windows Event-Log-Quellname |
| `scheduled_task_name` | `agentbox-task-runner` | Windows Scheduled-Task-Name |

Siehe [`config.json`](../config.json) für die vollständige Liste mit allen Defaults.

## Vergleich

|                          | Docker Dev Container | GitHub Codespaces | **agentbox** |
|--------------------------|:-------------------:|:-----------------:|:------------:|
| Braucht Docker           | Ja                  | Nein (Cloud)      | **Nein**     |
| One-Liner Install        | Nein                | Nein              | **Ja**       |
| Agent-Isolation          | Manuell             | Teilweise         | **Automatisch** |
| Netzwerk-Beschränkung    | Manuell             | Nein              | **Automatisch** |
| Build/Deploy-Whitelist   | Nein                | Nein              | **Ja**       |
| Session wegwerfbar       | Manuell             | Nein              | **Automatisch** |
| Funktioniert offline     | Ja                  | Nein              | **Ja**       |
| Kosten                   | Gratis              | Ab $0/Monat       | **Gratis**   |
| Setup-Zeit               | 10-30 Min           | 5 Min             | **3-5 Min**  |

## Session-Kontinuität

Agenten lesen `CLAUDE.md` zu Beginn und aktualisieren sie am Ende jeder Session. Kein Kontext geht verloren. Vor jeder Session wird automatisch ein Backup (`CLAUDE.md.bak`) erstellt.

## Replay-Modus: Agenten-Vergleich

Führe die gleiche Aufgabe mit verschiedenen Agenten aus und vergleiche die Ergebnisse — deterministisch.

### So funktioniert es

Jede Session erstellt automatisch einen **Snapshot** (Code + CLAUDE.md vor Agent-Start) und einen **Diff** (alle Änderungen des Agenten). Das ermöglicht:

```bash
# 1. Aufgabe mit Claude Code ausführen
agentbox
#    → Session-ID: 20260411_143000_claude_MeinProjekt

# 2. Gleichen Ausgangszustand mit anderem Agent wiederholen
agentbox --replay 20260411_143000_claude_MeinProjekt
#    → Anderen Agent wählen (z.B. Codex oder Aider)
#    → Session-ID: 20260411_150000_codex_MeinProjekt

# 3. Vergleichen was jeder Agent gemacht hat
agentbox --compare 20260411_143000_claude_MeinProjekt 20260411_150000_codex_MeinProjekt
```

### Befehle

| Befehl | Beschreibung |
|--------|-------------|
| `agentbox --list-sessions` | Alle aufgezeichneten Sessions auflisten |
| `agentbox --replay <session-id>` | Snapshot wiederherstellen, mit anderem Agent ausführen |
| `agentbox --compare <id1> <id2>` | Zwei Sessions nebeneinander vergleichen |

### Was verglichen wird

- **Code-Änderungen**: Vollständiger Unified-Diff aller geänderten Dateien
- **CLAUDE.md-Änderungen**: Wie jeder Agent seine Arbeit dokumentiert hat
- **Session-Metadaten**: Agent-Name, Zeitstempel, Projekt

Nützlich um zu evaluieren, welcher Agent bestimmte Aufgaben besser löst, oder um zu verifizieren, dass ein Refactoring bei verschiedenen Agenten äquivalente Ergebnisse liefert.

## Post-Session-Diagnostik

Nach jeder Session listet agentbox die Verbindungsversuche, die von den Host-Protection-Regeln verworfen wurden — alles was nicht HTTPS/HTTP auf public IPs war:

```
=== Blockierte Verbindungsversuche ===
(nicht 443/80 oder in private Netze — Host-Protection-Regeln haben gegriffen)

  [BLOCKED] internal-service.local (10.0.0.42)
  [BLOCKED] 203.0.113.42
```

Typische Einträge: der Agent hat versucht, deinen Windows-Host (`172.x`, `127.0.0.1`), dein LAN (`192.168.x`) oder einen Nicht-Web-Port zu erreichen. Wenn du einen Treffer auf eine Domain siehst, die du wirklich brauchst — z.B. ein privater Artifact-Mirror — dann hat der aktuelle Build von agentbox keinen per-Host-Whitelist-Knopf; die iptables-Regeln in `wsl-sandbox-init.sh` musst du dann selber aufweichen.

## Dateistruktur

agentbox trennt **Code/Config** und **Runtime-State** absichtlich in zwei
Trees — der erste ist versioniert und Cloud-sync-tauglich, der zweite
binär/sensibel und bleibt lokal.

**Versionierter Tree** (dein Projekt-Ordner, OneDrive-tauglich):

```
AI_Projects_Source\                (oder eigener Pfad)
+-- _control\                      # Dieser Repo-Clone; syncht mit OneDrive
|   +-- config.json                # Zentrale Konfiguration
|   +-- install.ps1                # Bootstrap von GitHub
|   +-- win-setup.ps1              # Einmalig: Template bauen
|   +-- win-setup-core.ps1         # Template-Builder (wird von install.ps1 aufgerufen)
|   +-- win-task-runner.ps1        # Build/Deploy Runner
|   +-- wsl-ai-start.sh            # Projekt/Agent-Auswahl
|   +-- wsl-sandbox-init.sh        # Sandbox-Initialisierung
|   +-- type_defaults.json         # Typ-Erkennung + Defaults
|   +-- SYSTEM_META_PROMPT.md      # Arbeitsvertrag für Agenten
|   +-- refactor.md                # Architektur-Aufräum-Roadmap
|   +-- lib\
|       +-- config.sh              # Bash-Config-Helper
+-- MeinProjekt\
|   +-- project.json
|   +-- CLAUDE.md
|   +-- src\
|   +-- assets\
|   +-- _tasks\
```

**Runtime-Tree** (lokal, kommt nie in die Cloud):

```
%LOCALAPPDATA%\agentbox\
+-- sandbox\
|   +-- template.vhdx              # Primär (WSL 2.0+); ~3-5s Copy auf SSD
|   +-- template.tar.gz            # Fallback nur für WSL < 2.0.x
|   +-- .config_hash               # Skip-Build-Check
+-- cache\
|   +-- npm\                       # Persistenter npm-Cache
|   +-- pip\                       # Persistenter pip-Cache
+-- sessions\                      # Replay-Snapshots + Diffs
+-- auth\
|   +-- claude\                    # Claude Code OAuth + Tokens
|   +-- codex\
|   +-- gemini\
|   +-- aider\
|   +-- goose\
+-- host-distro\                   # Persistente Host-WSL-Distro (Default)
```

> Die Trennung ist hart: `_control/` enthält nur versionierte Scripts +
> Config, nie Cache oder Token-Daten. OneDrive Files-on-Demand kann mit
> Binär-State nichts anfangen, und Secrets haben per Default nichts in
> der Cloud verloren.

## Voraussetzungen

- Windows 10 (2004+) oder Windows 11 + WSL2 (wird automatisch installiert falls nicht vorhanden)
- Admin-Rechte (nur einmalig)
- Git (optional — wird für schnellere Updates genutzt, nicht zwingend erforderlich)
- **Kein Docker. Kein Kubernetes. Keine Cloud.**

## Ehrlichkeit

### Was agentbox NICHT schützt

- WSL2-Kernel-Exploits (Microsoft-Verantwortung)
- Bösartiger Code im Projektordner (Agent hat dort r/w — das ist beabsichtigt)
- DNS-Tunneling (theoretisch möglich, praktisch irrelevant)
- Kein Multi-User-System (ein Entwickler, ein Rechner)

Wir dokumentieren das, weil Sicherheitsversprechen nur zählen, wenn man ehrlich sagt wo die Grenzen sind.
