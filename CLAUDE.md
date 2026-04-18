# agentbox — Projekt-Memory

## Architektur-Refactor (abgeschlossen 2026-04-17)

Der Umbrella-Refactor aus 2.0.2–2.0.12 ist durch. Prinzipien und
bewusste Skip-Entscheidungen stehen in `refactor.md`; die einzelnen
Etappen und Rationalen im `CHANGELOG.md`. Fuer zukuenftige Refactors
auf derselben Basis: `refactor.md` ist der Startpunkt, nicht
`CHANGELOG`.

## Projektziel & Architektur-Constraints

agentbox startet AI-Coding-Agents (Claude Code, Codex, Gemini, Aider, Goose) in
einer ephemeren WSL2-Sandbox auf Windows. Kern-Invarianten beim Ändern von Code:

- **Sandbox-Isolation ist hart:** kein Zugriff auf `/mnt/c`, kein Host-LAN,
  Firewall default-deny (nur 443 raus + Paketquellen je nach Projekttyp). Neue
  Features dürfen das nicht aufweichen.
- **Distro wird bei jedem Start frisch importiert und am Ende unregistriert** —
  alles was überleben muss, geht über Bind-Mount oder `%LOCALAPPDATA%\agentbox\`.
- **Runtime-State liegt strikt außerhalb `_control/`**, weil CONTROL_DIR
  typischerweise in OneDrive liegt und binärer/sensibler/großer State dort
  nichts verloren hat (Sync-Kosten, Files-On-Demand-Placeholder, Tokens in
  der Cloud). Fester Layout-Vertrag unter `%LOCALAPPDATA%\agentbox\`:
  - `sandbox\template.vhdx` (primaer, 2.0+) oder `sandbox\template.tar.gz`
    (Fallback fuer WSL < 2.0.x) + `sandbox\.config_hash` — WSL-Template
  - `cache\npm\`, `cache\pip\` — Paket-Caches
  - `sessions\<id>\` — Replay-Snapshots
  - `auth\<agent>\` — OAuth/Session-State der CLIs
  - `host-distro\` — persistente Host-WSL-Distro (Default)

  In `_control/` bleiben ausschließlich versionierte Scripts/Config/Libs.
  Beim Zugriff von Bash-Seite: Pfad via `cmd.exe /c echo %LOCALAPPDATA%` +
  `wslpath -u` auflösen (siehe `_resolve_agentbox_local_root` in
  `wsl-ai-start.sh`).
- **Claude Code OAuth-State**: das plaintext-Backend schreibt Tokens in
  `~/.claude/.credentials.json` (via `writeFileSync` + `chmod 0o600`, kein
  atomic rename). Die Datei liegt **innerhalb** des bind-mounted
  `.claude/`-Ordners — es genügt also **ein** Mount. `~/.claude.json`
  hingegen enthält nur Feature-Flags + UserID, keine Credentials.
- **PS 5.1 Kompatibilität** für Installer (`win-setup.ps1`, `install.ps1`,
  `win-setup-core.ps1`, `win-task-runner.ps1`): keine Here-Strings, kein
  `-Encoding utf8NoBOM`, LF/CRLF-Fallen beachten.
  - **NIEMALS `New-Item -LiteralPath` verwenden.** `-LiteralPath` wurde bei
    `New-Item` erst in PS 6 eingeführt, in PS 5.1 existiert der Parameter
    **nicht** und der Aufruf crasht mit `NamedParameterNotFound`. Schon
    zweimal aufgetreten (zuletzt 1.0.9-Regression). Fix für Directory-
    Creation immer: `[System.IO.Directory]::CreateDirectory($path) | Out-Null`
    — PS-5.1-kompatibel, idempotent wie `-Force`, und tilde-/umlaut-safe
    (umgeht den PS-Provider komplett, gleicher Grund wie bei
    `[System.IO.Directory]::Delete` statt `Remove-Item` auf Tilde-Pfaden).
    Für andere Cmdlets (`Test-Path`, `Remove-Item`, `Get-Content`,
    `Get-ChildItem`, `Copy-Item`, `Move-Item`, `Out-File`, `Expand-Archive`)
    ist `-LiteralPath` in PS 5.1 OK und soll wegen Tilde-Safety genutzt
    werden — die Regel gilt **nur** für `New-Item`.
- **Agent startet in `/workspace`** (Bind-Mount des Projektordners), damit die
  Projekt-Root für den Agent sichtbar ist.
- **Netzwerk-Mode:** seit 2.1.0 standardmäßig `networkingMode=mirrored` in
  `.wslconfig` bei WSL 2.0+ / Win11 22H2+ (Build ≥22621), sonst NAT. Die
  Isolation wird in **beiden** Modi durch iptables + ip6tables mit OUTPUT +
  INPUT default-deny, Host-IP-Autodetect-DROP und einen pflicht­mäßigen
  Firewall-Seal-Test aufrechterhalten — `mirrored` ist **kein** Isolations-
  Downgrade, nur ein NAT-Overhead-Bypass (Host-Speed statt ~50 %). Override
  per `network_mode` in `config.json` (`auto` | `nat` | `mirrored`). Achtung:
  `.wslconfig`-Setting ist **global**, betrifft ALLE WSL-Distros am Host
  (docker-desktop, andere Ubuntus etc.) — der Installer warnt gelb und
  triggert `wsl --shutdown` einmal beim Enabling. Wer das nicht will:
  `network_mode=nat` in `config.json` + `install.ps1` re-run.

## Config-Topologie

Zwei JSON-Dateien im Repo-Root, bewusst getrennt:

- **`config.json`** — System-/Agent-/Resources-Config. Alles was den
  Sandbox-Lifecycle steuert (WSL-Resources, aktivierte Agents und ihre
  Install-Commands, Update-Verhalten, Launcher-Wahl, Whitelists für
  Build/Deploy). Der Config-Hash in `win-setup-core.ps1:Get-AgentboxConfigHash`
  liest alle `agent_*`-Keys + `ubuntu_image_url`/`nodejs_setup_url` —
  ein neuer Key hier forciert beim nächsten `install.ps1`-Rerun einen
  Template-Rebuild.
- **`type_defaults.json`** — Projekt-Type-Defaults. Nur was beim ersten
  Anlegen eines neuen Projekt-Ordners in die generierte `project.json`
  reinmuss (`working_dir`, `entry_point`, Build-Command-Vorlage je
  Type). Ist für `wsl-ai-start.sh` bei Projekt-Auto-Detect relevant,
  nicht für den Template-Build.

Keine überlappenden Keys, keine Fallback-Kette zwischen den Dateien —
wer Runtime-Steuerung sucht, sucht in `config.json`; wer eine
Projekt-Template-Default braucht, in `type_defaults.json`.

Bash-seitig ist die einzige Lese-Schnittstelle `lib/config.sh`
(`cfg_get`, `cfg_get_array`, `cfg_get_agents`, `cfg_get_agents_all`) —
kein direktes python/jq/sed-Gemurkse in Scripts. Neue Reader gehören
in `lib/config.sh`, nicht ad-hoc an den Callsite.

## tools/ — Benchmark-Demoprojekt

`tools/` ist kein gewoehnlicher Script-Ordner, sondern ein mitgeliefertes
Demo-Projekt, das agentbox' WSL-Performance-Vorsprung zeigt. Beim Install
wird der Inhalt idempotent nach `<AI_PROJECTS_ROOT>\demo-benchmark\`
geseedet (Funktion `Seed-AgentboxDemoBenchmark` in `win-setup-core.ps1`,
laeuft nach `Register-AgentboxTaskRunner` in beiden Install-Pfaden).

Agent-Kontext steht in `tools/CLAUDE.md` — nicht hier dupliziert. Kurz:

- **bench.ps1** (Host) + **bench.sh** (WSL-Seite), paired Scripts,
  identische Workloads. Output: **`bench-results.json`** mit
  strict-overwrite pro Schluessel `{ host: {latest}, agentbox_host: {latest} }`
  — nur letzter Run pro Key, **kein JSONL** mehr (war bis 2.2.0 Append).
- **bench.sh** parametrisiert via `BENCH_PLATFORM` env var (Default
  `agentbox_host`), damit derselbe Script aus verschiedenen WSL-Kontexten
  heraus unter verschiedenen Keys schreiben kann -- heute nur
  `agentbox_host` (persistente Host-Distro, OHNE Session-Tunings),
  spaeter auch `sandbox` (ephemer, getuned) oder `default_wsl` (plain
  User-Ubuntu).
- Nur **bench.ps1** generiert `index.html` und oeffnet es via
  `Start-Process` im Host-Browser. `bench.sh` ist stumm, schreibt nur
  seine Seite der JSON via python3.
- Trigger ueber den bestehenden Task-Runner-Flow: Config-Submenue
  `[3] Benchmark ausfuehren` in `wsl-ai-start.sh` misst die Sandbox-Seite
  synchron, legt ein Task-JSON in `demo-benchmark/_tasks/` ab und
  emittiert dann ein **Trigger-Event** (Source `AIProjects`, EventID
  **2000**) via `powershell.exe`-Interop. Der `agentbox-task-runner`
  Scheduled-Task hat dieses Event als Trigger (plus AtLogon-Sweep als
  Safety-Net) — feuert das Event, startet der Runner im `-once`-Mode,
  fuehrt `build.command` aus der `project.json` aus und schreibt
  Audit-Events 1001/1002/1003 in Application-Event-Log (gleiche Source).
- **build_whitelist** muss `powershell -NoProfile -ExecutionPolicy Bypass
  -File bench.ps1` enthalten (steht in `config.json` und im hardcoded
  Fallback in `win-task-runner.ps1`).

Wer das Demo-Projekt aendert, aendert die Source-of-truth in `tools/` —
die User-Kopie unter `demo-benchmark/` wird bei jedem `install.ps1`-Rerun
nur fuer **fehlende** Dateien nachgezogen (nie ueberschrieben, damit
User-Modifikationen erhalten bleiben). Fuer Force-Re-Seed: die fehlenden
Dateien in `demo-benchmark/` loeschen und install.ps1 rerun.

## Git-Workflow

- **Immer direkt auf `main` committen und pushen.** Keine Feature-Branches
  anlegen, auch nicht wenn der Session-Wrapper einen Branch vorgibt — in dem
  Fall auf `main` wechseln (bzw. die Änderungen dorthin übertragen) und von
  dort pushen.
- Vor dem Push kurz `git pull --rebase origin main`, um auf dem aktuellen
  Stand aufzusetzen.

## Release-Prozess: `.update_class` NICHT vergessen

Seit 1.0.17 läuft der Auto-Update-Flow in `wsl-ai-start.sh` zweigleisig:
**minor** (silent, kein Admin) vs **major** (prompt + elevated PS via WSL
interop). Steuerung über die Datei `.update_class` im Repo-Root. Bei
**jedem Release** muss diese Datei bewusst gesetzt werden, **bevor**
gepusht wird:

- **`minor`** (Default, 99% der Fälle): nur `.sh`/`.ps1`-Scripts,
  `config.json`-Keys, `lib/`-Helper, Dokumentation, Agent-Version-Bumps,
  CHANGELOG. Der User bekommt den Pull ohne UAC und ohne Interaktion.
- **`major`**: alles was einen `install.ps1`-Rerun als Admin braucht —
  z.B. neue Windows-Features, geänderte WSL-Version, Kernel-Update,
  neue Enable-WindowsOptionalFeature-Calls, strukturelle Änderungen am
  Template-Build (`win-setup-core.ps1`) die das alte Template nicht
  mehr versteht. Der User bekommt einen [1]/[2]-Prompt, bei [1] wird
  aus WSL heraus via `powershell.exe -Command "Start-Process ... -Verb
  RunAs"` ein elevated Installer gespawnt, die aktuelle agentbox-Session
  beendet sich.

Faustregel: **wenn du nur `wsl-sandbox-init.sh`, `wsl-ai-start.sh`,
`lib/*.sh`, `config.json` oder README/CHANGELOG anfasst → `minor`.** Sobald
du `install.ps1` in einer Art änderst, die den Erst-Install-Pfad
(Features/Kernel/Template-Rebuild-Struktur) betrifft → `major`.

Bei fehlender `.update_class`-Datei default = `minor` (sicherer smooth-
Upgrade-Pfad von Pre-1.0.17-Versionen). Fix für neue Releases: Datei
anlegen und committen.

## agentbox 2.0 — Performance-Architektur (implementiert in 2.0.0 + 2.0.1)

Hintergrund zur Motivation + Benchmarks: siehe
`docs/future-features/agentbox-2.0-architecture.md`. Hier nur die
Invarianten + Stolperfallen, die man beim Weiterarbeiten wissen muss.

### Template-Format: vhdx primaer, tar.gz nur als Fallback

- `win-setup-core.ps1` exportiert `template.vhdx` via
  `wsl --export --vhd` **zuerst**. Nur wenn der vhdx-Export fehlschlaegt
  (WSL < 2.0.x, kein `--export --vhd`-Support), wird zusaetzlich
  `template.tar.gz` erzeugt. Beides lebt in
  `%LOCALAPPDATA%\agentbox\sandbox\`.
- `wsl-ai-start.sh` bevorzugt beim Session-Start den vhdx-Fastpath:
  vhdx kopieren (~3-5s SSD) + `wsl --import-in-place` (<1s).
  Faellt auf `wsl --import` mit tar.gz zurueck, wenn vhdx fehlt oder
  `import-in-place` fehlschlaegt.
- Beide Pruefungen (`win-setup-core.ps1`-Skip-Check, `wsl-ai-start.sh`-
  Template-Pruefung) akzeptieren **eines von beiden** — nie davon
  ausgehen dass beide existieren. Wer Template-Logik anfasst muss beide
  Pfade sauber lassen.

### Hybrid-Workspace: ext4-Overlays fuer Heavy-I/O

In `wsl-sandbox-init.sh`, nach dem Bind-Mount des Projekts nach
`/workspace/src`, werden per `_overlay_bind_ext4` ext4-Ordner aus
`/var/agentbox-overlay/` ueber bekannte ephemere Unterverzeichnisse
gemountet:

```text
/workspace/src/
  <projekt-dateien>/  <- DrvFs (OneDrive-synced, crash-safe)
  node_modules/       <- ext4 im vhdx (500 files/s statt 125)
  .next/, dist/, build/, out/, target/
  __pycache__/, .pytest_cache/, .mypy_cache/, .ruff_cache/
```

Regeln:
- **Kein Overlay fuer `.git`** — zu riskant, wuerde Commit-History pro
  Session verlieren.
- **Kein Overlay fuer beliebige User-Ordner** — nur die harte Liste in
  `wsl-sandbox-init.sh`. Erweiterungen nur wenn das Verzeichnis klar
  reproduzierbar ist (aus `package.json`/`requirements.txt` regener-
  ierbar).
- Wenn ein Overlay-Ziel in `/workspace/src/` nicht existiert, legt
  `_overlay_bind_ext4` es praeemptiv auf DrvFs an (1 leerer Ordner,
  OneDrive-sync-irrelevant) und ueberlagert ihn sofort mit ext4.

### Netzwerk-Tuning (live in `wsl-sandbox-init.sh`)

Alles additiv mit `|| true`-Fallback; kein Kernel-Feature ist Pflicht.

- **TCP BBR** via `modprobe tcp_bbr` + `sysctl tcp_congestion_control=bbr`.
  Faellt still auf Kernel-Default (cubic) wenn BBR nicht verfuegbar.
- **TCP Fast Open** (`tcp_fastopen=3`) fuer einen gesparten Roundtrip
  pro neuer HTTPS-Connection.
- **Socket-Buffer** (rmem/wmem bis 16 MB) fuer hohe-Durchsatz-Downloads.
- **PMTU-Probing** (`tcp_mtu_probing=1`) gegen Fragmentierungs-Stalls
  bei VPN/Corporate-Proxies.
- **Lokaler DNS-Cache** via `dnsmasq` auf `127.0.0.1` wenn
  `dnsmasq-base` im Template installiert ist (wird seit 2.0.0 im
  apt-Basis-Install mitgezogen). Bei fehlendem binary: direkter
  Upstream-Fallback auf 8.8.8.8/1.1.1.1 wie in 1.x.

### Template-Build-Beschleunigung (seit 2.0.1)

Gilt nur fuer den einmaligen Build in `win-setup-core.ps1`, Session-
Runtime nicht betroffen:

- `force-unsafe-io` in `/etc/dpkg/dpkg.cfg.d/99-agentbox-unsafe-io`
  (spart ~30-50s). Safe, weil das Template bei Crash eh verworfen wird.
- apt-Pipelining in `/etc/apt/apt.conf.d/99-agentbox-fastbuild`
  (`Pipeline-Depth=20`, `Queue-Mode=access`). ~20-30s.
- Parallele Agent-Installs via `_run_agent ... &` + `wait`. Jeder
  Agent schreibt in `/tmp/agent-<slug>.log`; bei Fail wird Tail ins
  Haupt-Install-Log gemirrored. ~30-60s.
- tar.gz-Export komplett weggelassen wenn vhdx-Export klappt. ~60-90s.

### `template_schema` — Build-Cache-Invalidierung

`Get-AgentboxConfigHash` in `win-setup-core.ps1` haelt eine
`template_schema=N`-Zeile. **Bump diese Zahl, wenn du am
Template-Build-Script etwas aenderst, das einen Rebuild erzwingen muss,
ohne dass sich `config.json` aendert** (neue apt-Pakete, neue sysctls
im Template, geaenderte npm/pip-Calls). Ohne Bump kommen User-
Installationen mit gecachtem alten Template am `Skip-Build`-Check vorbei
und sehen die Aenderung nie.

Bisherige Bumps: `1` = 1.x, `2` = 2.0.0 (`dnsmasq-base`), `3` = 2.0.1
(Build-Performance + Export-Reihenfolge).

### Bewusst NICHT gemacht

- **`.git` auf ext4** — zu riskant fuer Commit-History.
- **npm/pip-Cache in vhdx** — bleibt auf DrvFs (persistiert ueber
  Sessions, OneDrive-harmlos). Wenn spaeter Hit-Raten-Benchmarks einen
  klaren Gewinn zeigen, separat angehen.
- **Multi-Projekt-VHD-Pool / Dev-Drive-Detection / Alpine-Distro** —
  Later. Aktuelle Flaeche ist schon gross genug.
