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

**agentbox** startet AI-Coding-Agenten in **wegwerfbaren WSL2-Distributionen** mit echter Dateisystem- und Netzwerkisolation.

Ein Befehl. Kein Docker. Kein Kubernetes. Nur Windows + WSL2.

## Warum?

AI-Coding-Agenten sind maechtig — aber sie laufen mit vollen Rechten auf deinem System. Sie koennen:

- Jede Datei lesen und aendern (SSH-Keys, Browser-Profile, andere Projekte)
- Beliebige Prozesse starten und Netzwerkverbindungen oeffnen
- Build-Artefakte, Caches und temporaere Dateien hinterlassen, die WSL aufblaehenagentbox gibt dir die Produktivitaet von AI-Agenten **ohne das Risiko**.

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
/workspace/
  src/           (read-write)   Dein Code
  assets/        (read-only)    Statische Dateien
  _tasks/        (read-write)   Task-Trigger
  CLAUDE.md      (read-write)   Session-Kontext
  project.json   (read-only)    Konfiguration
```

Der Agent sieht **nicht**: `/mnt/c/`, OneDrive, `~/.ssh/`, andere Projekte, `_control/`.

Mounts: `nosymfollow` + `nodev` + Hardlink-Schutz (`sysctl`).

### Netzwerk-Isolation

Per `iptables` — nur das Noetige:

| Erlaubt | Blockiert |
|---------|-----------|
| AI-APIs (konfigurierbar in `config.json`) | Alles andere |
| Paketquellen (automatisch nach Projekttyp) | Beliebige Outbound-Verbindungen |
| DNS (Port 53) | Zugriff auf lokale Dienste |

Projekttyp `node` → nur `registry.npmjs.org`. Projekttyp `python` → nur `pypi.org` + `files.pythonhosted.org`. HTML/PowerShell → keine Paketquellen.

> **Hinweis:** Moderne Paketmanager nutzen CDNs und Subdomains. Die Defaults in `config.json` enthalten die exakten Domains (`registry.npmjs.org`, nicht nur `npmjs.org`). Falls ein `npm install` fehlschlaegt, prüfe `firewall_registries_node` / `firewall_registries_python` in `config.json` und ergaenze fehlende Domains.

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
| `firewall_ai_apis` | 3 Endpoints | Erlaubte AI-API-Domains |
| `firewall_registries_node` | `npmjs.org` | Node.js-Paketquellen |
| `firewall_registries_python` | `pypi.org`, `pythonhosted.org` | Python-Paketquellen |
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
