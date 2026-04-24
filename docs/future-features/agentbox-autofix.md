# agentbox-autofix — Design-Doc (Entwurf)

**Status:** Entwurf zur Pruefung, Iteration 2 (nach User-Review). Noch nicht
implementiert.
**Scope:** Automatisierter Code-Haertungs-Flow auf Basis der bestehenden
agentbox-Sandbox. Ein Befehl, mehrere Reviewer-Agenten, ein Fix-Agent mit
Confidence-Scoring, Runner-Gate mit Qualitaetsleveln, Secret-Scan,
Export des reparierten Standes.

---

## 1. Ziel

Ein Projektordner wird per Single-Command in eine agentbox-Sandbox geschoben.
Dort analysieren mehrere AI-Reviewer parallel, ein FixAgent entscheidet und
repariert, ein Runner validiert, und nur ein bestandener Fix wird als separater
Ordner (oder Patch) an den User exportiert. Das Original bleibt immer unberuehrt.

Erfolgsmetrik: User startet den Command, geht Kaffee holen, findet entweder
einen sauberen `_fixed`-Ordner + Diff, oder ein klares "FAIL, nichts geaendert".

---

## 2. User-Flow (Soll)

```text
1. Projekt waehlen       C:\...\AI_Projects_Source\MeinProjekt
2. Autopilot starten     agentbox-autofix MeinProjekt
3. Warten                (keine Interaktion)
4. Ergebnis lesen        Status: OK | FAIL + Zusammenfassung
5. Uebernahme            %LOCALAPPDATA%\agentbox\autofix\MeinProjekt\<ts>\
6. Rollback              Original ist unveraendert, Ergebnis loeschen reicht
```

---

## 3. Architektur-Ueberblick

```text
Reviewer (parallel)  ->  FixAgent  ->  Runner  ->  Decision  ->  Export | Discard
  Codex, Claude          (arbitriert         (build +         (Gate)
  (plug-bar)              + patcht)          test + lint)
```

Eingabe: bind-mount des Projektordners nach `/workspace/src`.
Arbeitsort: derselbe Pfad, aber git-versioniert innerhalb der Sandbox (siehe 4.1).
Ausgabe: Export-Ordner **oder** Patch-Serie ausserhalb `_control/`.

---

## 4. Design-Entscheidungen

### 4.1 Git im Sandbox (MUSS)

Im Konzept stand "ohne Git". Das ist die groesste Schwachstelle. Fix:

- Bei Sandbox-Start: `git init` im Sandbox-Arbeitskopie-Pfad (nicht im
  Original-Bind-Mount — siehe 4.2), initialer Commit "baseline".
- FixAgent committet pro logischem Fix einen Commit mit Trailer
  `AutoFix-Finding: <id>` + `AutoFix-Reviewer: codex|claude`.
- Export erzeugt zusaetzlich eine `changes.patch` via `git format-patch`
  und eine `run.json` mit Finding-zu-Commit-Mapping.
- Original bleibt ohne Git-Eingriff.

Begruendung: Diff-Review, Audit-Trail, Rollback-Granularitaet, saubere
Arbitrierungs-Spuren. Kosten: 1 zusaetzlicher `git`-Install im Template
(ist sowieso drin).

### 4.2 Kopie statt In-Place

Nicht direkt in `/workspace/src` (bind-mount ins Original) schreiben, sondern:

- Bind-Mount des Originals read-only nach `/workspace/_src-ro/`.
- `rsync -a` einmalig nach `/workspace/src/` (rw, ext4-Overlay-faehig) mit
  aggressiven Excludes fuer genau die Pfade, die eh ueber ext4-Overlays
  neu entstehen bzw. bei Sandbox-Start reproduziert werden:
  `--exclude=.git --exclude=node_modules --exclude=.next --exclude=dist
  --exclude=build --exclude=out --exclude=target --exclude=__pycache__
  --exclude=.pytest_cache --exclude=.mypy_cache --exclude=.ruff_cache`.
- FixAgent arbeitet nur in `/workspace/src/`.

Begruendung: selbst bei Bug im Autopilot wird das Original nie beruehrt.
Kosten: einmaliger Copy beim Start — durch die Excludes faellt gerade bei
grossen Node-/Python-Projekten der 90%-Anteil weg.

**Bewusst NICHT:** Hardlinks via `rsync --link-dest` (funktioniert nicht
cross-FS DrvFs->ext4), OverlayFS als Basis-Copy-on-Write (auf DrvFs
unsupported, bricht uns die OneDrive-Kompatibilitaet).

### 4.3 Namensraum im Workspace

Kollision vermeiden mit bestehendem `tools/` (Benchmark-Demo, siehe CLAUDE.md).
Autofix-Artefakte landen unter:

```text
/workspace/
  _src-ro/      <- read-only Original
  src/          <- arbeitskopie (git init, ext4-overlays wie heute)
  .autofix/
    findings/   <- JSON pro Reviewer
    state/      <- run.json, decisions.json
    logs/       <- reviewer-<slug>.log, runner.log
```

Kein `/workspace/tools/` in dieser Feature-Flaeche.

### 4.4 Export-Ziel

Layout-Vertrag aus CLAUDE.md erweitern (analog `sessions/`, `auth/`):

```text
%LOCALAPPDATA%\agentbox\autofix\<projekt>\<yyyyMMdd-HHmmss>\
  fixed\            <- kompletter Snapshot von /workspace/src
  changes.patch     <- git format-patch baseline..HEAD
  run.json          <- audit
  README.txt        <- kurzanleitung, wie User es uebernimmt
```

Ausserhalb `_control/` (OneDrive-Regel). Neues Top-Level unter `agentbox\`.

### 4.5 Guardrails gegen "Refactoring-Drift"

"Nur kleine Aenderungen" ist als Prompt-Regel nicht durchsetzbar. Stattdessen
mechanische Gatekeeper nach jedem FixAgent-Commit:

- **Zeilen-Delta-Limit** pro Commit (z.B. default 50 added + removed).
- **File-Count-Limit** pro Commit (z.B. default 3).
- **Gesamt-Limit** pro Run (z.B. 500 Zeilen, 20 Files).
- **Blockliste** fuer massenhafte Umbenennungen (z.B. >10 files mit
  demselben rename-Delta) — heuristisch, configurable.

Bei Verletzung: Commit wird revertiert, Finding als "too invasive, skipped"
markiert. Limits per `config.json` ueberschreibbar.

#### 4.5.1 Fix-Typ-Klassifikation

Jedes Finding wird von seinem Reviewer mit einem `type` versehen:

- `bugfix` — Fehlverhalten reparieren
- `security` — Security-Issue
- `style` — Lint/Format
- `refactor` — Umstrukturierung ohne Verhaltensaenderung

FixAgent akzeptiert per Default nur `bugfix`, `security`, `style`.
`refactor` ist **default-blocked** und nur via `--allow-refactor` Opt-in
aktivierbar. Fehlt der `type`, wird das Finding als `refactor` behandelt
(Default-deny, keine Guesswork).

### 4.6 Runner als Gate, nicht als Orakel

- Runner laeuft **strikt** ueber bestehende Task-Runner-Whitelist
  (`build_whitelist` in `config.json` + `win-task-runner.ps1`).
- Kein neuer Exec-Pfad, keine parallele Security-Oberflaeche.
- Runner-Output flieszt zurueck zum FixAgent (Retry-Loop, siehe 4.7).

**Qualitaets-Level** (ersetzt das fruehere "eines von"-Kriterium):

| Level | Bedingung                     | Final-Decision          |
|-------|-------------------------------|-------------------------|
| 0     | Kein Build, keine Tests, kein Lint erkannt | **FAIL** (kein Export) |
| 1     | Nur Build ok                  | **WARN** (Export nur mit `--accept-warn`) |
| 2     | Build + Lint ok               | **OK**                  |
| 3     | Build + Lint + Tests ok       | **STRONG OK**           |

Stufenbestimmung vor dem Run (nicht waehrend): Runner prueft, was der
Projekt-Type ueberhaupt liefern kann (`project.json`/Heuristik), und legt
das Level-Ziel fest. Fehlen Tests, wird Level 3 nie erreichbar — wird im
`run.json` als `max_achievable_level: 2` hart gekennzeichnet, damit der User
das Ergebnis nicht ueberinterpretiert.

### 4.7 Bounded Retry-Loop mit Frozen-Findings

One-Shot ist zu wenig. Iterationen duerfen aber **keine frueheren erfolgreichen
Fixes ueberschreiben** — sonst oszilliert das System.

```text
frozen = {}   # Finding-IDs, die bereits committed + runner-OK sind
for i in 1..N (default 3):
  candidates = open_findings - frozen
  if candidates leer: break
  FixAgent wendet batch aus candidates an
  Runner laeuft
  if Runner OK:
    frozen += angewandte Findings dieser Iteration
    if alle Findings erledigt: break (Full Success)
  else:
    letzte Iteration rollback (git reset auf letzten frozen-Stand),
    FixAgent bekommt Runner-Output als Feedback fuer naechste Iteration,
    frozen bleibt unveraendert erhalten
if kein break mit vollem Success:
  wenn frozen nicht leer -> Export der frozen-Teilmenge (Partial Success)
  sonst -> FAIL + attempted.patch
```

Regel: Einmal `frozen`, nie mehr angefasst. FixAgent-Prompt bekommt explizit
eine Liste "diese Dateien/Ranges sind eingefroren, nicht modifizieren".

Max-Iterationen, Max-Tokens, Max-Wallclock jeweils configurable.

### 4.8 Reviewer-Arbitrierung, Confidence, Determinismus

Codex und Claude werden widerspruechliche Findings liefern. Regeln:

- Jedes Finding hat `{id, type, severity, file, range, description,
  suggestion?, reviewer}`.
- **Confidence-Score** pro Finding (0.0–1.0):
  - Start: `severity_weight` (low=0.2 / medium=0.5 / high=0.8 / critical=1.0)
  - **+0.3** Consensus-Bonus pro zusaetzlichem Reviewer, der dasselbe
    Finding (gleiche Datei, ueberlappender Range, kompatibler Type) gemeldet hat.
  - **−0.2** bei widerspruechlichen Suggestions auf gleicher Range.
  - Cap bei 1.0, Floor bei 0.0.
- **Apply-Schwelle** (default `confidence >= 0.5`), per Config
  ueberschreibbar. Voting wirkt hier als Confidence-Modifier, **nicht** als
  Hard-Gate — ein Single-Reviewer-Finding mit `critical` severity kommt
  auch ohne zweiten Reviewer durch.
- **Konflikt-Erkennung**: zwei Findings auf demselben Range mit
  widerspruechlichen Suggestions → FixAgent waehlt den hoeheren
  Confidence-Score, begruendet die Wahl in der Commit-Message, das unterlegene
  Finding wandert als `skipped: conflict_with_<id>` ins Audit.

**Deterministische Sort-Order** (gleiche Findings → gleiche Apply-Reihenfolge):

1. `confidence` absteigend
2. `severity_weight` absteigend
3. `type` Reihenfolge: `security, bugfix, style, refactor`
4. `file` lexikografisch aufsteigend
5. `range.start_line` aufsteigend
6. `reviewer` lexikografisch (tiebreaker)
7. `id` lexikografisch (endgueltiger tiebreaker)

LLM-Output bleibt nicht-deterministisch, aber **Auswahl und Reihenfolge
der angewandten Fixes** sind es, gegeben dieselben Findings.

### 4.9 Parallelitaet der Reviewer

- Reviewer laufen seriell **pro Sandbox**, aber in separaten Arbeits-
  Branches auf dem gleichen Worktree (nur Leseanalyse, keine Schreibvorgaenge).
  Jeder Reviewer schreibt nur sein Finding-JSON unter `.autofix/findings/<slug>.json`.
- Rate-Limits, Auth-State-Kollisionen und Log-Interleaving werden dadurch
  vermieden.
- Auth-State je Agent wie heute unter `%LOCALAPPDATA%\agentbox\auth\<agent>\`.

### 4.10 Abbruch / UX / Modi

- `Ctrl+C` im aufrufenden Terminal -> Sandbox wird sauber via
  `wsl --terminate` abgeraeumt, kein Partial-Export.
- Session-Timeout (default 30 min) hart.

**Modi** (CLI-Flags / Config-Presets):

- `--dry-run`: Reviewer + FixAgent-Planung, nur `planned-changes.patch`,
  kein apply+runner.
- `--safe`: Safe-Mode-Preset. Nur Fix-Typen aus enger Allowlist:
  `null-check`, `import-sort`, `unused-var`, `syntax-error`,
  `obvious-typo`. Das sind Sub-Types von `bugfix`/`style` (Reviewer muss
  diese explizit setzen). Alles andere -> skipped.
- `--explain`: erzeugt zusaetzlich `report.md` mit pro Fix: Reviewer-
  Zitat, Commit-SHA, Confidence-Score, Diff-Snippet, Risikonote aus der
  FixAgent-Begruendung. Fuer User, die **jeden** Fix manuell nachvollziehen
  wollen bevor sie uebernehmen.
- Flags kombinierbar (`--safe --explain`).

### 4.11 Pre-Export Secret-Scan (MUSS, nicht Optional)

Vor Schreiben des Export-Ordners:

- Scan der **Arbeitskopie** (`/workspace/src/`) und der Commit-History
  (`git log -p baseline..HEAD`) gegen:
  - common Secret-Patterns (AWS-Keys, GitHub/GitLab-Tokens, private Keys,
    JWT-Header-Signaturen, generische `API_KEY=...`/`SECRET=...`)
  - explizite Pfade: `.env`, `.env.*`, `*.pem`, `*.key`, `id_rsa*`,
    `credentials.json`, `.aws/credentials`
- Library: `gitleaks` oder `trufflehog` (eines davon ins Template, kein
  Reinventing).
- Treffer in **Arbeitskopie allein** (war schon im Original): Warnung im
  Report, Export laeuft durch.
- Treffer in **Diff** (FixAgent hat Secret eingefuegt oder unmasked):
  **Export-Hard-Block**. `run.json` markiert Status `fail_secret_leak`,
  Sandbox wird trotzdem cleanup, kein Partial-Export.

Template-Install: `gitleaks` via apt/release-binary im
`win-setup-core.ps1`-Agent-Install-Block. `template_schema`-Bump
noetig (auf `4`).

---

## 5. Config

Neue Sektion in `config.json`:

```jsonc
{
  "autofix": {
    "reviewers": ["claude", "codex"],
    "fix_agent": "claude",
    "runner": {
      "use_task_runner_whitelist": true,
      "min_level": 2                // 0=fail, 1=warn, 2=ok, 3=strong-ok
    },
    "limits": {
      "max_iterations": 3,
      "max_lines_per_commit": 50,
      "max_files_per_commit": 3,
      "max_lines_total": 500,
      "max_files_total": 20,
      "session_timeout_min": 30
    },
    "confidence_threshold": 0.5,
    "allowed_types": ["bugfix", "security", "style"],  // refactor default off
    "secret_scan": {
      "tool": "gitleaks",
      "block_on_diff_hit": true
    },
    "export_root": "%LOCALAPPDATA%/agentbox/autofix"
  }
}
```

- `cfg_get`/`cfg_get_array` in `lib/config.sh` erhalten wo noetig neue Wrapper,
  nie ad-hoc jq-Parsing an Callsites.
- `Get-AgentboxConfigHash` in `win-setup-core.ps1`: `autofix.*`-Keys muessen
  **nicht** in den Template-Hash — Autofix-Config aendert nicht das Template,
  sondern Session-Verhalten. Explizit dokumentieren, damit niemand das
  versehentlich in den Hash-Block aufnimmt.

---

## 6. Audit-Output (`run.json`)

```jsonc
{
  "project": "MeinProjekt",
  "started_at": "2026-04-24T10:15:00Z",
  "finished_at": "2026-04-24T10:23:41Z",
  "status": "ok",
  "reviewers": [
    { "name": "claude", "findings": 5, "duration_s": 42 },
    { "name": "codex",  "findings": 6, "duration_s": 38 }
  ],
  "findings_total": 7,
  "findings_applied": 4,
  "findings_skipped": [
    { "id": "F-03", "reason": "too_invasive: 120 lines > 50 limit" },
    { "id": "F-06", "reason": "runner_failed_after_apply" },
    { "id": "F-07", "reason": "conflict_with_F-02" }
  ],
  "commits": [
    { "sha": "ab12cd3", "finding_ids": ["F-01"], "lines": "+4 -2" }
  ],
  "runner": {
    "iterations": 2,
    "final": { "build": "pass", "tests": "pass", "lint": "pass" }
  },
  "export": {
    "path": ".../agentbox/autofix/MeinProjekt/20260424-101500/",
    "patch": "changes.patch"
  }
}
```

---

## 7. Open Questions / Bewusst offen

- **Multi-File-Atomaritaet**: heute geloest durch "ein Commit pro Fix, Revert
  bei Runner-Fail". Reicht wahrscheinlich.
- **Cost-Budget**: Token-Limit pro Run (Fix + Reviewer). Default diskutieren.
- **Reviewer-Plug-in-Schnittstelle**: fuers MVP Claude + Codex fix. Spaeter
  Gemini/Aider/Goose analog zum bestehenden Agent-Install-System.
- **Update-Class**: Feature fuegt Scripts + Config-Keys zu, ausserdem
  `gitleaks` ins Template. **`minor`** reicht, weil existierende User beim
  naechsten Update den Template-Rebuild via `template_schema=4`-Bump
  automatisch bekommen — kein `install.ps1`-Rerun als Admin noetig.

---

## 8. Abgrenzung — explizit NICHT Teil dieses Features

- **In-Place-Modifikation des Originals**: nie. Immer nur Export.
- **Auto-Merge ins Original**: nie automatisch. User uebernimmt manuell.
- **Git-Commit/Push des Originals**: nicht automatisiert. Autofix liefert
  einen Patch, User entscheidet ueber sein eigenes VCS.
- **Scheduled/Recurring-Runs**: Autofix ist explizit on-demand. Kein Cron,
  kein Watch-Mode im ersten Wurf.
- **Cross-Projekt-Refactorings**: ein Projekt pro Run.

---

## 9. Naechste Schritte (wenn dieses Doc abgenommen ist)

1. `config.json` um `autofix`-Sektion erweitern + `lib/config.sh`-Wrapper.
2. Neuer Bash-Entry `wsl-autofix.sh` analog `wsl-ai-start.sh`.
3. Powershell-Entry `agentbox-autofix.ps1` (Installer registriert als Shim
   unter `agentbox-autofix.cmd` im PATH, analog `agentbox`).
4. Reviewer-/FixAgent-/Runner-Orchestrierung als `lib/autofix/*.sh`.
5. Export-Schreiber mit Layout-Contract aus 4.4.
6. Integration-Test im Benchmark-Demo-Projekt (`tools/` -> `demo-benchmark/`)
   mit absichtlich eingebautem trivialem Bug als Smoke-Test.
7. CHANGELOG-Eintrag, `.update_class=minor`, ggf. `template_schema=4`
   wenn neue apt-Pakete noetig (z.B. `git` ist schon drin — vermutlich kein
   Bump noetig).
