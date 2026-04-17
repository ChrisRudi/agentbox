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
- [x] **1.3** README-Dateistruktur auf 2.0-Layout umschreiben (Befund H2). ✅ 2.0.3
  - `README.md` + `docs/README.de.md` → zwei getrennte Trees
    (versioniert vs. lokal), `%LOCALAPPDATA%\agentbox\` explizit
    aufgeführt mit `sandbox/template.vhdx` als primary.
  - Cache-Pfad-Passage im "What Persists"-Abschnitt angeglichen.

**Commit 1** (`minor`): alle drei Sub-Tasks zusammen oder einzeln.

---

## Etappe 2 — `--list-sessions` / `--compare` Regression-Fix (`minor`) ✅ 2.0.3

Ziel: Befund B + H3. Broken-Feature repariert.

Gewählter Ansatz (anders als im Ur-Plan): **Argparse bleibt vorne,
Execution wird deferred.** Das Hochziehen von `_resolve_agentbox_local_root`
haette CONTROL_DIR + `cfg_get` vorgezogen, und damit die Reihenfolge
`config.sh laden → base_path_override → CONTROL_DIR umsetzen`. Sauberer:
Argparse sammelt nur Flags, die beiden Modi laufen nach `SESSIONS_DIR`
und nach der `_migrate_from_control`-Schleife.

- [x] **2.1** Argparse-Loop entkoppelt: neues Flag `LIST_SESSIONS_MODE`;
  `--compare` setzt wie bisher `COMPARE_MODE=true` + `COMPARE_SESSIONS`.
- [x] **2.2** Deferred-Execution-Bloecke nach `mkdir -p
  $AGENTBOX_LOCAL_ROOT/sessions` eingefuegt; beide nutzen
  `$SESSIONS_DIR`.
- [ ] **2.3** Smoke-Test durch User (auf Host): `agentbox
  --list-sessions` + `--compare` gegen echten `%LOCALAPPDATA%`-State.
- [x] **2.4** CHANGELOG-Eintrag 2.0.3.

**Commit 2** = `minor`, siehe 2.0.3-Release.

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

## Etappe 4 — Agent-Liste konsolidieren (Befund C) (`minor`) ✅ 2.0.4

Ziel: Auth-Mount zieht Agent-Liste aus `config.json`, nicht mehr
hartcodiert. `wsl-sandbox-init.sh` hat kein eigenes Config-Parsing,
stattdessen Uebergabe via neuen 7. Parameter.

- [x] **4.1** `lib/config.sh`: `cfg_get_agents_all` gibt alle Agents
  mit `id:auth_dir` aus (Default `.<id>`, Goose-Ausnahme aus Config).
- [x] **4.2** `config.json` → `agent_goose_auth_dir: ".config/goose"`.
- [x] **4.3** `wsl-ai-start.sh`: baut `AGENTBOX_AUTH_SPEC` aus
  `cfg_get_agents_all`, legt AUTH_BASE-Unterordner an, uebergibt die
  Spec als `$7` an sandbox-init.
- [x] **4.3b** `wsl-sandbox-init.sh:305-` auf `AUTH_SPEC`-Iteration
  umgestellt; Legacy-Hardcode als Fallback wenn Spec leer.
- [ ] **4.4** Auto-Approve-Flag-Block (`wsl-sandbox-init.sh:~841`)
  analog Config-driven: **bewusst skipped**. Block enthaelt nur 2
  Eintraege (Gemini/Aider) und ist bewusst hartcoded fuer Injection-
  Safety. Config-Treiber kostet hier mehr als er einspart; Erhalt
  begruendet im bestehenden Code-Kommentar.
- [ ] **4.5** Smoke-Test durch User: Session mit `claude` (default
  auth_dir), Session mit `goose` (explizite Config). Wenn beide
  Auth-Persistenz zeigen, 4.5 gruen.
- [x] **4.6** CHANGELOG 2.0.4 + refactor.md Fortschritt.

**Commit 4** = 2.0.4. Template-Rebuild wird beim naechsten
`install.ps1`-Rerun einmalig ausgeloest, weil der neue Goose-Auth-Dir-
Key in den Config-Hash faellt — `template_schema` nicht extra gebumpt.

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
| 2026-04-17 | 1.3 + Etappe 2 | 2.0.3 | done (Smoke-Test User offen) |
| 2026-04-17 | Etappe 4 (Agent-Liste aus Config) | 2.0.4 | done (Smoke-Test User offen) |
| — | Etappe 3 (`lib/config.ps1`) | — | offen |
| — | Etappe 5 (Log-Refactor + Doku) | — | offen |
