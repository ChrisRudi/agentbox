# benchmarks — agentbox Build-Flow Demo

Ein Starter-Projekt, das den kompletten Build-Task-Runner-Flow von
agentbox zeigt: Agent in der Sandbox triggert → Host-Runner validiert
→ PowerShell-Skript läuft auf Windows-Host.

## Setup

Ordner einmalig nach `AI_Projects_Source/` kopieren:

```powershell
Copy-Item -Recurse "$env:OneDrive\AI_Projects_Source\_control\examples\benchmarks" `
                   "$env:OneDrive\AI_Projects_Source\benchmarks"
```

Danach `agentbox` starten → Projekt `benchmarks` wählen → beliebigen
Agent wählen. Der Agent liest beim Session-Start die `CLAUDE.md` in
diesem Ordner und weiß, dass er einen Build triggern soll.

## Was passiert

1. **Agent in der Sandbox** schreibt `_tasks/build_001.tmp` und
   benennt sie zu `_tasks/build_001.json` um (Atomic-Rename, damit
   der Watcher keine halbe Datei sieht):
   ```json
   { "project": "benchmarks", "action": "build", "timestamp": "2026-04-18T14:30:00" }
   ```

2. **`win-task-runner.ps1`** (Host-seitiger Dienst) picked die Datei
   auf, liest `project.json`, prüft `build.command` gegen
   `config.json:build_whitelist` (exakter String-Match).

3. **Exakter Match** → Runner startet:
   ```cmd
   cmd.exe /c cd /d <ProjectDir> && powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1
   ```
   auf dem **Windows-Host** (nicht in der Sandbox — deshalb misst die
   Bench echte Host-Disk- und Netz-Performance).

4. **`build.ps1`** ruft `_control/tools/bench.ps1` auf; das Ergebnis
   landet in `bench-results.txt` im Projektroot.

5. **Status** wird in `_tasks/status_build.json` geschrieben:
   ```json
   { "status": "done", "timestamp": "2026-04-18T14:30:12" }
   ```
   Der Agent pollt diese Datei und sieht das Ergebnis.

## Warum `build.ps1` als Convention

`powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1` ist
in agentbox das **universelle PS-Äquivalent** zu `npm run build` /
`pip install -r requirements.txt` / `make`:

- `-NoProfile`: keine User-Profile-Seiteneffekte, reproduzierbar.
- `-ExecutionPolicy Bypass`: User-Workspace-Skripte sind unsigniert —
  greift nur für **diesen einen** Invocation, ändert keine globale
  Policy.
- `-File build.ps1`: relativer Pfad, weil der Runner vorher ins
  Projekt-Verzeichnis `cd`t.

Jedes neue `powershell`-Projekt bekommt diesen Build-Command per
Default aus `type_defaults.json` — muss nur ein `build.ps1` anlegen.

## Security-Boundaries

- Command wird **exakt** gegen die Whitelist in `config.json`
  geprüft. Kein Glob, kein Prefix, kein Wildcard.
- Script läuft mit **User-Rechten** auf dem Host, nicht als Admin.
- `build.ps1` **muss im Projektordner liegen** — der Runner `cd`t
  vorher rein, daher keine Pfad-Escape-Möglichkeit via `..\`.
- Agent hat **read-only** auf `project.json` (per
  `SYSTEM_META_PROMPT.md`-Contract) — kann den Build-Command nicht
  selbst ändern, nur triggern.

## Dateien in diesem Projekt

| Datei | Zweck |
|---|---|
| `project.json` | Typ + Build-Command (read-only für Agent) |
| `build.ps1` | Das Skript, das der Runner ausführt |
| `CLAUDE.md` | Agent-Priming — sagt dem Agent, was dieses Projekt demonstriert |
| `README.md` | Diese Datei (für Menschen) |
| `bench-results.txt` | Entsteht nach erstem Build-Run |
| `_tasks/` | Task-Trigger-Ordner (Agent schreibt `.json`, Runner schreibt `status_*.json`) |
| `build_out/` | Build-Output-Verzeichnis (per `project.json` konfiguriert) |
