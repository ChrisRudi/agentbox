# agentbox

Sandboxed AI Agent Runner fuer Windows + WSL2.

Startet AI-Coding-Agenten (Claude Code, OpenAI Codex, Gemini CLI) in wegwerfbaren WSL2-Distributionen mit echter Dateisystem- und Netzwerkisolation. Kein Docker, kein Kubernetes.

## Installation

Ein Befehl in einer Admin-PowerShell:

```powershell
irm https://raw.githubusercontent.com/ChrisRudi/agentbox/main/install.ps1 | iex
```

Das wars. WSL-Terminal oeffnen — agentbox startet automatisch.

## Was passiert bei der Installation?

1. Repository wird nach `OneDrive\AI_Projects_Source\_control` geklont
2. WSL2-Template wird gebaut (Ubuntu-Minimal + Node.js + Python3 + AI-CLIs)
3. Windows Event-Source und Scheduled Task werden angelegt
4. WSL `.bashrc` wird konfiguriert (Auto-Start)
5. Desktop-Shortcut `agentbox.lnk` wird erstellt

Dauer: ca. 3-5 Minuten, einmalig.

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

Der Agent arbeitet in einer wegwerfbaren Sandbox. Nach der Session wird die Distro geloescht — alle temporaeren Dateien, Caches und Artefakte sind weg. Code und CLAUDE.md bleiben im Projektordner (waren nur gemountet).

### Wo liegt der Code?

Alle Projekte liegen in `OneDrive\AI_Projects_Source\` — auf dem Windows-Dateisystem, nicht in WSL. Die Sandbox mountet nur den jeweiligen Projektordner per Bind-Mount in die wegwerfbare Distro. Der Agent schreibt also direkt in deinen OneDrive-Ordner. Dadurch:

- **Automatische Synchronisation**: OneDrive sichert deinen Code automatisch in die Cloud
- **Kein Kopieren noetig**: Aenderungen landen sofort im Projektordner auf Windows
- **Sandbox weg, Code bleibt**: Nach Session-Ende wird nur die Distro geloescht, nicht deine Dateien
- **Zugriff von ueberall**: Dein Code ist ueber OneDrive auf allen Geraeten verfuegbar
- **Paket-Cache bleibt**: npm- und pip-Caches werden in `_control/cache/` persistent gemountet — Pakete muessen nicht bei jeder Session neu heruntergeladen werden
- **WSL bleibt schlank**: Beim normalen Coding in WSL sammeln sich node_modules, pip-Caches, Build-Artefakte und temporaere Dateien an — die VHDX-Datei waechst und waechst, schrumpft aber nie von allein. agentbox vermeidet das komplett: Jede Session ist eine frische Wegwerf-Distro, danach wird alles geloescht. Deine Host-WSL bleibt sauber.

## Sicherheitsmodell

### Dateisystem-Isolation

Der Agent sieht nur:

| Pfad | Zugriff | Inhalt |
|------|---------|--------|
| `/workspace/src/` | read-write | Projekt-Quellcode |
| `/workspace/assets/` | read-only | Statische Dateien |
| `/workspace/_tasks/` | read-write | Task-Trigger fuer Build/Deploy |
| `/workspace/CLAUDE.md` | read-write | Session-Kontinuitaet |
| `/workspace/project.json` | read-only | Projektkonfiguration |

Der Agent sieht **nicht**: `/mnt/c/`, OneDrive, `~/.ssh/`, andere Projekte, `_control/`.

Mounts sind gehardened: `nosymfollow` (keine Symlinks nach aussen), `nodev` (keine Device-Nodes), Hardlink-Schutz via `sysctl`.

### Netzwerk-Isolation

Per `iptables` sind nur diese Endpoints erlaubt:

- `api.anthropic.com`, `api.openai.com`, `generativelanguage.googleapis.com` (AI-APIs)
- Paketquellen **automatisch nach Projekttyp**: Node → `npmjs.org`, Python → `pypi.org`, HTML/PowerShell → keine
- DNS (Port 53)
- **Alles andere wird blockiert.**

### Ressourcen-Limits

Der Installer setzt `.wslconfig` mit Defaults (4 GB RAM, 2 CPUs, 1 GB Swap), damit ein ausser Kontrolle geratener Agent den Host nicht lahmlegen kann. Bestehende `.wslconfig` werden nicht ueberschrieben.

### Build/Deploy-Kontrolle

Der Agent kann nicht selbst builden oder deployen. Er schreibt eine Task-Datei, ein separater Windows-Runner fuehrt die Aktion kontrolliert aus:

- Build-Kommandos muessen exakt in einer Whitelist stehen (`npm run build`, `make`, etc.)
- Deploy-Targets sind auf `local` und `github` beschraenkt
- Kein freies Kommando, kein Wildcard, kein Prefix-Match

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

Sieben Dateien, zwei Ordner. Das ist alles.

## Session-Kontinuitaet

Agenten lesen `CLAUDE.md` zu Beginn und aktualisieren sie am Ende jeder Session. So geht kein Kontext verloren, auch wenn die Sandbox weggeworfen wird. Vor jeder Session wird automatisch ein Backup (`CLAUDE.md.bak`) erstellt.

## Voraussetzungen

- Windows 11 + WSL2
- Git
- Admin-Rechte (nur fuer die Ersteinrichtung)
- Kein Docker, kein Kubernetes, keine Cloud

## Was agentbox IST

- Ein Befehl zum Installieren
- Echte Dateisystem-Isolation (wegwerfbare WSL2-Distro)
- Agent schreibt Code direkt in deinen OneDrive-Ordner (Bind-Mount, kein Kopieren)
- Build/Deploy nur ueber Whitelist-Task — der Agent kann nichts selbst ausfuehren
- Netzwerk-Beschraenkung auf API-Endpoints
- Automatische Projekt-Erkennung und CLI-Verwaltung
- Zero-Cleanup: Session-Ende = alles weg

## Was agentbox NICHT IST

- Kein Container-Runtime (kein Docker-Ersatz)
- Kein Schutz gegen WSL2-Kernel-Exploits (Microsoft-Verantwortung)
- Kein Schutz gegen boesartigen Code im Projektordner selbst (Agent hat dort r/w)
- Kein Multi-User-System (ein Entwickler, ein Rechner)
- DNS-Tunneling ist theoretisch moeglich (praktisch irrelevant)

## Lizenz

MIT
