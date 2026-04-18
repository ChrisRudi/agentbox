# tools/ — agentbox Benchmark-Demoprojekt

## Was ist das?

Dieses Verzeichnis ist ein **mitgeliefertes Beispiel-Projekt**, das den
Performance-Vorsprung der agentbox-Sandbox (ext4 in vhdx, TCP-Tuning,
parallele Build-Paths) gegenueber dem nativen Windows-Host demonstriert.
Beim Install wird der komplette Inhalt **idempotent** nach
`<AI_PROJECTS_ROOT>\demo-benchmark\` geseedet, damit User direkt einen
spielbereiten agentbox-Workspace mit Projekt-Auto-Erkennung sehen.

## Architektur

Zwei gepaarte Bench-Scripts mit identischen Workloads:

- **`bench.ps1`** (Host, Windows PowerShell 5.1 + PS 7) — misst die
  Host-Seite, aggregiert beide Seiten zu `bench-results.json`, generiert
  `index.html` mit Vergleichstabelle und oeffnet sie im Standard-Browser
  (`Start-Process`).
- **`bench.sh`** (Sandbox, Ubuntu 24.04 in WSL) — misst die Sandbox-Seite
  und schreibt sie in die gemeinsame `bench-results.json`. Kein HTML,
  kein Browser-Trigger — das ist Host-Sache.

Getestete Metriken pro Seite:

1. Netzwerk: 100 MB HTTPS-Download (Multi-URL-Fallback)
2. Disk sequentiell: 1 GB Write
3. Disk small-files: 10 000 x 4 Byte
4. CPU: SHA256 ueber 500 MB
5. Process spawn: 500 x `/bin/true` bzw. `cmd /c exit`

## JSON-Format

`bench-results.json` — **strict overwrite**, nur letzter Run pro Seite
(kein History-Append, kein JSONL):

```json
{
  "host":    { "timestamp": "...", "version": "3.0.1", "net_mbs": ..., "disk_seq_mbs": ..., "disk_small_files_per_s": ..., "cpu_sha256_mbs": ..., "proc_spawn_per_s": ... },
  "sandbox": { "timestamp": "...", "version": "3.0.1", "net_mbs": ..., "disk_seq_mbs": ..., "disk_small_files_per_s": ..., "cpu_sha256_mbs": ..., "proc_spawn_per_s": ... }
}
```

Jeder Bench-Lauf liest das File, ueberschreibt **nur seine eigene Seite**
(`host` oder `sandbox`) und schreibt zurueck. Die andere Seite bleibt
erhalten, damit bench.ps1 beim HTML-Rendering beide Werte hat.

## Build-Hook — Task-Runner-Integration

`project.json` setzt `build.command = "powershell -NoProfile
-ExecutionPolicy Bypass -File bench.ps1"`. Damit wird der Benchmark ueber
den agentbox-**Task-Runner-Flow** ausgeloest (kein manueller Aufruf
noetig):

```
Menu [c] Konfiguration -> [3] Benchmark ausfuehren
  -> bench.sh laeuft synchron in der Sandbox, schreibt .sandbox
  -> Task-JSON landet in demo-benchmark/_tasks/bench-<ts>.json
  -> powershell.exe Write-EventLog Source=AIProjects EventID=2000
  -> Scheduled-Task agentbox-task-runner (EventLog-getriggert) startet
  -> win-task-runner.ps1 -once: Process-AllTasks findet das File
  -> liest project.json, fuehrt build.command aus
  -> bench.ps1 misst Host, mergt .host, schreibt index.html, oeffnet Browser
  -> Event-Log-Audit: 2000 (triggered), 1001 (gestartet), 1002 (erledigt)
```

Das zeigt dem User gleichzeitig, wie der **Build-Mechanismus ausserhalb
der Sandbox** funktioniert — agentbox fuehrt den Build nicht selbst aus,
sondern delegiert an den Host-Runner via EventLog-Trigger.

## Agent-Regeln

- **Metriken erweitern** ist erlaubt — aber beide Scripts (`.ps1` + `.sh`)
  synchron halten, sonst bricht der HTML-Rendering (fehlende Keys werden
  als `n/a` dargestellt).
- **JSON-Struktur NICHT aendern** — das HTML-Template in `bench.ps1`
  liest die Keys hart. Neue Metriken: Key in beiden Scripts hinzufuegen
  + HTML-Renderer-Block in `bench.ps1` erweitern.
- **Keine externen Dependencies** — PS 5.1 + plain bash + curl/jq/python3
  (alle im agentbox-Template vorhanden). Kein npm, kein pip install, kein
  `jq`-Fallback ohne python3-Fallback (jq ist im Template, aber die
  python3-Variante ist der Safety-Net bei Template-Schema-Drift).
- **ASCII-only** im Output — PS 5.1 parset UTF-8-Dashes/Arrows als Fehler,
  siehe Root-CLAUDE.md PS-5.1-Regeln.
- **Idempotent** — jeder Bench-Run darf beliebig oft laufen. Kein
  Aufraeumen von `bench-results.json` zwischen Runs noetig, da jede Seite
  nur ihre eigene Haelfte ueberschreibt.

## Dateien

| Datei | Zweck |
|---|---|
| `bench.ps1` | Host-Bench + HTML-Gen + Browser-Open |
| `bench.sh`  | Sandbox-Bench, schreibt `.sandbox`-Seite |
| `bench-results.json` | Output, nur letzter Run pro Seite (gitignored) |
| `index.html` | HTML-Report, bei jedem Host-Run ueberschrieben |
| `project.json` | agentbox Projekt-Config, `build.command` -> bench.ps1 |
| `CLAUDE.md` | Dieses Dokument |
