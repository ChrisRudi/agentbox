# Changelog

All notable changes to agentbox are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.5] - 2026-04-14

### DAU-Fixes

Leitprinzip dieser Version: **agentbox muss starten, wenn ein DAU
doppelklickt — oder klar erklaeren warum nicht. Keine "trag mal das in
admin-PowerShell ein"-Aufgaben.** 1.0.4 hatte das halbherzig gemacht
(Pre-Flight zeigte nur Anweisungen statt sie auszufuehren). 1.0.5 macht
es richtig.

### Added

- **Auto-Update fuer veraltete WSL.** `install.ps1` ruft `wsl --update`
  jetzt selbst auf, wenn der Pre-Flight-Check Inbox-WSL erkennt. Fallback
  auf `wsl --update --web-download`, falls Standard-Update am Microsoft
  Store scheitert. Nur wenn beide Versuche failen, wird der User um
  manuelle Store-Installation gebeten — mit klick-fuer-klick-Anleitung,
  nicht mit CLI-Befehlen.
- **Reboot-Prompt nach erfolgreichem WSL-Update.** Statt "bitte starten Sie
  Windows neu und fuehren Sie install.ps1 erneut aus" bietet der Installer
  jetzt direkt `Restart-Computer -Force` an mit 10s-Countdown und Abbruch-
  Hinweis.

### Fixed

- **`agentbox-host` wird IMMER importiert**, nicht mehr nur wenn 0 Distros
  registriert sind. Frueher schaltete der Installer den Host-Distro-Setup
  ab, sobald *irgendeine* andere Distro registriert war — und bei Usern
  mit Docker Desktop landete dann jeder spaetere `wsl bash -c ...`-Aufruf
  in der `docker-desktop`-VM (laeuft als root, hat keine `~/.bashrc`),
  was den `grep: /root/.bashrc: No such file or directory`-Fehler aus
  unserem letzten Bug-Roundtrip ausloeste. Jetzt: agentbox-host wird
  idempotent erstellt (Skip, wenn schon vorhanden), unabhaengig von
  Fremd-Distros.
- **Alle `wsl bash -c`-Aufrufe in der `.bashrc`-Phase nutzen jetzt
  explizit `-d agentbox-host`**, statt sich auf die Default-Distro zu
  verlassen. Damit landen `.bashrc`-Reads, Konflikt-Cleanup, Migration
  und der finale `>> ~/.bashrc`-Append garantiert in unserer eigenen
  Distro, auch wenn der User docker-desktop, Ubuntu oder eine andere
  Distro als Default hat.
- **Desktop-Shortcut nutzt `wsl.exe -d agentbox-host -e bash -li -c
  agentbox`** statt nur `-e bash -li -c agentbox`. Vorher: Doppelklick
  bei Docker-Desktop-Usern landete in der Docker-VM und tat nichts.
  Jetzt: Doppelklick startet zuverlaessig agentbox-host, egal was die
  WSL-Default ist.
- **`Import-AgentboxHostDistro` setzt agentbox-host nur dann als WSL-
  Default, wenn der User keine eigene "echte" Distro hat.** docker-desktop
  und docker-desktop-data zaehlen dabei NICHT als echt — die ueberschreiben
  wir bewusst, weil docker-Nutzer ihre Container ueber `docker` CLI
  starten, nicht ueber `wsl`. Bei Usern mit Ubuntu/Debian/etc. bleibt
  ihre Default unangetastet, agentbox spricht seine Distro per `-d`
  immer explizit an.
- **`Invoke-WslUpdate`-Helper nutzt `$wslArgs` statt `$args`** — `$args`
  ist eine PS-Auto-Variable und in einem Function-Scope read-only;
  Zuweisung wuerde mit "Cannot overwrite variable args" abbrechen.

## [1.0.4] - 2026-04-14

### Added

- **WSL-Version-Pre-Flight in `install.ps1`.** Vor dem teuren Template-Build
  wird `wsl --version` aufgerufen. Inbox-WSL (in Windows eingebaut, vor der
  Store-Variante) kennt den Schalter nicht und kann das Ubuntu-24.04-Cloud-
  Minimal-Image nicht importieren — der spaetere `wsl --import` quittiert
  das mit einem generischen "Unbekannter Fehler" ohne Hinweis auf die
  Ursache. Wir fangen das jetzt frueh ab und zeigen einen klaren Fix-Pfad
  (`wsl --update`, Fallback `--web-download`, oder Store-Install + Reboot)
  statt den User durch 5 Minuten Mojibake-Output zu schicken.
- **Frueh-Abbruch in `install.ps1` bei fehlgeschlagenem Setup.** Wenn
  `win-setup.ps1` oder der Host-Distro-Rescue gefailt sind, wird jetzt
  unmittelbar danach mit einer klaren Fehlermeldung abgebrochen — vor der
  `.bashrc`-Integration, vor `.wslconfig`, vor Desktop-Shortcut. Frueher
  lief der Installer trotzdem weiter und produzierte Folgefehler wie
  `grep: /root/.bashrc: No such file or directory` gegen eine zufaellige
  Default-Distro (z.B. `docker-desktop`). Der spaete `$setupOk`-Check, der
  fast am Ende des Installers stand, ist damit obsolet und wurde entfernt.

### Fixed

- **`win-setup-core.ps1` `wsl --import`-Error-Reporting ist jetzt UTF-16-
  bewusst.** Alte wsl.exe-Versionen ignorieren `$env:WSL_UTF8` und schreiben
  Stderr/Stdout als UTF-16LE. Die `HCS_E_*`-Detection-Regex matchte nie,
  weil "H\0C\0S\0..." nicht auf "HCS" matcht. Wir strippen NUL-Bytes jetzt
  rigoros vor der Pattern-Erkennung und zeigen die rohe (gesaeuberte) wsl-
  Fehlermeldung in jedem Fall an, plus zusaetzliche Diagnose fuer
  "Unbekannter Fehler" / "Unspecified error" mit Verweis auf `wsl --update`.
- **Auto-Start-Prompt in `~/.bashrc` startet den Timer nach "n" nicht mehr
  erneut.** Der `.bashrc`-Block hatte keinen Schutz gegen doppeltes Sourcing
  (z.B. `bash -li` sourced `~/.profile`, das wiederum `~/.bashrc`, und der
  interactive-init triggert ein zweites `~/.bashrc`-Loading). Nach einem
  "n" beim 5s-Prompt erschien der Timer sofort wieder. Zwei neue Guards
  im `.bashrc`-Block:
  - `case "$-" in *i*)` — der Auto-Prompt laeuft nur in interaktiven Shells,
    nicht in non-interactive Source-Aufrufen.
  - `[ -z "$AGENTBOX_AUTO_PROMPTED" ]` + `export AGENTBOX_AUTO_PROMPTED=1` —
    einmal pro Login-Shell prompten, dann ist die Var im Environment, alle
    Sub-Shells und Re-Sources sehen sie und ueberspringen.
- **Bestandsinstalls bekommen die Auto-Prompt-Guards per Migration.** Der
  alte `.bashrc`-Block (ohne `AGENTBOX_AUTO_PROMPTED`) wird beim naechsten
  `install.ps1`-Lauf erkannt und aus der `.bashrc` entfernt — der frische
  Block mit Guards wird danach angehaengt. Backup vor der Migration unter
  `~/.bashrc.agentbox-pre-migrate`.

## [1.0.3] - 2026-04-13

### Fixed

- Auto-start prompt (`agentbox starten? [J/n]`) now actually honors
  `n` when entered from a Windows terminal. `read -r` strips LF but
  not CR, so CRLF-terminated input came through as `"n\r"` and
  missed the case pattern — the script then started agentbox anyway
  against the user's wish. Trailing CR and surrounding whitespace
  are now stripped before the comparison, and the match accepts
  `n`, `N`, `nein`, `no` in all common cases.
- `_toggle_agents_menu` no longer claims "Template-Rebuild folgt
  beim nächsten Start" — that was a lie, wsl-ai-start.sh runs as an
  unprivileged user inside WSL and cannot rebuild the template. The
  menu now tells the user to re-run `install.ps1` in an admin
  PowerShell instead.

### Changed

- Both READMEs (`README.md`, `docs/README.de.md`) now point at the
  in-app `[c] Konfiguration` menu for enabling/disabling agents
  instead of telling users to hand-edit `config.json`. The
  template-rebuild step via `install.ps1` is still required and is
  still documented.

## [1.0.2] - 2026-04-13

### Fixed

- Auto-approve seed for Claude Code now handles the case where Claude
  Code itself wrote an empty `{}` to `~/.claude/settings.json` on first
  start. The previous if-not-exists logic saw the file, skipped the
  seed, and left the user with permission prompts despite 1.0.1. The
  seed is now a smart merge:
  - Missing or empty/whitespace-only → write the default
  - Trivial `{}` → replace with the default
  - Other content → JSON-parse, add `permissions.defaultMode` only if
    absent, preserve every other user key (including existing
    `permissions.allow`/`permissions.deny` lists)
  - Invalid JSON → leave the file alone and warn
- Codex `config.toml` and Goose `config.yaml` seeds now also replace
  empty/whitespace-only files (simple empty-check, no TOML/YAML
  parser).
- Implemented in both `win-setup-core.ps1` (install time, PS 5.1 +
  `ConvertFrom-Json`/`ConvertTo-Json`) and `wsl-ai-start.sh` (session
  start, bash + `python3` for the JSON merge).

## [1.0.1] - 2026-04-13

### Added

- Auto-approve defaults for all five agents so the sandbox stops
  prompting on every tool call. The sandbox itself is the trust
  boundary; inside it, the permission prompts are pure friction.
  - Claude Code: `~/.claude/settings.json` with
    `permissions.defaultMode = "bypassPermissions"`
  - OpenAI Codex: `~/.codex/config.toml` with
    `approval_policy = "never"` + `sandbox_mode = "danger-full-access"`
  - Goose: `~/.config/goose/config.yaml` with `GOOSE_MODE: auto`
  - Gemini CLI: launched with `--approval-mode=yolo`
  - Aider: launched with `--yes-always`
- Config files are seeded under `%LOCALAPPDATA%\agentbox\auth\<agent>\`
  at install time (`win-setup-core.ps1`) and re-seeded at every
  session start (`wsl-ai-start.sh`), both with if-not-exists so user
  edits stick.

### Fixed

- Package-install phase (`win-setup-core.ps1`) streams the Linux
  install script's step markers live to the console instead of
  buffering the whole 3–5 minute output into an array that only
  printed once the install finished. Previously the installer
  looked hung between "Installiere Pakete in der Template-Distro..."
  and the next `[OK]` line.
- `docs/README.de.md` now uses real umlauts (ä/ö/ü/ß) instead of
  the ASCII transliterations (ae/oe/ue/ss) that had crept in.

## [1.0.0] - 2026-04-12

First stable release.

agentbox runs sandboxed AI coding agents — Claude Code, OpenAI Codex,
Gemini CLI, Aider, Goose — inside an ephemeral WSL2 distro on Windows.
The 1.0 release locks in the persistence model, sandbox boundary, and
OneDrive-friendly project layout, with all known startup, auth, and
filesystem bugs from the 0.x line resolved end to end.

### Highlights

- Five agents supported out of the box, switchable per session
- Per-agent OAuth credentials persist across sessions
- Project files mounted live from the workspace — writes go straight
  back to the host (incl. OneDrive folders)
- Replay mode for running the same task with a different agent, plus
  cross-session diff
- Hard sandbox boundary: no `/mnt/c`, no host LAN, default-deny
  firewall (HTTPS out + project-type package sources only)
- Single-command install + auto-update via PowerShell

### Architecture Invariants (locked for 1.x)

- Sandbox isolation is hard: no `/mnt/c`, no host LAN, default-deny
  firewall, tmpfs overmount blocks DrvFs automount inside the sandbox
- Distro is freshly imported every session and unregistered on exit
  via a bash trap on `EXIT INT TERM HUP`
- Runtime state lives strictly under `%LOCALAPPDATA%\agentbox\`,
  never inside `_control/` (which typically sits in OneDrive):
  - `sandbox\template.tar.gz` + `sandbox\.config_hash`
  - `cache\npm\`, `cache\pip\`
  - `sessions\<id>\`
  - `auth\<agent>\`
  - `host-distro\`
- OAuth state in `~/.claude/.credentials.json`, persisted via direct
  `mount -t drvfs ... -o metadata,uid=<sandbox>,gid=<sandbox>,umask=077`
- PowerShell 5.1 compatibility for all installers (no here-strings,
  no `-Encoding utf8NoBOM`, CRLF/LF aware)
- Agent starts in `/workspace`

### Added (path to 1.0)

- Bash cleanup trap on `EXIT INT TERM HUP` that guarantees the
  ephemeral sandbox distro is terminated and unregistered on every
  exit path — including hard terminal close, `Ctrl+C`, watchdog OOM,
  and partial `wsl --import` failures (`ce67005`)
- Auto-restore of `~/.claude.json` from
  `~/.claude/backups/.claude.json.backup.<timestamp>` on sandbox
  start, so theme + UI settings persist across sessions (`b2b90a2`)
- Sandbox-init diagnostics: workspace write-test, auth mount-owner
  display, auth write-test as the sandbox user, `.credentials.json`
  state at session start and end, plus a `sync` before sandbox-init
  exits to flush DrvFs writes
- New helper `_wsl_distro_running` next to `_wsl_distro_exists`,
  used by the session-lock check
- New helper `_resolve_agentbox_local_root` resolving
  `%LOCALAPPDATA%` from inside WSL via `cmd.exe /c echo`

### Changed (path to 1.0)

- **Runtime state out of OneDrive.** Template, cache, sessions, and
  auth all moved from `$CONTROL_DIR/` into `%LOCALAPPDATA%\agentbox\`.
  The 1 GB template no longer hits cloud sync, Files-On-Demand
  placeholders no longer cause `wsl --import` to fail with
  ERROR_PATH_NOT_FOUND, and `_control/` keeps only versioned scripts
  and config (`fc4a7fa`)
- **Session-lock check distinguishes registered from running**, so a
  corpse from a partially-failed `wsl --import` falls through to the
  stale-cleanup path instead of deadlocking the next start (`52e5508`)
- **`/mnt` isolation uses tmpfs overmount** instead of `umount -f`
  followed by tmpfs. Linux covered-mount semantics keep the underlying
  DrvFs/9P channel intact (so bind-mounts in `/workspace` stay
  read-write), while the tmpfs cover makes `/mnt/c` unreachable from
  inside the sandbox namespace. Sandbox isolation is identical, DrvFs
  is no longer disturbed (`c404302`, supersedes the lazy-unmount
  attempt in `1b66ad1`)
- **Auth bind-mounts replaced with direct DrvFs mounts** carrying
  explicit `metadata,uid=$AGENT_UID,gid=$AGENT_GID,umask=077` —
  required because the parent `/mnt/c` is automounted without the
  `metadata` flag, so chown on a bind-mount silently no-ops and the
  sandbox user can't write into the auth directory (`96c2f56`)
- **Project bind-mounts use correct `remount,bind,rw,...` syntax**
  with explicit `bind` keyword and explicit `rw`. Without `bind`,
  Linux interprets `mount -o remount` as a remount of the underlying
  filesystem, which on DrvFs/9P quietly downgrades the bind to
  read-only — surfaces as `Read-only file system` on writes despite
  the `read-write` log line (`c404302`)

### Fixed (path to 1.0)

- `wsl --import` `ERROR_PATH_NOT_FOUND` on first run after a clean
  install: the parent of the import target (`%TEMP%\agentbox\`) is
  now created with `mkdir -p` before the import (`c2b679e`)
- `irm | iex` update gate skipped the layout migration because
  `.version` was not bumped, leaving `install.ps1` (freshly fetched,
  new layout) in split-brain with the local `_control\win-setup.ps1`
  (old layout). Adds a copy-fallback to the PowerShell migration so
  it survives OneDrive Files-On-Demand placeholders (`852978a`)
- I/O errors on `CLAUDE.md`, `project.json`, `src/`, `_tasks/` after
  the agent starts, caused by `umount -f` killing the DrvFs/9P
  channel that the project bind-mounts depended on (`1b66ad1`,
  fully overhauled by `c404302`)
- "Not logged in · Run /login" immediately after a successful
  OAuth flow, because Claude Code's `writeFileSync` to
  `~/.claude/.credentials.json` was hitting a root-owned bind-mount
  on metadata-less DrvFs and bouncing with EACCES (`96c2f56`)
- "Session laeuft bereits" on every start after the previous run
  ended via hard terminal close — distro stayed running because the
  cleanup at the bottom of `wsl-ai-start.sh` was never reached
  (`ce67005`)
- "Claude configuration file not found" warning flood (3x per start)
  and the welcome / theme prompt reappearing every session, due to
  `~/.claude.json` not being persisted across the ephemeral distro
  (`b2b90a2`)

### Removed

- `_control\sandbox\`, `_control\cache\`, `_control\sessions\` are
  no longer part of the layout. A one-shot migration in
  `wsl-ai-start.sh` and `win-setup-core.ps1` moves any leftover
  files into `%LOCALAPPDATA%\agentbox\` and removes the legacy
  directories. Safe to keep `_control/` itself in OneDrive — it
  now contains only versioned scripts/config

[1.0.0]: https://github.com/ChrisRudi/agentbox/releases/tag/v1.0.0
