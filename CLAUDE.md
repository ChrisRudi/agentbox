# agentbox — Projekt-Memory

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
  - `sandbox\template.tar.gz` + `sandbox\.config_hash` — WSL-Template
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

## Roadmap: agentbox 2.0 — Performance-Architektur

### Problem (1.x)

Alle Projektdateien, Caches und Auth-State liegen auf **DrvFs** (Windows
NTFS via 9P-Protokoll). Das ist 3-10x langsamer als natives ext4 im
WSL2-VM. Jeder `git status`, jeder `npm install`, jedes Datei-Read/Write
geht durch:

```
App → Linux VFS → 9P Client → Hyper-V VMBus → 9P Server → Windows I/O → NTFS → Disk
```

1.x-Tuning (noatime, iptables-Reorder, DNS, chown-Eliminierung) hat die
schlimmsten Bremsen rausgenommen, kann aber den fundamentalen 9P-Overhead
nicht beseitigen.

**Gemessene Zahlen** (User-Benchmark 1.0.28):
- ext4 (/tmp): 495 MB/s write, 6.2 GB/s read (cached), 500 files/s
- DrvFs (/workspace): 44 MB/s write, 161 MB/s read, 125 files/s
- **Faktor: 4-11x langsamer auf DrvFs**

**Wettbewerbs-Vorteil:** ALLE Konkurrenten (Docker-basiert wie vibekit,
textcortex, rivet; WSL-basiert wie claudecode-wsl2, sandvault) leiden
unter demselben DrvFs/9P-Overhead wenn sie Windows-Dateien anfassen.
Docker Desktop auf Windows nutzt intern denselben 9P-Kanal für Bind-
Mounts. Wenn agentbox diesen Flaschenhals eliminiert, ist das ein
Performance-Alleinstellungsmerkmal das kein Konkurrent hat.

### Lösung (2.0): Hybrid-Architektur — vhdx-Template + ext4-Workspace

#### Kernideen

1. **Template als vhdx statt tar.gz** — `wsl --export --vhd` speichert
   das fertige Template als vhdx-Datei. Session-Start = File-Copy der
   vhdx (~3-5s auf SSD) + `wsl --import-in-place` (<1s) statt tar.gz-
   Extraktion (30-120s). **Kein Admin nötig** — `wsl --import-in-place`
   ist eine User-Level-Operation.

2. **Hybrid-Workspace: Quellcode auf DrvFs (sicher), Heavy-I/O auf
   ext4 (schnell)** — Quellcode-Dateien (src/) bleiben per Bind-Mount
   auf DrvFs/OneDrive (crash-safe, cloud-synced, kein Datenverlust).
   Alles was Heavy-I/O erzeugt (node_modules, .git/objects, dist/,
   __pycache__, Build-Artefakte) lebt auf dem ext4-Filesystem der
   Sandbox-vhdx. **Kein Sync nötig, kein Crash-Risiko für Quellcode.**

   ```
   /workspace/
     src/           ← Bind-Mount von DrvFs (sicher, OneDrive-synced)
     node_modules/  ← ext4 im vhdx (schnell, ephemer, recreatable)
     .git/          ← ext4 im vhdx (schneller git status/log/diff)
     dist/          ← ext4 im vhdx (schnelle Builds)
     __pycache__/   ← ext4 im vhdx
   ```

   Agent schreibt Quellcode → geht sofort auf DrvFs/OneDrive (safe).
   Agent macht `npm install` → 10.000 Dateien auf ext4 (500 files/s).
   **Best of both worlds.**

#### Architektur-Entwurf

```
Installer (install.ps1, einmalig):
  1. Template bauen:     wsl --import template-build <tmpdir> <ubuntu.tar.xz>
                         [Node, Python, Agent-CLIs installieren — wie bisher]
  2. Als vhdx sichern:   wsl --export --vhd template-build template.vhdx
                         wsl --unregister template-build
     → template.vhdx in %LOCALAPPDATA%\agentbox\sandbox\

Sandbox-Start (wsl-ai-start.sh, jede Session):
  3. vhdx kopieren:      Copy-Item template.vhdx → session.vhdx   (~3-5s SSD)
  4. Distro registrieren: wsl --import-in-place agentbox-<sess> session.vhdx  (<1s)
  5. wsl-sandbox-init.sh:
     - Quellcode bind-mounten: DrvFs → /workspace/src  (wie 1.x, sicher)
     - Heavy-I/O-Dirs auf ext4: node_modules, .git, dist, Cache
       bleiben im vhdx-Filesystem (schnell)

Agent-Session:
  6. Quellcode-Writes → DrvFs (safe, sofort auf OneDrive)
     Heavy-I/O (npm, git, build) → ext4 (500 files/s, 495 MB/s)

Sandbox-Ende:
  7. wsl --unregister agentbox-<sess>
  8. session.vhdx löschen
  → Kein rsync nötig! Quellcode war die ganze Zeit auf DrvFs.
  → node_modules etc. sind ephemer (werden bei nächstem npm install
    neu erzeugt, oder per Cache beschleunigt)
```

### Netzwerk-Tuning 2.0 — Ziel: Host-Level-Performance

**Status nach 1.x-Tuning:**
- DNS: 28ms ✓ (Google/Cloudflare, schnelle Resolver)
- TCP Handshake: 63ms ✓
- HTTPS HEAD: 250-450ms ✓ (TLS-Overhead, kaum reduzierbar)
- iptables: ESTABLISHED an Pos. 2, fast-path für 99% des Traffics ✓

**Was in 2.0 noch geht:**

1. **TCP BBR Congestion Control** — Googles Algorithmus, besser als
   cubic bei Paketverlust und hoher Latenz. Besonders relevant weil
   WSL2-NAT einen extra Hop einführt:
   ```bash
   modprobe tcp_bbr 2>/dev/null || true
   sysctl -w net.ipv4.tcp_congestion_control=bbr
   ```

2. **TCP Fast Open (TFO)** — spart einen Roundtrip beim TCP-
   Verbindungsaufbau. Jede neue HTTPS-Connection (npm registry,
   AI API, git push) profitiert:
   ```bash
   sysctl -w net.ipv4.tcp_fastopen=3
   ```

3. **Socket-Buffer-Tuning** — WSL2-Defaults sind konservativ.
   Grössere Buffer = weniger Syscalls pro Transfer, besserer
   Durchsatz bei grossen Downloads:
   ```bash
   sysctl -w net.core.rmem_max=16777216
   sysctl -w net.core.wmem_max=16777216
   sysctl -w net.ipv4.tcp_rmem="4096 131072 16777216"
   sysctl -w net.ipv4.tcp_wmem="4096 131072 16777216"
   ```

4. **Lokaler DNS-Cache** — aktuell geht jede DNS-Query direkt an
   8.8.8.8/1.1.1.1. npm/pip machen 50-200 DNS-Queries pro Install
   (registry.npmjs.org, cdn.npmjs.org, ...). Ein lokaler dnsmasq-
   Cache hält aufgelöste Adressen im Speicher:
   ```bash
   apt-get install -y dnsmasq
   # /etc/dnsmasq.conf: server=8.8.8.8, cache-size=1000
   # /etc/resolv.conf: nameserver 127.0.0.1
   ```
   Erwarteter Gewinn: DNS-Latenz von 28ms auf <1ms für wiederholte
   Lookups (99% der Fälle bei npm/pip install).

5. **MTU-Optimierung** — WSL2-NAT kann MTU-Mismatches verursachen
   die zu TCP-Fragmentierung führen. Korrekter MTU = weniger Overhead:
   ```bash
   # In wsl-sandbox-init.sh: auto-detect und setzen
   ip link set dev eth0 mtu $(cat /sys/class/net/eth0/mtu) 2>/dev/null
   ```

**Wettbewerbs-Pitch:** "agentbox: die einzige AI-Agent-Sandbox mit
TCP BBR, DNS-Caching, Buffer-Tuning und iptables-Fastpath. Alle
anderen nutzen die WSL2/Docker-Defaults — wir nicht."

### Offene Fragen / Risiken

- **`wsl --export --vhd` und `wsl --import-in-place`** — verfügbar
  seit WSL 2.0.x (ca. 2023). Ältere WSL-Versionen unterstützen das
  nicht → Fallback auf 1.x tar.gz-Pfad nötig.
- **vhdx-Größe:** Template ist ~3 GB (Ubuntu + Node + Python + 5
  Agent-CLIs). Sparse VHDX startet kleiner, wächst auf Disk aber
  während der Session (node_modules etc.). 10 GB Limit sollte
  reichen, Monitoring via `du` sinnvoll.
- **Crash-Recovery:** Quellcode ist sicher (DrvFs/OneDrive). Ephemere
  Daten (node_modules, Build-Artefakte) gehen bei Crash verloren —
  akzeptabel, weil jederzeit regenerierbar.
- **dnsmasq im Template:** vergrössert das Template, muss beim Build
  installiert werden. Alternativ: nur die sysctl-Tunings ohne dnsmasq
  (leichtgewichtiger, 80% des Gewinns).
- **TCP BBR:** WSL2-Kernel muss `tcp_bbr` als Modul haben. Auf
  Standard-WSL2-Kernel (5.15+) vorhanden. `modprobe tcp_bbr` mit
  Fallback wenn fehlend.
- **Fallback:** wenn vhdx-Pfad fehlschlägt (alte WSL-Version, fehlende
  Befehle), muss der 1.x-DrvFs-Pfad als Fallback erhalten bleiben.

### Implementierungs-Reihenfolge

**Phase 1: Netzwerk-Tuning (niedrig-hängend, kein Architektur-Umbau)**
1. TCP BBR + TFO + Socket-Buffer sysctls in wsl-sandbox-init.sh
2. Lokaler DNS-Cache (dnsmasq oder systemd-resolved)
3. Benchmarks vorher/nachher

**Phase 2: vhdx-Template (der grosse Umbau)**
4. PoC: `wsl --export --vhd` + Copy + `wsl --import-in-place` manuell
   testen
5. win-setup-core.ps1: Template als vhdx exportieren
6. wsl-ai-start.sh: vhdx-Copy + import-in-place statt tar.gz-import
7. Fallback: wenn vhdx-Pfad fehlschlägt, 1.x tar.gz beibehalten

**Phase 3: Hybrid-Workspace**
8. wsl-sandbox-init.sh: Quellcode per Bind-Mount (wie 1.x), aber
   node_modules/.git/dist auf ext4 im vhdx belassen
9. Session-Ende: kein rsync nötig (Quellcode war immer auf DrvFs)

**Phase 4: Feinschliff**
10. `.update_class = major` für das Release
11. Benchmarks: vorher/nachher-Vergleich publizieren (README)
12. Competitive Claim: "5-10x faster I/O than stock WSL2/Docker"

### Nicht in 2.0 (Later)

- npm/pip-Cache auf vhdx statt DrvFs (weiterer I/O-Gewinn)
- Multi-Projekt-VHD-Pool (ein vhdx pro Projekt, parallele Sessions)
- Dev-Drive-Detection (ReFS Copy-on-Write für instant vhdx-Kopie)
- Netzwerk-Profiling pro Session (Latenz/Throughput-Report am Ende)
