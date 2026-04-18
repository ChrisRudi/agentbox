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

**Aufgeteilt in 5 Sub-Commits**, damit Regression pro Script revert-bar
bleibt. Die `3.3`-/`3.4`-Items aus dem Ur-Plan sind bewusst auf eigene
Sub-Steps verschoben.

### Teil A ✅ 2.0.7

- [x] **3.A.1** `lib/config.ps1` angelegt: `Read-AgentboxConfig`,
  `Invoke-Native`, `Write-AgentboxLog`. PS-5.1-kompatibel, keine
  Here-Strings, keine PS-6-only-Parameter. Additiv — keine Call-Site
  umgestellt.

### Teil B ✅ 2.0.9 — `install.ps1` opts-in (post-Clone)

- [x] **3.B.1** `install.ps1` sourced `lib/config.ps1` **post-clone**,
  mit `Get-Command Read-AgentboxConfig` als Idempotenz-Guard und
  `try/catch` um `. $lib`, damit eine defekte Lib den Installer nie
  blockiert.
- [x] **3.B.2** Config-Parse-Block bei Z.955 (`$installConfig` fuer
  `.wslconfig`) auf `Read-AgentboxConfig` mit Inline-Fallback.
- [ ] **3.B.3** Pre-Clone-Block bei Z.474 **nicht** migriert —
  lib/config.ps1 liegt zu dem Zeitpunkt strukturell noch nicht auf
  Disk (erst nach Repo-Clone). Bleibt als Inline-Muster bestehen.

### Teil C ✅ 2.0.10 — `win-setup-core.ps1` opts-in

- [x] **3.C.1** Config-Parse (Z.73-82) → `Read-AgentboxConfig` mit
  Test-Path-guarded Source + Inline-Fallback. Gleiche Struktur wie
  Teil B.
- [x] **3.C.2** `$ErrorActionPreference="Continue"` bleibt bewusst —
  Stop-Umstellung ist Teil E und braucht Invoke-Native-Wrap-
  Voraussetzungen, nicht in diesem Commit.

### Teil D (offen) — `win-task-runner.ps1` opts-in

- [ ] **3.D.1** Source + Config-Parse (Z.30-36) → `Read-AgentboxConfig`.
- [ ] **3.D.2** `Write-Log` durch Re-Export aus `Write-AgentboxLog`
  ersetzen (oder beibehalten — Entscheidung je nach Call-Sites).
- [ ] **3.D.3** Native-Calls Z.252-265 in `Invoke-Native` wrappen
  (latenter Crash-Fix, Teil des Original-Plans Punkt 3.4).

### Teil E (offen, sensibel) — `$ErrorActionPreference='Stop'`

- [ ] **3.E.1** `win-setup-core.ps1:7` + alle Native-Calls dort in
  `Invoke-Native` wrappen. **Nur nach** Teil C gruen ist. Hoechstes
  Regressions-Risiko der Etappe.

**Freigabe fuer naechste Teil:** nach User-Smoke-Test des aktuellen
Teils auf Windows-Host (`install.ps1` clean + `install.ps1` update).

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

Ziel: Befund F, H. Niedrige Prio. Bewusst in Teil 1 + Teil 2 gesplittet.

### Teil 1 ✅ 2.0.5

- [x] **5.1** `lib/log.sh` angelegt mit `log_info`/`log_ok`/`log_warn`/
  `log_error` + Farb-Vars. Aus `wsl-ai-start.sh:344-347` extrahiert.
- [x] **5.2a** `wsl-ai-start.sh` sourced `lib/log.sh`. Inline-
  Definitionen bleiben als Fallback fuer Pre-2.0.5-Upgrades.
- [x] **5.3** `CLAUDE.md` → neue Section „Config-Topologie"
  (`config.json` vs. `type_defaults.json`, `lib/config.sh` als
  kanonische Lese-Schnittstelle).

### Teil 2 ✅ 2.0.6

- [x] **5.2b** `wsl-sandbox-init.sh` → 34 `echo "[LEVEL] ..."`-Zeilen
  auf `log_ok`/`log_info`/`log_warn`/`log_error` umgestellt.
  Entscheidung: `log_*`-Funktionen **inline** am Scriptanfang
  (identisch zu `lib/log.sh`), weil `_control/` bewusst nicht in die
  Sandbox gemounted wird. Kleine Duplikation mit `lib/log.sh`
  akzeptiert — keine neue Mount-Route nur fuer Logging.

### Teil 3 (offen, Folge-Ticket)

- [ ] **5.4** Stderr-Split fuer WARN/ERROR — semantisch sauberer,
  aber potenziell pipe-breaking fuer bestehende User-Scripts. Separate
  Etappe, damit Revert trivial bleibt.

**Commit 5 Teil 1** = 2.0.5. **Commit 5 Teil 2** = 2.0.6.

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
| 2026-04-17 | Etappe 5 Teil 1 (`lib/log.sh` + Config-Topologie-Doku) | 2.0.5 | done |
| 2026-04-17 | Etappe 5 Teil 2 (sandbox-init [OK]-Replace) | 2.0.6 | done |
| 2026-04-17 | Etappe 3 Teil A (lib/config.ps1 additiv) | 2.0.7 | done |
| 2026-04-17 | 2.0.4-Hotfix (Bug-1+2 aus Etappe 4) | 2.0.8 | done |
| 2026-04-17 | Etappe 3 Teil B (install.ps1 post-Clone) | 2.0.9 | done (Host-Test OK) |
| 2026-04-17 | Etappe 3 Teil C (win-setup-core.ps1) | 2.0.10 | done (Smoke-Test User offen) |
| — | Etappe 3 Teil C (win-setup-core.ps1 opts-in) | — | offen |
| — | Etappe 3 Teil D (win-task-runner.ps1 opts-in) | — | offen |
| — | Etappe 3 Teil E (Stop-Mode + Invoke-Native-Wrap) | — | offen (hoch-risk) |
| — | Etappe 5 Teil 3 (Stderr-Split) | — | offen (Follow-up) |
