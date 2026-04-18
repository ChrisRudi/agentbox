# benchmarks — agentbox Build-Flow Demo

Ein Starter-Projekt, das den kompletten Build-Task-Runner-Flow von
agentbox zeigt: Agent in der Sandbox triggert → Host-Runner validiert
→ PowerShell-Bench läuft auf Windows-Host → `index.html` mit
Wirkungsgrad-Tabelle wird generiert.

## Setup

Ordner einmalig nach `AI_Projects_Source/` kopieren:

```powershell
Copy-Item -Recurse "$env:OneDrive\AI_Projects_Source\_control\examples\benchmarks" `
                   "$env:OneDrive\AI_Projects_Source\benchmarks"
```

Danach `agentbox` starten → Projekt `benchmarks` wählen → beliebigen
Agent wählen. Der Agent liest beim Session-Start die `CLAUDE.md` in
diesem Ordner und weiß, dass er einen Build triggern soll.

Für den vollständigen Host-vs-Sandbox-Vergleich einmal vorher in der
Sandbox `bash _control/tools/bench.sh` laufen lassen — das appendet
eine Sandbox-Zeile an `bench-results.jsonl`, die der Build dann mit
der Host-Messung gegenüberstellt.

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
   Bench echte Host-Disk-, CPU-, Netz- und Prozess-Spawn-Performance).

4. **`build.ps1`** delegiert an `_control/tools/bench.ps1` (v2.2.0+),
   das 5 Workloads misst: Netz-Download, Disk-seq-Write, Small-Files,
   SHA256-Durchsatz, Process-Spawn.

5. **Resultate** werden an `bench-results.jsonl` im Projektroot
   angehängt (eine JSONL-Zeile pro Run, `platform=host` oder
   `platform=sandbox`). Nach der Messung generiert `bench.ps1` ein
   statisches **`index.html`** mit Durchschnitten über alle
   bisherigen Host- und Sandbox-Runs sowie dem Wirkungsgrad
   (host/sandbox, auf 100 % gedeckelt).

6. **Status** wird in `_tasks/status_build.json` geschrieben:
   ```json
   { "status": "done", "timestamp": "2026-04-18T14:30:12" }
   ```
   Der Agent pollt diese Datei und liest anschließend
   `bench-results.jsonl` + `index.html` ein.

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
| `build.ps1` | Thin Wrapper, delegiert an `_control/tools/bench.ps1` |
| `CLAUDE.md` | Agent-Priming — sagt dem Agent, was dieses Projekt demonstriert |
| `README.md` | Diese Datei (für Menschen) |
| `bench-results.jsonl` | Entsteht nach erstem Build-Run (JSONL-Append über alle Runs) |
| `index.html` | Wird von `bench.ps1` generiert — Durchschnitte + Wirkungsgrad |
| `_tasks/` | Task-Trigger-Ordner (Agent schreibt `.json`, Runner schreibt `status_*.json`) |
| `build_out/` | Build-Output-Verzeichnis (per `project.json` konfiguriert) |
