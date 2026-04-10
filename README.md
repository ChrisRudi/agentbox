<p align="center">
  <h1 align="center">agentbox</h1>
  <p align="center">
    <strong>AI-Coding-Agenten haben vollen Zugriff auf dein Dateisystem.<br>agentbox aendert das.</strong>
  </p>
  <p align="center">
    <a href="#installation">Installation</a> · <a href="#taegliche-nutzung">Nutzung</a> · <a href="#sicherheitsmodell">Sicherheit</a> · <a href="#vergleich">Vergleich</a>
  </p>
</p>

---

**agentbox** startet AI-Coding-Agenten (Claude Code, OpenAI Codex, Gemini CLI) in **wegwerfbaren WSL2-Distributionen** mit echter Dateisystem- und Netzwerkisolation.

Ein Befehl. Kein Docker. Kein Kubernetes. Nur Windows + WSL2.

## Warum?

AI-Coding-Agenten sind maechtig — aber sie laufen mit vollen Rechten auf deinem System. Sie koennen:

- Jede Datei lesen und aendern (SSH-Keys, Browser-Profile, andere Projekte)
- Beliebige Prozesse starten und Netzwerkverbindungen oeffnen
- Build-Artefakte, Caches und temporaere Dateien hinterlassen, die WSL aufblaehenagentbox gibt dir die Produktivitaet von AI-Agenten **ohne das Risiko**.

## Installation

Ein Befehl in einer Admin-PowerShell:

```powershell
irm https://raw.githubusercontent.com/ChrisRudi/agentbox/main/install.ps1 | iex
```

Das wars. WSL-Terminal oeffnen — agentbox startet automatisch.

<details>
<summary>Was passiert bei der Installation?</summary>

1. Repository wird nach `OneDrive\AI_Projects_Source\_control` geklont
2. WSL2-Template wird gebaut (Ubuntu-Minimal + Node.js + Python3 + AI-CLIs)
3. Windows Event-Source und Scheduled Task werden angelegt
4. WSL `.bashrc` wird konfiguriert (Auto-Start)
5. Desktop-Shortcut `agentbox.lnk` wird erstellt
6. `.wslconfig` mit Ressourcen-Limits gesetzt (4 GB RAM, 2 CPUs)

Dauer: ca. 3-5 Minuten, einmalig.
</details>

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

**Agent arbeitet → Session endet → Sandbox wird geloescht → Code bleibt.**

### Wo liegt der Code?

Alle Projekte liegen in `OneDrive\AI_Projects_Source\` — auf deinem Windows-Dateisystem. Die Sandbox mountet nur den Projektordner per Bind-Mount. Der Agent schreibt direkt in deinen OneDrive-Ordner:

| Vorteil | Beschreibung |
|---------|-------------|
| **OneDrive-Sync** | Code wird automatisch in die Cloud gesichert |
| **Kein Kopieren** | Aenderungen landen sofort auf Windows |
| **Sandbox weg, Code bleibt** | Nur die Distro wird geloescht, nicht deine Dateien |
| **Paket-Cache bleibt** | npm/pip-Caches sind persistent — kein Re-Download |
| **WSL bleibt schlank** | Keine wachsende VHDX durch Caches und Artefakte |

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
| AI-APIs (Anthropic, OpenAI, Google) | Alles andere |
| Paketquellen (automatisch nach Projekttyp) | Beliebige Outbound-Verbindungen |
| DNS (Port 53) | Zugriff auf lokale Dienste |

Projekttyp `node` → nur `npmjs.org`. Projekttyp `python` → nur `pypi.org`. HTML/PowerShell → keine Paketquellen.

### Ressourcen-Limits

- `.wslconfig`: 4 GB RAM, 2 CPUs, 1 GB Swap (anpassbar)
- **RAM-Watchdog**: Warnt per Windows-Dialog wenn Sandbox > 90% RAM nutzt
- Schutz vor Endlosschleifen die den Host lahmlegen

### Build/Deploy-Kontrolle

Der Agent kann **nichts selbst ausfuehren**. Er schreibt eine Task-Datei, ein Windows-Runner prueft:

- Build-Kommando in Whitelist? (`npm run build`, `make`, etc.) → Ausfuehren
- Deploy-Target in Whitelist? (`local`, `github`) → Ausfuehren
- Alles andere → **Abgelehnt. Kein Wildcard, kein Prefix-Match.**

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
OneDrive\AI_Projects_Source\
+-- _control\
|   +-- install.ps1              # Bootstrap von GitHub
|   +-- win-setup.ps1            # Einmalig: Template bauen
|   +-- win-task-runner.ps1      # Build/Deploy Runner
|   +-- wsl-ai-start.sh          # Projekt/Agent-Auswahl
|   +-- wsl-sandbox-init.sh      # Sandbox-Initialisierung
|   +-- type_defaults.json       # Typ-Erkennung + Defaults
|   +-- SYSTEM_META_PROMPT.md    # Arbeitsvertrag fuer Agenten
|   +-- sandbox\
|   |   +-- template.tar.gz      # Template-Distro
|   +-- cache\
|       +-- npm\                  # Persistenter npm-Cache
|       +-- pip\                  # Persistenter pip-Cache
+-- MeinProjekt\
|   +-- project.json
|   +-- CLAUDE.md
|   +-- src\
|   +-- assets\
|   +-- _tasks\
```

Sieben Skripte, zwei Ordner. Das ist alles.

## Voraussetzungen

- Windows 11 + WSL2
- Git
- Admin-Rechte (nur einmalig)
- **Kein Docker. Kein Kubernetes. Keine Cloud.**

## Ehrlichkeit

### Was agentbox NICHT schuetzt

- WSL2-Kernel-Exploits (Microsoft-Verantwortung)
- Boesartiger Code im Projektordner (Agent hat dort r/w — das ist beabsichtigt)
- DNS-Tunneling (theoretisch moeglich, praktisch irrelevant)
- Kein Multi-User-System (ein Entwickler, ein Rechner)

Wir dokumentieren das, weil Sicherheitsversprechen nur zaehlen, wenn man ehrlich sagt wo die Grenzen sind.
