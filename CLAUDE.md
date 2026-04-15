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
  `win-setup-core.ps1`): keine Here-Strings, kein `-Encoding utf8NoBOM`,
  LF/CRLF-Fallen beachten.
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
