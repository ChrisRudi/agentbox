# tools/ — agentbox Benchmark-Demoprojekt

## Was ist das?

Dieses Verzeichnis ist ein **mitgeliefertes Beispiel-Projekt**, das den
Performance-Unterschied zwischen Windows-Host und einer WSL-Distro
misst. Beim Install wird der Inhalt **idempotent** nach
`<AI_PROJECTS_ROOT>\demo-benchmark\` geseedet.

## Architektur

Zwei gepaarte Bench-Scripts mit identischen Workloads:

- **`bench.ps1`** (Host, Windows PowerShell 5.1 + PS 7) — misst die
  Host-Seite (`.host`), rendert `bench-results.json` zu einer
  `index.html`-Tabelle und oeffnet sie im Standard-Browser
  (`Start-Process`).
- **`bench.sh`** (Linux, in irgendeiner WSL-Distro) — misst die WSL-
  Seite. Der JSON-Schluessel wird ueber die Env-Variable
  `BENCH_PLATFORM` bestimmt (Default: `agentbox_host`).
  Kein HTML, kein Browser-Trigger -- das ist Host-Sache.

## Was ist die `agentbox_host`-Seite?

Das Config-Submenue `[3] Benchmark ausfuehren` in `wsl-ai-start.sh`
laeuft aus der **persistenten Host-Distro `agentbox-host` heraus**,
BEVOR die ephemere Agent-Session ueberhaupt importiert und getuned
wurde. Die gemessene WSL-Seite hat also:

- [x] Template-Paketstand (Node, Python, Agents)
- [x] Basis-Sysctl-Hardening aus dem Template-Build
- [ ] **keine** Session-Time-Tunings: kein ext4-Overlay fuer Heavy-I/O,
      kein BBR, kein dnsmasq-Cache -- die wirken erst in der
      ephemeren Sandbox waehrend einer Agent-Session.

Deshalb ehrlicher Name: `agentbox_host`. Das HTML sagt das auch in
der Legende unter der Tabelle explizit.

`BENCH_PLATFORM` ist bewusst parametrisierbar, damit spaetere Features
(ein `[4] Benchmark inkl. tuned Sandbox`) dieselbe `bench.sh` mit
`BENCH_PLATFORM=sandbox` aus einer frisch-getunten Sandbox heraus
aufrufen koennen. Das landet dann neben `.agentbox_host` unter
`.sandbox` in derselben JSON.

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
  "host":          { "timestamp": "...", "platform": "host",          "version": "3.0.2", "net_mbs": ..., "disk_seq_mbs": ..., "disk_small_files_per_s": ..., "cpu_sha256_mbs": ..., "proc_spawn_per_s": ... },
  "agentbox_host": { "timestamp": "...", "platform": "agentbox_host", "version": "3.0.2", "net_mbs": ..., "disk_seq_mbs": ..., "disk_small_files_per_s": ..., "cpu_sha256_mbs": ..., "proc_spawn_per_s": ... }
}
```

Zukuenftig moeglich (nicht jetzt aktiv): `.sandbox` (tuned ephemeral),
`.default_wsl` (user's plain Ubuntu) als weitere Keys -- dann hat die
Tabelle mehrere WSL-Spalten.

Jeder Bench-Lauf liest das File, ueberschreibt **nur seinen eigenen
Key** (per `BENCH_PLATFORM`) und schreibt zurueck. Andere Keys bleiben
erhalten.

## Build-Hook — Task-Runner-Integration

`project.json` setzt `build.command = "powershell -NoProfile
-ExecutionPolicy Bypass -File bench.ps1"`. Damit wird der Benchmark ueber
den agentbox-**Task-Runner-Flow** ausgeloest (kein manueller Aufruf
noetig):

```
Menu [c] Konfiguration -> [3] Benchmark ausfuehren
  -> bench.sh laeuft synchron in agentbox-host, schreibt .agentbox_host
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
| `bench.sh`  | WSL-Bench, schreibt `.$BENCH_PLATFORM`-Seite (Default: `.agentbox_host`) |
| `bench-results.json` | Output, nur letzter Run pro Key (gitignored) |
| `index.html` | HTML-Report, bei jedem Host-Run ueberschrieben |
| `project.json` | agentbox Projekt-Config, `build.command` -> bench.ps1 |
| `CLAUDE.md` | Dieses Dokument |
