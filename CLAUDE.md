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

### Lösung (2.0): ext4-VHD als Workspace-Cache

**Kernidee:** eine sparse VHDX-Datei (~10 GB, startet bei ~4 KB auf Disk)
in `%LOCALAPPDATA%\agentbox\` ablegen, als ext4 formatieren, und über
`wsl --mount --vhd` als Block-Device direkt in die Sandbox mounten.
Damit umgeht der Agent den 9P-Pfad komplett:

```
App → Linux VFS → ext4 (Block-Level) → Hyper-V VHD I/O → Disk
```

**Erwarteter Gewinn:** 5-10x schnellere I/O während der Agent-Session.

### Architektur-Entwurf

```
Installer (install.ps1, einmalig):
  1. Sparse VHDX erstellen:  New-VHD -Path $vhdPath -SizeBytes 10GB -Dynamic
  2. Als ext4 formatieren:   wsl --mount --vhd $vhdPath --bare
                             mkfs.ext4 /dev/sdX
                             wsl --unmount $vhdPath

Sandbox-Start (wsl-ai-start.sh, jede Session):
  3. VHD mounten:            wsl --mount --vhd $vhdPath --bare
  4. In Sandbox verfuegbar:  mount /dev/sdX /workspace-fast (ext4, noatime)
  5. overlayfs:              mount -t overlay overlay /workspace/src \
                               -o lowerdir=<DrvFs-Projekt>,
                                  upperdir=/workspace-fast/upper,
                                  workdir=/workspace-fast/work
     → Reads gehen erst zum ext4-Upper, dann DrvFs-Lower (gecacht)
     → Writes gehen NUR auf ext4 (Memory-/Block-Speed)

Agent-Session:
  6. Agent arbeitet auf /workspace/src (overlayfs-Merged-View)
     → Near-native ext4 Performance

Sandbox-Ende (wsl-sandbox-init.sh / wsl-ai-start.sh):
  7. Upper-Layer-Diff auf DrvFs zuruecksyncen:
     rsync -a /workspace-fast/upper/ <DrvFs-Projekt>/
  8. VHD unmounten:  wsl --unmount $vhdPath
  9. Sandbox unregistrieren (wie bisher)
```

### Offene Fragen / Risiken

- **`wsl --mount` braucht Admin** auf Win10; auf Win11 22H2+ reicht die
  `disk`-Gruppe. Muss getestet werden.
- **overlayfs + DrvFs als Lower:** ob WSL2's Kernel (5.15+) das
  unterstützt, muss mit einem Einzeiler getestet werden:
  ```bash
  mount -t overlay test \
    -o lowerdir=/mnt/c/test,upperdir=/tmp/u,workdir=/tmp/w /tmp/m
  ```
- **Crash-Recovery:** wenn die Sandbox abstürzt vor dem Sync, sind
  Änderungen im Upper-Layer weg. Mitigation: Agent committet in Git,
  also sind nur uncommittete Edits betroffen (akzeptabel).
- **VHD-Lifecycle:** wer räumt auf? Braucht Garbage-Collection für
  verwaiste VHDs nach abgebrochenen Sessions.
- **Speicherverbrauch:** sparse VHDX wächst dynamisch. Bei vielen
  Projekten mit großen node_modules könnten 10 GB knapp werden. Evtl.
  TRIM/discard regelmäßig.
- **Fallback:** wenn `wsl --mount` fehlschlägt (Permissions, alter
  Kernel), muss der 1.x-DrvFs-Pfad als Fallback erhalten bleiben.

### Implementierungs-Reihenfolge

1. **PoC:** VHD-Mount + overlayfs in einer Test-Sandbox manuell
   ausprobieren (Einzeiler-Tests, kein Code)
2. **install.ps1:** VHD-Erstellung + ext4-Formatierung im Installer
3. **wsl-ai-start.sh:** VHD-Mount vor Sandbox-Import
4. **wsl-sandbox-init.sh:** overlayfs statt direktem Bind-Mount
5. **Sync-Logik:** rsync Upper→DrvFs am Session-Ende
6. **Cleanup:** VHD-Unmount + Garbage-Collection
7. **Fallback-Pfad:** wenn VHD-Mount fehlschlägt, 1.x-DrvFs-Bind-Mount
8. **`.update_class = major`** für das Release (VHD-Erstellung braucht
   initial install.ps1-Rerun)

### Nicht in 2.0 (Later)

- Template-Extraktion direkt auf VHD statt DrvFs-Temp-Dir (könnte
  den 30-120s wsl-import auf ~5-15s drücken)
- npm/pip-Cache auf VHD statt DrvFs (weiterer I/O-Gewinn)
- Multi-Projekt-VHD-Pool (ein VHD pro Projekt, parallele Sessions)
