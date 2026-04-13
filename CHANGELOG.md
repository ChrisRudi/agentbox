# Changelog

All notable changes to agentbox are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
