# Changelog

All notable changes to agentbox are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.13] - 2026-04-15

### Fixed

- **`wsl --status`-Endlosschleife im Installer (Issue #32).** Ein User
  hatte WSL- und VM-Features korrekt aktiviert, der Kernel-Update-MSI
  war installiert, der Reboot war durchgelaufen — und `install.ps1`
  forderte trotzdem stur "Neustart erforderlich!" und schickte ihn
  immer wieder im Kreis.

  User-Report (Issue #32):
  ```
  WSL2 ist nicht installiert — richte es automatisch ein...
  Versuche: wsl --install --no-distribution ...
  Fallback: Aktiviere WSL- und VM-Features manuell...
    [OK] Windows Subsystem for Linux bereits aktiv
    [OK] Virtual Machine Platform bereits aktiv
    Lade WSL2-Kernel-Update herunter...
    [OK] WSL2-Kernel-Update installiert
  ========================================
   Neustart erforderlich!
  ========================================
  ```

  Diagnose vom User selbst im Issue-Kommentar: *"wsl -xxx geht nur in
  der CMD nicht in PS :-)"*. Es ist tatsaechlich ein bekanntes Quirk-
  Bundle: `wsl.exe --status` (und `wsl --install`) liefern aus PS 5.1
  heraus regelmaessig `$LASTEXITCODE != 0`, obwohl derselbe Aufruf in
  cmd.exe sauber durchlaeuft. 1.0.7/1.0.11 hatten das ueber
  `Invoke-Native` nur halb abgefangen — der NativeCommandError bei
  stderr-Output war damit weg, der falsche Exit-Code aber nicht.
  Ursachenmix: UTF-16LE-Output von Inbox-WSL, Argument-Weiterreichung
  in PS, Console-Handle-Detection in wsl.exe.

  Folge im Code: bei Issue #32 lief der Installer in
  - `wsl --status` (Initial-Probe, Zeile 175) → faelschlich != 0
  - `wsl --install --no-distribution` (Methode 1) → faelschlich != 0
    → unnoetiger Sprung in den manuellen Fallback
  - `wsl --status` (Reboot-Detection, Zeile 239) → faelschlich != 0
    → `$needsReboot = $true` → "Neustart erforderlich"-Endlosschleife

  Fix: neuer Helper `Invoke-WslExitCode` in `install.ps1`, der
  `wsl ...`-Probes durch `cmd.exe /c "wsl ... >NUL 2>&1"` routet und
  nur den Exit-Code zurueckgibt. cmd.exe isoliert PS vollstaendig von
  den wsl.exe-Quirks: kein NativeCommandError, kein UTF-16LE-Decoding,
  korrekte Argument-Weiterreichung. Output wird verworfen — wir
  brauchen nur den Exit-Code, und das Decoding waere unter Inbox-WSL
  ohnehin unzuverlaessig.

  Drei Callsites in `install.ps1` umgebogen:
  - Initial-Probe `wsl --status` vor dem Install-Block
  - `wsl --install --no-distribution` (Methode 1)
  - Post-Fallback `wsl --status` fuer die Reboot-Detection

  Die nachgelagerten Checks (`vmcompute`-Service-Status, CBS Pending-
  Reboot-Flag) bleiben unveraendert — die haben den Fall sowieso schon
  korrekt erkannt, sind durch die falsche `wsl --status`-Vorpruefung
  nur nie erreicht worden.

## [1.0.12] - 2026-04-14

### Fixed

- **Remove-Item-Crash bei Tilde-Username — der echte Fix.** 1.0.8/1.0.9
  hatten `-Path` auf `-LiteralPath` umgestellt, in der Annahme das wuerde
  reichen. Falsch: PS 5.1 hat einen **separaten Provider-Bug**, bei dem
  `Remove-Item -LiteralPath` mit Tilde-Pfaden (`C:\Users\SCHLER~1\...`)
  trotzdem mit `InvalidArgument` crasht — obwohl `Test-Path -LiteralPath`
  mit dem gleichen Pfad `$true` returnt. Inkonsistenz im FileSystem-Provider.

  User-Report:
  ```
  Remove-Item : Ein Objekt im angegebenen Pfad "C:\Users\SCHLER~1"
                ist nicht vorhanden.
  +     Remove-Item -LiteralPath $tempZip -Force -ErrorAction Sil ...
  ```

  Korrekter Fix: alle `Remove-Item`-Calls in den ZIP-, Update-, Migration-
  und Cleanup-Pfaden durch `[System.IO.File]::Delete()` und
  `[System.IO.Directory]::Delete()` ersetzt. Das umgeht den PS-Provider
  vollstaendig und nutzt Win32 direkt. Betroffen:
  - `install.ps1` ZIP-Update-Cleanup (war der Trigger)
  - `install.ps1` Neuinstall-ZIP-Cleanup
  - `install.ps1` Neuinstall-git-clone-Cleanup
  - `install.ps1` WSL-Kernel-MSI-Cleanup
  - `win-setup-core.ps1` Template-Build-Setup-Cleanup (2 Stellen)
  - `win-setup-core.ps1` Legacy-Sandbox-Migration-Cleanup
  - `win-task-runner.ps1` Task-File-Cleanup nach Verarbeitung

  `Test-Path -LiteralPath` und `Copy-Item -LiteralPath` sind weiter im
  Einsatz — die haben den Bug nicht, nur `Remove-Item`. Statt `Test-Path`
  fuer die `Delete()`-Vorabchecks: `[System.IO.File]::Exists()` /
  `[System.IO.Directory]::Exists()`, ebenfalls Win32-direkt.
- **`Get-ChildItem -Force` im Update-Loop**, damit hidden Files wie
  `.version` mitkopiert werden. Vorher waren Updates im "Endlos-Loop":
  Code wurde aktualisiert (Copy-Item lief), aber `.version` blieb
  stehen, weil `Get-ChildItem` ohne `-Force` keine Dot-Files auflistet —
  beim naechsten `irm | iex`-Run sah der Installer wieder "Local 1.0.9
  → Remote 1.0.x" und ratterte denselben Update-Pfad nochmal durch.
  Effekt fuer den User: `irm | iex` war effektiv idempotent
  funktional, aber kosmetisch immer mit Update-Phase + Cleanup-Crash.

## [1.0.11] - 2026-04-14

### Added

- **`Invoke-Native`-Helper in `install.ps1`.** Wrapping-Function fuer
  alle nativen Tool-Calls (wsl.exe, git.exe, etc.), die unter PS 5.1 +
  `$ErrorActionPreference='Stop'` an stderr-Output crashen koennen
  (NativeCommandError, der durch `2>&1` nicht abgefangen wird). Setzt
  lokal `Continue` und wrapped den Block in try/catch, restored den
  vorherigen Wert in finally.

### Fixed (proaktiver Bug-Sweep)

Nach mehreren Roundtrips, bei denen ich denselben Bug-Pattern in Files
uebersehen habe (1.0.8 nur `install.ps1`, 1.0.9 dann erst `win-setup-
core.ps1`), habe ich systematisch alle PS- und Bash-Files nach den
bekannten Bug-Klassen durchsucht und proaktiv alle latenten Stellen
gefixt:

- **`win-task-runner.ps1`**: Komplette `-LiteralPath`-Umstellung fuer
  alle `Test-Path`, `Get-Content`, `Get-ChildItem`, `New-Item`,
  `Remove-Item`, `Copy-Item`, `Move-Item`-Calls mit Variablen-Pfaden.
  Vorher anfaellig fuer den Tilde-Username-Bug (Schueler → SCHLER~1)
  bei Background-Task-Runs.
- **`install.ps1::Import-AgentboxHostDistro`**: `wsl -l -q`,
  `wsl --unregister`, `wsl --import` jetzt alle ueber `Invoke-Native`.
  Vorher: bei Erst-Install (oder wenn `agentbox-host` per Reset
  geloescht wurde) konnte `wsl --import` mit Status-Output auf stderr
  den Installer killen.
- **`install.ps1` WSL2-Bootstrap-Phase**: `wsl --install
  --no-distribution` und beide `wsl --set-default-version 2`-Calls
  jetzt ueber `Invoke-Native`. Vorher: auf einem frischen Windows ohne
  WSL2 wuerde der Installer im automatischen WSL-Setup an den
  Status-Messages crashen — bei einem User der gerade WSL einrichten
  laesst, der schlimmstmoegliche Zeitpunkt.
- **`install.ps1` `.bashrc`-Phase (Zeile 727-897)**: Komplette Phase
  laeuft jetzt mit lokalem `$ErrorActionPreference = "Continue"`,
  vorheriger Wert wird am Ende der Phase wiederhergestellt. 7 latente
  `wsl -d agentbox-host bash -c ...`-Calls in einem Schritt abgesichert
  (grep, cp, python3, base64-Append). Im happy path war keiner der
  Calls anfaellig, aber bei jeder bash-Warning oder einem nicht-existen-
  ten File haette es geknallt.
- **`install.ps1` finaler Auto-Start (Zeile 1030)**: Der finale
  `wsl -d agentbox-host -e bash -li -c "agentbox"` jetzt ueber
  `Invoke-Native`, weil `wsl-ai-start.sh` und der Sandbox-Trap stderr
  schreiben — der Installer haette sonst statt mit cleanem Exit mit
  einem NativeCommandError raus.

## [1.0.10] - 2026-04-14

### Fixed

- **`wsl-ai-start.sh` startete nicht mit Umlaut-Usernamen.** Beim
  ersten Start im agentbox-host crashte das Script mit
  `FEHLER: %LOCALAPPDATA% nicht ermittelbar`. Ursache: Die Funktion
  `_resolve_agentbox_local_root` rief `cmd.exe /c echo %LOCALAPPDATA%`
  auf — und cmd.exe schreibt seinen Output in der OEM-Codepage
  (cp850 in DE), nicht UTF-8. Bei einem User namens "Schueler" wird
  das `ue` als single byte 0x81 ausgegeben, bash interpretiert das
  als invalid UTF-8 lead byte, und `wslpath -u` bekommt einen
  Garbage-Pfad.

  Fix: Drei-stufige Aufloesung mit Fallbacks:
  1. `powershell.exe` mit explizitem
     `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8` —
     bevorzugte Methode, robust gegen Umlaute.
  2. `cmd.exe` als Fallback fuer ASCII-Usernamen, wenn PowerShell
     nicht verfuegbar ist.
  3. **Filesystem-Glob auf `/mnt/c/Users/*/AppData/Local/agentbox/`**
     als finaler Rettungsanker. Bash-globbing arbeitet direkt mit den
     Filesystem-Bytes ohne Encoding-Roundtrip — funktioniert garantiert
     bei jedem Username, solange `install.ps1` den Ordner schon angelegt
     hat. Ueberspringt Public/Default/All-Users-System-Profile.

  Bei Failure jetzt diagnostische Fehlermeldung mit den drei probierten
  Methoden und Hinweisen zum Pruefen des WSL-Interops.
- **Selber Bug auch in der Sandbox-Distro-Import-Phase
  (`WIN_TEMP_BASE`).** `wsl-ai-start.sh:1222` rief ebenfalls
  `cmd.exe /c echo %TEMP%` auf — beim selben Username waere der
  Sandbox-Import an `wsl --import` mit korruptem Pfad gescheitert.
  Gleicher PowerShell-zuerst-Cascade als Fix.

## [1.0.9] - 2026-04-14

### Fixed

- **Tilde-Username-Crash jetzt auch in `win-setup-core.ps1` gefixt.**
  1.0.8 hatte den `Remove-Item -Path`-Bug nur in `install.ps1`
  beseitigt, aber `win-setup-core.ps1` (das wird vom Installer
  aufgerufen) hatte die gleiche Falle in mehreren Stellen — der
  naechste Lauf crashte direkt im Template-Build-Cleanup:

  ```
  Remove-Item : Ein Objekt im angegebenen Pfad "C:\Users\SCHLER~1"
                ist nicht vorhanden.
  In Zeile:370 Zeichen:5
  +     Remove-Item -Path $tempSetup -Recurse -Force
  ```

  Fix: Systematisch ALLE `*-Item -Path` und `Test-Path` mit
  Variablen-Pfaden in `win-setup-core.ps1` und nachgezogen auch in
  `install.ps1` auf `-LiteralPath` umgestellt. Betrifft Cmdlets:
  `Test-Path`, `New-Item`, `Get-Content`, `Get-ChildItem`,
  `Copy-Item`, `Move-Item`, `Remove-Item`, `Out-File`,
  `Expand-Archive`. Function-Aufrufe an eigene Helper-Functions
  (`Set-ShortcutRunAsAdmin -Path`, `Merge-AgentboxClaudeSettings -Path`,
  `Write-AgentboxSeedIfEmpty -Path`) sind absichtlich NICHT umgestellt
  — die heissen das Param so und nutzen .NET-File-API intern, was
  Tilde-safe ist.

## [1.0.8] - 2026-04-14

### Fixed

- **ZIP-Update crashte bei User-Namen mit Umlaut.** Wenn der Windows-
  User-Name ein Sonderzeichen enthielt (z.B. "Schueler" → 8.3-Pfad
  `C:\Users\SCHLER~1\AppData\Local\Temp\...`), warf `Remove-Item -Path`
  im Cleanup-finally-Block:

  ```
  Remove-Item : Ein Objekt im angegebenen Pfad "C:\Users\SCHLER~1"
                ist nicht vorhanden.
  In Zeile:546 Zeichen:17
  +     Remove-Item -Path $tempZip -Force -ErrorAction SilentlyCo ...
      + CategoryInfo : InvalidArgument: (:) [Remove-Item], PSArgumentException
  ```

  Ursache: PS 5.1 `Remove-Item -Path` resolved den Pfad mit Wildcard-
  Pattern-Engine, die am Tilde des 8.3-Namens stolpert. Update wurde
  zwar erfolgreich angewendet ("[OK] Update per ZIP abgeschlossen"),
  aber der Cleanup-Fehler killte den Installer mit `$ErrorActionPreference
  = "Stop"`.

  Fix: Alle `*-Item -Path` mit User-TEMP-Pfaden auf `-LiteralPath`
  umgestellt — das umgeht jede Pattern-Interpretation. Plus defensive
  `Test-Path -LiteralPath`-Guards vor jedem Remove-Item, damit ein
  noch nicht erstellter Temp-Pfad keinen zusaetzlichen Fehler wirft.
  Betroffen: ZIP-Update-Pfad, Neuinstall-ZIP-Pfad, Neuinstall-git-clone-
  Pfad, WSL-Kernel-MSI-Cleanup im WSL2-Bootstrap.

## [1.0.7] - 2026-04-14

### Fixed

- **Pre-Flight crashte mit `NativeCommandError` waehrend WSL-Update.**
  PS 5.1 unter `$ErrorActionPreference='Stop'` wirft fuer jede stderr-
  Zeile eines nativen Tools einen `ErrorRecord` — auch mit `2>&1`. Das
  Zwischen-`Test-WslVersionOk`, das nach `wsl --update` lief, fiel auf
  die Schnauze, weil `wsl.exe --version` Status-Meldungen wie
  "WSL beendet ein Upgrade..." auf stderr schreibt:

  ```
  wsl.exe : WSL beendet ein Upgrade...
  In Zeile:261 Zeichen:12
  +     $out = & wsl.exe --version 2>&1 | ...
  ```

  Fix: `Test-WslVersionOk` (jetzt umbenannt zu `Get-WslVersionLine` +
  duenner Bool-Wrapper) und `Invoke-WslUpdate` setzen lokal
  `$ErrorActionPreference = "Continue"` und wrappen die Pipeline in
  try/catch. Damit ueberlebt der Pre-Flight stderr-Output von wsl.exe
  ohne abzubrechen, der Update-Loop laeuft sauber durch, und die
  finale Versionszeile wird auch im Erfolgsfall ausgegeben (z.B.
  "[OK] WSL erfolgreich aktualisiert: WSL-Version: 2.3.26.0").
- Doppelter `wsl.exe --version`-Aufruf in der Pre-Flight-Anzeige
  entfernt — die Version wird jetzt von `Get-WslVersionLine` gleich
  mit zurueckgegeben, statt sie nochmal anzufordern (was vorher den
  gleichen stderr-Bug ausloesen konnte).

## [1.0.6] - 2026-04-14

### Changed

- **`Import-AgentboxHostDistro` setzt agentbox-host nicht mehr explizit
  als WSL-Default, und kennt keine docker-desktop-Sonderfaelle mehr.**
  1.0.5 hatte eine `$hasRealUserDistro`-Detection, die `docker-desktop`
  als Pseudo-Distro klassifizierte und in dem Fall die Default mit
  agentbox-host ueberschrieben hat. Das war Magie ohne Mehrwert: agentbox
  spricht seine Distro seit 1.0.5 ueberall mit `-d agentbox-host` an,
  also ist die WSL-Default fuer agentbox egal. Wenn der User vorher gar
  keine Distro hatte, setzt WSL agentbox-host beim Import automatisch
  als Default — wir muessen das nicht selbst machen. Wenn der User
  schon eine Default hatte (Ubuntu, Debian, docker-desktop — egal),
  wird sie jetzt unangetastet gelassen. Kein Workflow-Bruch fuer den
  User, kein Sonderfall im Code.

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
