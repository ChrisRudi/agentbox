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
