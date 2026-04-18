# refactor.md — Architektur-Aufraeum-Philosophie

**Status:** abgeschlossen am 2026-04-17 mit Release **2.0.12**.
Details zu den einzelnen Etappen: siehe `CHANGELOG.md`.

Dieses Dokument bleibt erhalten als Sammlung der Prinzipien, die
fuer den Refactor gegolten haben — damit ein spaeterer Refactor
auf derselben Baseline aufsetzen kann.

---

## Grundregeln fuer agentbox-Refactors

- **Commit-Ziel: `main`.** Keine Feature-Branches, auch nicht wenn
  der Session-Wrapper einen vorgibt. Siehe `CLAUDE.md`
  § Git-Workflow.
- **Installer muss nach jeder Etappe gruen bleiben.** Das ist die
  harte Invariante. Im Zweifel Etappe splitten oder Smoke-Test
  durch den User einfordern, bevor die naechste gestapelt wird.
- **Kosten/Nutzen vor jeder Etappe.** Wenn der Umbau viele
  kritische Call-Sites anfasst, aber nur kosmetische Konsistenz
  bringt, ist „skip + dokumentieren" die richtige Antwort (siehe
  Etappe 3 Teil E).
- **Minor-Release mit Fallback-Pfad.** Neue gemeinsame Helper
  (`lib/log.sh`, `lib/config.ps1`) werden per Test-Path +
  try/catch gesourced; die alte Inline-Logik bleibt als
  `else`-Branch erhalten, bis ein komplettes Release-Intervall
  ohne Regressions-Reports vergangen ist. So ist jeder Sub-Commit
  revert-bar, ohne dass User-Scripts brechen.
- **`.update_class` bewusst setzen.** Default `minor`. Nur `major`
  wenn `install.ps1`-Rerun als Admin strukturell zwingend ist
  (neue WSL-Features, neue Enable-WindowsOptionalFeature-Calls,
  Template-Rebuild-Struktur-Aenderung). Template-Rebuild allein
  triggert `minor` + ggf. `template_schema`-Bump.
- **`template_schema` bumpen** wenn sich am Template-Build etwas
  aendert, das einen Rebuild erzwingen muss, ohne dass sich
  `config.json` aendert.
- **Doku updaten im selben Commit** — CHANGELOG + `refactor.md`
  (solange das lief) + CLAUDE.md fuer dauerhafte Invarianten.
  Zwischen „weiss noch" und „wissen alle" liegen 24 Stunden und
  eine Autocompact.
- **Keine PRs ohne expliziten User-Auftrag.**

## Bewusst nicht gemacht

Fuer Nachfolge-Refactors hilfreich zu wissen, was absichtlich nicht
angefasst wurde:

- **Firewall-Regeln config-driven machen.** Die Hartcodierung in
  `wsl-sandbox-init.sh` ist Sicherheits-Design (CHANGELOG 1.0.23),
  nicht Drift.
- **`_control/` reorganisieren oder umbenennen.** Versioniert,
  in OneDrive, wuerde bestehende Installationen silent brechen.
- **Stop-Mode + breiter `Invoke-Native`-Wrap in
  `win-setup-core.ps1`** (Etappe 3 Teil E). 19 kritische
  `wsl.exe`-Calls, hohe Kosten, null funktionaler Gewinn — der
  urspruenglich vermutete „latente Crash" in
  `win-task-runner.ps1` erwies sich in Teil D als Fehldiagnose
  (`Start-Process -PassThru`, kein Stderr-Routing-Risiko).
- **Multi-Projekt-VHD-Pool / Dev-Drive-Detection / Alpine-Distro**
  — separate Roadmap unter `docs/future-features/`.

## Offene Follow-ups

- **Stderr-Split fuer `log_warn`/`log_error`.** In `lib/log.sh`
  und im Inline-Copy in `wsl-sandbox-init.sh` schreiben WARN und
  ERROR heute auf stdout — semantisch sauberer waere stderr, aber
  potenziell pipe-breaking fuer User-Scripts, die das Output in
  Logfiles umleiten. Separate Etappe mit bewusstem User-Announce.
