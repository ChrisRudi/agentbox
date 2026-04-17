# refactor.md — Architektur-Aufräumen agentbox

**Status:** aktiv, session-übergreifend. Diese Datei wird in mehreren
Claude-Sessions abgearbeitet. Jede Session nimmt sich genau **eine
Etappe** (oder eine Sub-Etappe) vor, committet und pusht, und markiert
hier das Häkchen. **Installer muss nach jeder Etappe weiter grün
durchlaufen** — vor jedem Push: `install.ps1` in einer sauberen
Windows-VM testen oder zumindest Syntax/Logik lokal reviewen. Bei
Zweifeln lieber die Etappe splitten.

## Grundregeln

- Commit-Ziel: **main** (siehe CLAUDE.md-Git-Workflow).
- Vor jedem Commit: `.update_class` bewusst setzen (siehe CLAUDE.md §
  Release-Prozess).
- Bei Änderungen am Template-Build (apt-Pakete, neue sysctls, geänderte
  Install-Kommandos in `win-setup-core.ps1`): `template_schema` in
  `win-setup-core.ps1 → Get-AgentboxConfigHash` bumpen.
- Keine PRs erstellen, wenn nicht explizit vom User gewollt.
- Nach jeder Etappe **hier** den Status updaten + CHANGELOG.md-Eintrag.

---

## Etappe 1 — Schnelle User-facing Fixes (`minor`)

Ziel: alle User-visible Drifts raus, die keinen Code-Refactor brauchen.
Keine Risiken am Installer-Pfad.

- [x] **1.1** `.update_class` auf `minor` setzen (Befund A). ✅ 2.0.2
- [x] **1.2** Gemini-Install konsolidieren (Befund H1). ✅ 2.0.2
  - Kanonische Quelle: `config.json`
    (`npm install -g @google/gemini-cli@latest`).
  - `win-setup-core.ps1:473` Fallback von `pip3 install
    google-gemini-cli` auf `npm install -g @google/gemini-cli@latest`.
  - README-Tabelle (`README.md:49` + `docs/README.de.md:49`) auf
    **npm**.
  - `template_schema` **nicht** gebumpt — der tatsächliche Install-
    Command aus `config.json` ändert sich nicht, nur der Fallback.
    Config-Hash damit identisch, kein erzwungener Rebuild.
- [ ] **1.3** README-Dateistruktur auf 2.0-Layout umschreiben (Befund H2).
  - `README.md:378-404` — File-Tree-Block: `_control/sandbox/` und
    `_control/cache/` und `_control/sessions/` entfernen; separaten
    `%LOCALAPPDATA%\agentbox\`-Block ergänzen mit
    `sandbox/template.vhdx`, `cache/{npm,pip}`, `sessions/`, `auth/<agent>/`.
  - `README.md:275` Cache-Pfade auf `%LOCALAPPDATA%\agentbox\cache\…`
    korrigieren.
  - `docs/README.de.md` analog.

**Commit 1** (`minor`): alle drei Sub-Tasks zusammen oder einzeln.

---

## Etappe 2 — `--list-sessions` / `--compare` Regression-Fix (`minor`)

Ziel: Befund B + H3. Broken-Feature reparieren.

- [ ] **2.1** `_resolve_agentbox_local_root` + `SESSIONS_DIR`-Ableitung
  aus `wsl-ai-start.sh` so refaktorieren, dass sie **vor** dem
  Argparse-Loop laufen. Konkret: Block Z.206-279 vor den `while`-Loop
  Z.15 ziehen. Die Migration (`_migrate_from_control`) darf da bleiben
  wo sie ist — sie kollidiert nicht mit dem Argparse.
- [ ] **2.2** In `--list-sessions`-Handler (Z.31) und `--compare`-Modus
  (Z.73) das hartcodierte `_control/sessions` durch `$SESSIONS_DIR`
  ersetzen.
- [ ] **2.3** Smoke-Test (manuell durch User auf Host):
  - `agentbox --list-sessions` zeigt die Sessions unter
    `%LOCALAPPDATA%\agentbox\sessions\`.
  - `agentbox --compare <a> <b>` öffnet den Diff.
- [ ] **2.4** CHANGELOG-Eintrag.

**Commit 2** (`minor`).

---

## Etappe 3 — Zentrale PS-Library (`lib/config.ps1`) (`minor`)

Ziel: Befund D + E. Config-Parse + `Invoke-Native` + Log-Helper an einer
Stelle. Keine Verhaltensänderung — reiner Refactor.

- [ ] **3.1** Neue Datei `lib/config.ps1` anlegen mit:
  - `Read-AgentboxConfig` (`Get-Content -LiteralPath ... -Raw |
    ConvertFrom-Json`, try/catch, Default-Rückgabe bei Fehler).
  - `Invoke-Native` (aus `install.ps1:27` extrahieren, minimal invasiv).
  - `Write-AgentboxLog` (Wrapper mit Zeitstempel + Level).
  - PS-5.1-kompatibel, `-LiteralPath`-safe wo möglich, nie
    `New-Item -LiteralPath`.
- [ ] **3.2** `install.ps1` (~Z.474), `win-setup-core.ps1` (~Z.78),
  `win-task-runner.ps1` (~Z.32) auf die gemeinsame Library umstellen
  via `. "$PSScriptRoot\lib\config.ps1"`.
- [ ] **3.3** `win-setup-core.ps1:7` von `"Continue"` auf `"Stop"`
  umstellen — nur **nachdem** die `Invoke-Native`-Wrapper überall dort
  stehen, wo native Tools aufgerufen werden (wsl.exe, git.exe,
  powershell.exe, winget.exe). **Vorsicht:** das ist die Etappe mit dem
  höchsten Regressions-Risiko am Installer. Vor Commit: zeile-für-zeile
  alle nativen Calls im Script identifizieren und wrappen.
- [ ] **3.4** `win-task-runner.ps1:252-265` Native-Calls in
  `Invoke-Native` einhüllen (latenter Crash-Fix).
- [ ] **3.5** Smoke-Test durch User: `install.ps1` auf Clean-VM +
  `install.ps1`-Update-Pfad auf vorhandener Installation.
- [ ] **3.6** CHANGELOG-Eintrag.

**Commit 3** (`minor`; nur `major` setzen falls Installer-Testlauf
zeigt, dass Template-Rebuild erzwungen werden muss — normalerweise
greift `template_schema` dafür, bumpen auf `5` wenn Build-Verhalten
betroffen).

---

## Etappe 4 — Agent-Liste konsolidieren (Befund C) (`minor`)

Ziel: `wsl-sandbox-init.sh` nutzt `lib/config.sh` für Auth-Mount und
Auto-Approve statt hartcodierte Listen.

- [ ] **4.1** `lib/config.sh` um `cfg_get_agents_all` erweitern (gibt
  **alle** Agents, enabled + disabled, mit Auth-Dir-Default aus).
- [ ] **4.2** Neuen Config-Key pro Agent einführen:
  `agent_<id>_auth_dir` (Default-Konvention: `.<id>`, Goose-Ausnahme
  `.config/goose` → als explizite Config gesetzt).
- [ ] **4.3** `wsl-sandbox-init.sh:306-312` auf `cfg_get_agents`-
  Iteration umstellen, `_auth_mount_agent` aus dem Loop rausrufen.
- [ ] **4.4** Auto-Approve-Flag-Block (~Z.841) analog auf Config
  umziehen: neuer Key `agent_<id>_auto_approve_flag`, Default leer.
  Aider/Gemini bekommen ihren bestehenden Flag als Config-Default.
- [ ] **4.5** Smoke-Test: je eine Session mit zwei Agents (`claude`
  und `goose` — extreme Ends der Auth-Dir-Konvention).
- [ ] **4.6** CHANGELOG-Eintrag.

**Commit 4** (`minor`).

---

## Etappe 5 — Kosmetik / Doku (`minor`)

Ziel: Befund F, H. Niedrige Prio.

- [ ] **5.1** `lib/log.sh` anlegen mit `log_info`/`log_ok`/`log_warn`/
  `log_error`. Aus `wsl-ai-start.sh:344-347` extrahieren.
- [ ] **5.2** `wsl-sandbox-init.sh` + `lib/config.sh` sourcen
  `lib/log.sh`, alle `echo "[OK] ..."` durch `log_ok "..."` ersetzen.
  (Große Textänderung — kann in eigener Etappe sein.)
- [ ] **5.3** `CLAUDE.md` um kurzen Abschnitt „Config-Topologie" ergänzen:
  `config.json` = System/Agents/Resources, `type_defaults.json` =
  Project-Type-Defaults. Verweis auf beide Dateien.
- [ ] **5.4** CHANGELOG-Eintrag.

**Commit 5** (`minor`).

---

## Nicht-Ziele (bewusst draußen)

- **Firewall-Regeln config-driven machen (Befund G).** Die
  Hartcodierung ist Sicherheits-Design, nicht Bug (CHANGELOG 1.0.23).
  Nur dokumentieren.
- **`_control/` reorganisieren oder umbenennen.** Der Ordner ist
  versioniert + in OneDrive, ein Rename bricht bestehende Installationen
  silent. Außerhalb des Scopes.
- **Alpine-Distro, Multi-Project-VHD-Pool.** Separate Roadmap
  (`docs/future-features/agentbox-2.0-architecture.md`).

---

## Fortschritts-Log

| Datum | Etappe | Commit | Status |
|-------|--------|--------|--------|
| 2026-04-17 | 1.1 + 1.2 | 2.0.2 | done |
| — | 1.3 (README-Layout-Tree) | — | offen |
| — | Etappe 2 (`--list-sessions`-Fix) | — | offen |
| — | Etappe 3 (`lib/config.ps1`) | — | offen |
| — | Etappe 4 (Agent-Liste aus Config) | — | offen |
| — | Etappe 5 (Log-Refactor + Doku) | — | offen |
