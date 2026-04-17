# Changelog

All notable changes to agentbox are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0] - 2026-04-17

### Added — Performance-Architektur

Massiv-Umbau auf Hybrid-Architektur (vhdx-Template + ext4-Overlays) und
Netzwerk-Tuning. Der tar.gz-/DrvFs-Pfad bleibt als transparenter
Fallback erhalten — bei aelteren WSL-Versionen oder fehlgeschlagenem
vhdx-Import laeuft alles wie in 1.x.

- **vhdx-Template-Fastpath** — `win-setup-core.ps1` exportiert zusaetzlich
  zum tar.gz eine `template.vhdx` via `wsl --export --vhd`. Beim Session-
  Start in `wsl-ai-start.sh` wird die vhdx per File-Copy (~3-5s auf SSD)
  dupliziert und per `wsl --import-in-place` (<1s) als Distro registriert.
  Gesamter Sandbox-Start: ~5s statt 30-120s bei tar.gz-Extract.
  Fallback transparent auf tar.gz wenn `--export --vhd` oder
  `--import-in-place` nicht verfuegbar (WSL <2.0.x). Best-Effort: schlaegt
  der vhdx-Export fehl, wird stillschweigend nur das tar.gz gepflegt.

- **Hybrid-Workspace (ext4-Overlays fuer Heavy-I/O)** — in
  `wsl-sandbox-init.sh` werden fuer bekannt-ephemere Verzeichnisse
  (`node_modules`, `.next`, `dist`, `build`, `out`, `target`,
  `__pycache__`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache`) leere
  ext4-Ordner unter `/var/agentbox-overlay/` angelegt und ueber den
  DrvFs-Pfad im Workspace bind-gemountet. Schreibvorgaenge des Agents
  gehen auf ext4 (500 files/s vs 125 files/s auf DrvFs), Quellcode-
  Writes (`src/...`) gehen weiter direkt auf DrvFs/OneDrive. Kein
  Overlay fuer `.git` — zu riskant fuer Commit-History.

- **TCP BBR Congestion Control** — `sysctl -w
  net.ipv4.tcp_congestion_control=bbr` in `wsl-sandbox-init.sh`, per
  `modprobe tcp_bbr` mit Fallback auf Kernel-Default.

- **TCP Fast Open (TFO)** — `net.ipv4.tcp_fastopen=3`, spart einen
  Roundtrip pro HTTPS-Connection (npm/pip/git/AI-API).

- **Socket-Buffer-Tuning** — `rmem_max`/`wmem_max`/`tcp_rmem`/`tcp_wmem`
  auf 16 MB (default ~200 KB). Entspricht BDP fuer ~1 Gbps-Links.

- **Lokaler DNS-Cache via dnsmasq** — `dnsmasq-base` ins Template
  installiert, `wsl-sandbox-init.sh` startet dnsmasq auf 127.0.0.1 und
  biegt `/etc/resolv.conf` dorthin um. DNS-Latenz fuer wiederholte
  Lookups (npm/pip machen 50-200 pro Install) faellt von ~28ms auf <1ms.
  Fallback auf direkte Upstream-Resolver, wenn `dnsmasq` nicht
  installiert oder der Start fehlschlaegt.

- **PMTU-Probing** — `net.ipv4.tcp_mtu_probing=1`, schuetzt TFO+BBR-
  Gewinne vor Fragmentierungs-Stalls bei VPN/Corporate-Proxies.

### Changed

- `.update_class` auf `major` — Release braucht `install.ps1`-Rerun als
  Admin, damit das neue Template (mit `dnsmasq-base`) gebaut und die
  vhdx erzeugt wird. Ohne Rebuild bleibt der tar.gz-Pfad der 1.x-
  Semantik aktiv (kein Regression-Risiko, aber keine 2.0-Gewinne).

### Migration

Bestehende 1.x-Installationen: `install.ps1` erneut als Admin laufen
lassen. Der Template-Rebuild passiert automatisch (Config-Hash aendert
sich durch `dnsmasq-base` und die neuen sysctls). Kein manuelles
Aufraeumen noetig.

## [1.0.25] - 2026-04-17

### Fixed

- **`wsl-ai-start.sh` crasht mit nacktem `Input/output error` wenn
  OneDrive nicht laeuft und `_control/lib/config.sh` nur als Cloud-
  Placeholder existiert (User-Report, Schueler-OneDrive-Setup).** Der
  Standard-Install liegt in `%OneDrive%\AI_Projects_Source\` — Dateien
  die laenger nicht angefasst wurden werden von Files-On-Demand zu
  reinen Placeholdern degradiert. Solange OneDrive laeuft, hydratet es
  diese bei Zugriff transparent. Wenn OneDrive aber nicht laeuft (User
  hatte's explizit nicht gestartet), kann WSLs `/mnt/c`-Bridge die
  Placeholder nicht laden — der `source`-Call returnt I/O error, und
  der agentbox-Alias stirbt mit einer Meldung die fuer den User
  voellig kontextfrei aussieht.

  Fix: Preflight-Probelesen mit `head -c 1` vor dem `source`. Wenn
  der Read scheitert UND der Pfad wie `/mnt/c/...OneDrive...`
  aussieht, geben wir eine klare Diagnose + zwei konkrete Fix-Pfade
  aus (OneDrive starten ODER im Explorer rechtsklick ->
  "Immer auf diesem Geraet behalten"). Bei anderen Pfaden ein
  generischer Hinweis auf Filesystem/Mount-Pruefung. Danach sauberer
  `exit 1` statt Cascading-Failure.

  Nicht-Fix: wir spiegeln `_control/` nicht nach
  `%LOCALAPPDATA%\agentbox\control-cache\` (waere der robuste
  Architektur-Fix, aber signifikante Refactor-Flaeche und OneDrive-
  Versioning der Config ist ein bewusstes Feature). Erstmal nur
  die Diagnose-Verbesserung — wenn das nochmal hochkommt, ziehen
  wir den Mirror-Ansatz nach.

## [1.0.24] - 2026-04-17

### Fixed

- **KRITISCH: `install.ps1` crasht auf Win10 + PS 5.1 mit `iex :
  InvokeMethodOnNull` nach "agentbox bereits installiert — pruefe
  Update..." (User-Report, Build 19045).** Der Versionsvergleich
  liest `.version` via `(Get-Content -Raw -ErrorAction SilentlyContinue).Trim()`.
  PS 5.1 hat die Eigenheit, bei `-Raw` auf einer leeren oder
  zerstoerten Datei (0 Bytes, OneDrive-Placeholder nicht
  heruntergeladen, abgebrochener ZIP-Copy) `$null` statt `""`
  zurueckzuliefern. `.Trim()` darauf crasht mit
  `RuntimeException: method invocation on null`. Weil der Call
  NICHT in try/catch steht, bubble-t das ueber iex zum User als
  "iex : InvokeMethodOnNull" mit Position im Einzeiler — ohne
  Hinweis wo im Script der Fehler war.

  Fix: Null-Check zwischen Read und Trim. Wenn `.version` leer oder
  `$null` zurueckkommt, bleibt `$localVersion = ""` (wie ohnehin
  oben initialisiert), der Versions-Vergleich landet dann bei
  "lokal != remote" → Update wird gepullt → `.version` wird
  ueberschrieben. Self-healing.

  Zeile 524 (`(Invoke-WebRequest ...).Content.Trim()`) ist
  hiervon nicht betroffen, weil sie bereits in einem try/catch
  laeuft und `$remoteVersion` auf `""` initialisiert ist.

## [1.0.23] - 2026-04-17

### Removed

- **Tote `firewall_*`-Keys komplett ausgebaut statt sie als "Altlast,
  kein Runtime-Effekt" in README + config.json zu beschriften.** Die
  drei Keys `firewall_ai_apis`, `firewall_registries_node`,
  `firewall_registries_python` stammen aus einem frueheren Design-
  Entwurf mit per-Domain-Egress-Filtering. Das ist nie Runtime
  geworden (iptables matcht Hostnamen nicht zuverlaessig wenn CDNs
  IPs rotieren — daher der Blanket-HTTPS-Allow + Private-Range-DROP-
  Ansatz den wir tatsaechlich fahren). Die Keys wurden trotzdem aus
  `config.json` gelesen, durch `wsl-ai-start.sh` als Args 5-7 an
  `wsl-sandbox-init.sh` gereicht, und dort in `AI_API_DOMAINS` +
  `PACKAGE_DOMAINS` einsortiert — wo sie von keinerlei weiterer
  Logik mehr gelesen wurden. Pure Dead-Code-Kette.

  Gruende fuer die komplette Loeschung (statt weiter-tragen):
  - README-Eintrag "Altlast, kein Runtime-Effekt" wirkt unprofessionell,
    verlaengert die Config-Tabelle um drei Zeilen die man nicht anfassen
    soll, und lenkt vom echten Threat-Model ab.
  - User-Report: "wirkt weder in der README noch im Code gut."
  - CLAUDE.md-Policy: "Avoid backwards-compatibility hacks like
    renaming unused _vars ... If you are certain that something is
    unused, you can delete it completely."

  Aenderungen:
  - `config.json`: drei Keys raus.
  - `wsl-ai-start.sh`: drei `cfg_get_array`-Reads + drei Fallback-
    Defaults raus, Argumentliste zu `/sandbox-init.sh` von 9 auf 6
    Positions-Args gekuerzt.
  - `wsl-sandbox-init.sh`: drei Arg-Positionen raus (AI_API_DOMAINS,
    CFG_REG_NODE, CFG_REG_PYTHON), `AUTH_BASE_IN` + `AGENT_INSTALL`
    ruecken auf Position 5/6, Usage-String entsprechend. Der tote
    `PACKAGE_DOMAINS`-Case-Block (der nur echo'd hat und die Variable
    nirgends mehr gelesen wurde) ist auch weg.
  - `README.md` + `docs/README.de.md`: drei Config-Tabellen-Zeilen
    raus, Altlast-Warnparagraph in der Network-Isolation-Section raus.

  User-Impact: keiner. Wer die Keys in einer custom `config.json`
  gesetzt hat, bekommt sie ignoriert (wie vorher auch — sie waren ja
  schon effektiv tot).

## [1.0.22] - 2026-04-17

### Added

- **VS Code als Launcher-Option fuer den Shortcut — Live-Filewatch +
  Agent-Terminal im Editor.** Bisher bekam der User beim Doppelklick auf
  den agentbox-Shortcut immer ein Windows-Terminal-Fenster mit dem
  Agent-Prompt. Das ist schlank und bewaehrt, verliert aber den einen
  Workflow-Gewinn, den VS Code hier bringt: waehrend der Agent Dateien
  in `/workspace` aendert (= Bind-Mount des Projektordners auf Windows-
  Seite), kann VS Code als Editor parallel geoeffnet sein und jede
  Aenderung **live** anzeigen — Explorer-Tree refresht neue/geloeschte
  Dateien sofort, offene Dateien reloaden automatisch, Git-Gutter zeigt
  Diffs in Echtzeit.

  Implementation:
  - **Neuer config.json-Key `launch_ui`** mit Werten `wt` (Default),
    `vscode`, oder `both`. Leer beim Erstinstall → install.ps1 fragt
    einmalig ab ([1]/[2]/[3]-Prompt mit 5s-Timeout = Default wt),
    persistiert die Wahl. User-configs ueberleben ZIP-Updates, also
    wird die Wahl nur genau einmal verlangt.
  - **winget-Autoinstall** von VS Code wenn `launch_ui` ihn braucht und
    `code.exe` nicht gefunden wird — gleiches Muster wie 1.0.17
    wt.exe-Install, mit `--scope user` damit kein Admin noetig ist.
  - **Smart-Merge** eines `agentbox`-Terminal-Profils in
    `%APPDATA%\Code\User\settings.json` — JSON-parse, nur neuen Key
    ergaenzen, User-Settings bleiben unangefasst. JSONC-Dateien mit
    Kommentaren (PS 5.1 ConvertFrom-Json kann die nicht parsen) werden
    nicht angefasst, stattdessen Manual-Snippet auf der Konsole
    ausgegeben.
  - **Workspace-File `agentbox.code-workspace`** im Repo-Root. Enthaelt
    Folder-Pointer auf `../` (= baseDir, damit alle Projekte im
    Explorer sichtbar sind), Terminal-Profil `agentbox`, und einen
    Task mit `runOn: folderOpen` der `wsl.exe -d agentbox-host -e bash
    -li -c agentbox` in einem dedicated Terminal-Panel startet. Beim
    ersten Oeffnen fragt VS Code einmal "trust this workspace" — danach
    laeuft der Agent auto-start beim Doppelklick.
  - **Shortcut-Dispatcher** (`New-AgentboxShortcut -Mode wt|wsl|vscode`)
    legt je nach launch_ui einen oder zwei Shortcuts an (`agentbox.lnk`
    fuer wt, `agentbox (VS Code).lnk` fuer vscode). Bei `both` existieren
    beide parallel auf Desktop + Start-Menue. Wechselt der User spaeter
    zwischen Modi, raeumt der naechste install.ps1-Lauf den nicht mehr
    gewaehlten Shortcut weg (keine Zombie-Links).

  Bewusste Nicht-Entscheidung: VS Code ist nicht hart-Default, weil
  viele User bereits Cursor/Zed/JetBrains/Neovim nutzen. Der Prompt
  respektiert Enter → wt, und der bisherige Workflow bleibt 1:1
  erhalten.

### Changed

- **PS 5.1 `New-Item`-Regel ergaenzend angewandt:** der Start-Menue-
  Directory-Create nutzt jetzt ebenfalls `[System.IO.Directory]::
  CreateDirectory` statt `New-Item -Force`. Die 1.0.20-Regel ist
  damit im gesamten Installer durchgezogen.

## [1.0.21] - 2026-04-16

### Diagnostics

- **Install-Log wird jetzt auch bei Agent-Verifikations-Failure ausgegeben.**
  Bisheriger Zustand: nach 1.0.20 hat der User eine Setup-Failure gemeldet
  mit `[OK] Pakete installiert` gefolgt von `[FEHLT] claude / codex /
  gemini`. Die Distro wurde unmittelbar danach via `wsl --unregister` in den
  Wind geschossen, mit ihr `/var/log/agentbox-install.log` — also keinerlei
  Information warum die Agents fehlen.

  Hintergrund: der `installRc != 0`-Pfad dumpt das Log-Tail bereits seit
  1.0.18. Der `installRc == 0` + Agent-fehlt-Pfad nicht, weil die Annahme
  war: wenn das Install-Script sauber durchlaeuft, sind die Binaries auch
  da. Die Annahme stimmt nicht, weil die Agent-Install-Zeilen mit
  `|| echo 'WARNUNG: …'` enden — eine npm/pip-Failure unterdrueckt set
  -e und das Script exited 0, obwohl der Agent nie installiert wurde.

  Fix: vor dem `wsl --unregister` im Verifikations-Failure-Pfad jetzt
  ebenfalls `tail -n 120 /var/log/agentbox-install.log` ausgeben. Dann
  sieht man beim naechsten Run, ob es ein npm-EACCES, ein nodesource-
  GPG-Problem, Network-Timeout, PEP-668-Block (pip3) oder etwas anderes
  ist — ohne erneut die ganze Distro neu bauen zu muessen.

  Reine Diagnostik-Verbesserung, kein funktionaler Fix — die Root-Cause
  des aktuellen User-Reports ist ohne Log-Output nicht bestimmbar.
  Nach diesem Update bitte einmal `install.ps1` neu starten, dann
  liegt der Log-Tail im Output.

## [1.0.20] - 2026-04-16

### Fixed

- **KRITISCH: Template-Build crasht bei jedem Setup-Lauf mit
  `New-Item: Es wurde kein Parameter gefunden, der dem Parameternamen
  "LiteralPath" entspricht"` (User-Report, Regression aus 1.0.9).** Der
  1.0.9-Fix hatte zur Loesung des Tilde-Username-Bugs (`SCHLER~1`)
  systematisch alle `*-Item -Path` auf `-LiteralPath` umgestellt —
  inklusive `New-Item`. Was damals uebersehen wurde: `New-Item`
  bekam den `-LiteralPath`-Parameter erst in PS 6. In PS 5.1 — dem
  Ziel-Interpreter auf allen Windows-Hosts ohne pwsh — existiert der
  Parameter schlicht nicht, der Aufruf crasht mit
  `NamedParameterNotFound`. Getriggert wird der Pfad immer dann,
  wenn `Test-Path` auf dem Ziel-Dir `false` liefert — also bei
  Template-Rebuilds mit frischem `$env:TEMP\agentbox\setup` oder bei
  Erst-Installs.

  Fix: Alle 11 `New-Item -ItemType Directory -LiteralPath ...
  -Force`-Aufrufe (in `win-setup-core.ps1`, `install.ps1`,
  `win-task-runner.ps1`) durch `[System.IO.Directory]::CreateDirectory(...)
  | Out-Null` ersetzt. Die .NET-API ist PS-5.1-kompatibel, idempotent
  (entspricht `-Force`) und umgeht den PS-Provider komplett, womit
  sie automatisch auch tilde-/umlaut-safe ist — gleicher Grund,
  aus dem wir an der `Remove-Item`-Stelle bereits
  `[System.IO.Directory]::Delete` nutzen.

  Guard gegen Wiederholung: Regel in `CLAUDE.md` dokumentiert, dass
  `New-Item -LiteralPath` in dieser Codebasis **verboten** ist und
  stattdessen `[System.IO.Directory]::CreateDirectory` zu verwenden
  ist. Fuer alle anderen Cmdlets (`Test-Path`, `Remove-Item`,
  `Get-Content`, ...) bleibt `-LiteralPath` aus Tilde-Safety-Gruenden
  die richtige Wahl.

## [1.0.19] - 2026-04-15

### Fixed

- **KRITISCH: Jede Sandbox-Session kracht in Parent-Trap, sobald der
  Claude-Update-Run ins Timeout laeuft (User-Report JUC 1.0.18).** Die
  1.0.18-Verbesserungen am `_run_agent_update`-Block hatten den
  Heartbeat und Timeout-Kill korrekt, aber ich habe `set -euo pipefail`
  am Script-Anfang uebersehen. `timeout -k 10 180` liefert rc=137
  (SIGKILL), `set -e` triggert sofort, Script exit, und der
  Parent-Cleanup-Trap in `wsl-ai-start.sh` unregistriert die Sandbox-
  Distro — die Session ist weg, die `_update_rc=$?`-Zeile, die
  WARN-Behandlung, und alles danach wird nie erreicht. Effekt auf JUCs
  Rechner: jede Session hing 180s in "Pruefe claude auf Updates", kam
  dann mit "Killed", die Distro wurde unregistered, agentbox fiel in
  die Projekt-Auswahl zurueck, naechste Runde, gleicher Hang — keine
  Moeglichkeit zu agentbox durchzukommen.

  Fix: klassisches `set -e`-Workaround-Pattern — das `timeout …`-
  Kommando mit `|| _update_rc=$?` abschliessen. Der gesamte Ausdruck
  ist dann ein "erfolgreicher" Compound-Command (egal ob die LHS
  fehlschlaegt), `set -e` greift nicht mehr, und `$_update_rc` traegt
  den echten Exit-Code fuer die nachfolgende Fallunterscheidung.
  Getestet mit `bash -c 'set -euo pipefail; FOO=bar timeout 1 sleep 5
  || _rc=$?; echo $_rc'` → rc=124, Script laeuft weiter, so gewollt.

- **npm-Cache kalt bei jedem Session-Start.** Der Update-Run laeuft
  als `root`, aber der persistente npm-Cache (bind-mount von
  `%LOCALAPPDATA%\agentbox\cache\npm`) haengt nur unter
  `/home/$SANDBOX_USER/.npm`. Root's `/root/.npm` ist ephemer in der
  frisch importierten Sandbox-Distro → bei jedem Start wurde der
  komplette Claude-Code-Dependency-Tree aus dem Netz geladen statt
  aus dem Cache. Auf langsamen Verbindungen reichten die 180s Timeout
  aus 1.0.18 nicht. Fix: `npm_config_cache=/home/$SANDBOX_USER/.npm`
  als Env-Var vor dem Update-Invocation setzen — root teilt sich
  damit den Cache mit dem spaeteren agent-User, nach dem ersten
  erfolgreichen Run ist er warm und der naechste Update-Run laeuft
  in wenigen Sekunden durch.

- **`npm_config_prefer_offline=true`** ergaenzend: wenn das Package
  schon im Cache liegt, gar kein Registry-Roundtrip mehr. Faellt auf
  Netz zurueck wenn der Cache kalt ist. Macht warme Updates
  near-instant (~2-5s statt ~30-60s).

- **Timeout auf 300s erhoeht** (von 180s). 180s waren auf JUCs
  Verbindung zu knapp, und der Heartbeat zeigt ja Fortschritt, also
  ist eine etwas laengere Toleranz OK. Der kill-escalation-Pfad
  (`-k 10`) bleibt unveraendert.

### Notizen

- Die NPM-Env-Vars haben in 1.0.18 `NPM_CONFIG_…` in Grossbuchstaben
  verwendet. Auf Linux sind Env-Var-Namen case-sensitive, npm liest
  primaer die `npm_config_…`-Schreibweise (siehe npm docs, "Environment
  Variables"). Der Effekt war wohl nur deshalb nicht frueher
  aufgefallen, weil die "spart Zeit"-Optimierung im Log eh kaum
  sichtbar war — auf Kalte-Cache-Runs macht AUDIT/FUND/PROGRESS keine
  dramatische Differenz. In 1.0.19 jetzt einheitlich lowercase.

## [1.0.18] - 2026-04-15

### Fixed

- **Sandbox-Start hing bei "claude: X -> Y seit 2+ Minuten" (User-Report
  JUC).** Der 1.0.15-`_run_agent_update`-Block in `wsl-sandbox-init.sh`
  hatte drei Schwachstellen, die in Kombination einen unendlichen Hang
  auf dem `npm install`-Schritt erzeugen konnten:
  - **stdin war nicht geschlossen**: `bash -c "$_install"` erbt das
    Terminal-stdin. Wenn npm (oder ein Post-Install-Script) auf einen
    interaktiven Prompt wartet (z.B. "y/n"), blockt der ganze Run —
    Output geht ins Temp-Log, der User sieht aber nichts und kann
    auch nichts antworten.
  - **`timeout 120` ohne Kill-Eskalation**: bei Childs, die SIGTERM
    ignorieren, blieb der Prozess auch nach Ablauf der 120s haengen.
  - **Null Fortschritts-Feedback**: der User sitzt vor einer toten
    Statuszeile und denkt, agentbox ist abgestuerzt.

  Fix:
  - `bash -c "$_install" < /dev/null` schliesst stdin — npm bricht bei
    interaktivem Prompt sauber mit Fehler ab statt zu haengen.
  - `timeout -k 10 180 …` gibt 180s Grace (ausreichend auch fuer
    langsame Registries oder grosse Dep-Trees) und eskaliert bei
    SIGTERM-Ignore nach 10s auf SIGKILL.
  - `NPM_CONFIG_AUDIT=false NPM_CONFIG_FUND=false NPM_CONFIG_PROGRESS=false`
    spart 5-30s pro Run — Audit ist in einer ephemeren Sandbox ohnehin
    wertlos, Fund sind Spendennoten, Progress ist im Silent-Mode nutzlos.
  - **Heartbeat-Subshell**: alle 15s kommt eine Zeile
    `... noch beim Aktualisieren (<N>s)`, damit der User sieht dass der
    Start nicht tot ist. Wird via `trap RETURN` und expliziten
    `kill+wait`-Blocks sauber abgeraeumt, auch bei Timeout oder Early
    Return.
  - **Differenzierte Fehlermeldungen**: rc=124/137 wird jetzt explizit
    als Timeout gekennzeichnet (statt generisch "fehlgeschlagen"), so
    dass der User weiss ob es ein Netzwerk- oder ein Paket-Problem ist.

- **Desktop-Shortcut erschien nicht nach Installer-Rerun (User-Report
  JUC).** Nach `irm | iex` war kein `agentbox.lnk` auf dem Desktop —
  vermutete Ursache: OneDrive-Redirect des Desktop-Ordners, bei dem
  der COM-`Save()` zwar erfolgreich meldet, die Datei aber in einem
  Path landet, den der User nicht sieht (pausierter OneDrive-Sync,
  Files-on-Demand-Placeholder, unterbrochener Redirect).

  Fix in `install.ps1`:
  - **Shortcut wird zusaetzlich ins Start-Menue gelegt** (`%APPDATA%\
    Microsoft\Windows\Start Menu\Programs\agentbox.lnk`). Das ist der
    zuverlaessige Entry-Point: Win-Taste druecken, "agentbox" tippen,
    Enter — findet den Shortcut immer, unabhaengig von Desktop-
    Redirects.
  - **Beide Pfade werden vor der Erstellung explizit geloggt**
    (`Desktop-Pfad: ...`, `Start-Menue-Pfad: ...`), damit bei
    kuenftigen Problem-Reports sofort klar ist, wo der Installer
    hinschreiben wollte.
  - **Nach `$shortcut.Save()` wird `Test-Path` gecheckt**: wenn COM
    erfolgreich war aber die Datei nicht auf Disk liegt, bekommt der
    User eine laute `[WARN]` statt eines stillen Fehlers.
  - **Legacy-Cleanup beide Pfade**: `agentbox-installer.lnk` und
    `agentbox-update.lnk` werden jetzt sowohl am Desktop als auch im
    Start-Menue gesucht und entfernt, falls vorhanden.
  - **Helper-Funktion `New-AgentboxShortcut`**: gemeinsame Logik fuer
    beide Shortcut-Ziele (Desktop + Start-Menue), damit bei Aenderungen
    nicht mehr copy-paste an zwei Stellen noetig ist.

### Changed

- **Expliziter Hinweis beim Import der Sandbox-Distro**: die Log-Zeile
  in `wsl-ai-start.sh` ist jetzt `"Importiere Sandbox-Distro (extrahiert
  template.tar.gz, 30-120s)..."` statt nur `"Importiere Sandbox-Distro..."`.
  User-Report JUC: die Extraktion dauert auf manchen Rechnern "sehr
  lange" und die stumme Statuszeile sah aus wie ein Hang. Die 30-120s
  sind **inhaerent zur ephemeren Per-Session-Architektur** (Template ist
  gzip-komprimiert und wird bei jedem Start frisch entpackt), nicht
  fixable ohne architekturellen Umbau auf vhdx-basiertes Snapshotting.
  Fuer jetzt: transparenter Hinweis, damit der User nicht faelschlich
  Ctrl+C drueckt.

## [1.0.17] - 2026-04-15

### Changed

- **Ein einziger Desktop-Shortcut statt zwei.** Der separate
  `agentbox-update`-Shortcut (in 1.0.16 aus `agentbox-installer`
  umbenannt) ist entfallen. Begruendung: die Auto-Update-Logik in
  `wsl-ai-start.sh` kann 99% der Faelle (Script/Template/Agent-
  Updates) ohne Admin in-place erledigen — der UAC-geladene Installer-
  Rerun war damit fast immer Overkill fuer "alles schon aktuell". Ein
  Icon, ein Klick, der Rest passiert von selbst. `install.ps1` raeumt
  beide Legacy-Shortcut-Namen (`agentbox-installer.lnk` +
  `agentbox-update.lnk`) auf dem Desktop weg, und ein einmaliger
  Cleanup-Block in `wsl-ai-start.sh` macht dasselbe beim ersten Start
  nach dem Update (fuer User, die `install.ps1` nicht mehr laufen
  lassen, weil es jetzt nicht mehr noetig ist).

- **Auto-Update mit Minor/Major-Klassifizierung (`.update_class`).** Der
  Auto-Update-Flow in `wsl-ai-start.sh` liest jetzt eine neue Datei
  `.update_class` vom Repo-Root (parallel zu `.version`) und entscheidet
  damit:
  - **minor** (Default): wie bisher, silent git pull in `_control/`,
    kein User-Prompt, kein UAC, kein Admin. Alle Script-/Template-/
    Config-/CHANGELOG-Aenderungen laufen ueber diesen Pfad.
  - **major**: neuer [1]/[2]-Prompt, 10s-Timeout-Default auf [1]. Bei
    [1] wird aus dem WSL heraus via `powershell.exe -Command
    "Start-Process powershell.exe -Verb RunAs …"` ein elevated PS
    gespawnt, der die frische `install.ps1` laedt und ausfuehrt
    (gleicher Pfad wie das alte `agentbox-update`-Icon, nur halt
    bedarfsgerecht und nur wenn tatsaechlich noetig). Die aktuelle
    agentbox-Session beendet sich, User startet nach Installer-
    Abschluss erneut.
  - Bei fehlendem `.update_class` auf Remote: Default `minor`. Damit
    laufen Upgrades von Pre-1.0.17-Versionen ohne Reibung durch —
    die alte Version kennt das Flag nicht, die neue wsl-ai-start.sh
    nach dem Pull setzt die Regeln fuer kommende Updates.
  - CLAUDE.md-Eintrag als Projekt-Memory: **bei jedem Release muss
    `.update_class` bewusst gesetzt werden**. Faustregel: nur `.sh`/
    `.ps1`/`lib/`/`config.json`/Docs → minor; sobald `install.ps1` im
    Erst-Install-Pfad (Features, Kernel, Template-Struktur) geaendert
    wird → major.

- **Windows Terminal (`wt.exe`) wird Standard-Host fuer die Agent-UI.**
  Motivation: wenn man `irm … | iex` ausfuehrt und der Installer am
  Ende in-place den Agent via `wsl.exe -d agentbox-host …` startet,
  landet die Claude-Code-Fullscreen-UI im Terminal-Host der aktuellen
  PowerShell-Session. Auf alten Win10-Systemen mit ConsoleHost, in
  ISE, oder bei ungluecklichen Encoding-Konfigurationen kam es dort zu
  UTF-8-/ANSI-/Alt-Screen-Glitches (kaputte Box-Drawing-Chars, Farben
  klebten fest, Umlaut-Mojibake).
  - `install.ps1` prueft beim Erst-Install, ob `wt.exe` da ist. Wenn
    nicht: via `winget install --id Microsoft.WindowsTerminal --silent
    …` installieren. Fallback bei fehlendem winget: Warnung + der
    alte direkt-`wsl.exe`-Pfad.
  - Desktop-Shortcut `agentbox.lnk` zeigt jetzt primaer auf
    `wt.exe --title agentbox wsl.exe -d agentbox-host -e bash -li -c
    agentbox`. Fallback bei fehlendem `wt.exe`: wie bisher direkt auf
    `wsl.exe`.
  - `install.ps1` End-of-Install-Autostart lauft jetzt via
    `Start-Process wt.exe …` in einem frischen Fenster. Der Installer
    beendet sich sauber, die agentbox-Session laeuft komplett
    entkoppelt in ihrem eigenen wt-Fenster. Kein Kontext-Leak mehr,
    keine Encoding-Ueberraschungen.
  - Die `-Verb RunAs`-Fallback-Helper-Function `Set-ShortcutRunAsAdmin`
    ist aus `install.ps1` entfallen, weil sie nur fuer den alten
    Update-Shortcut gebraucht wurde (der war admin-markiert, der
    Start-Shortcut nie).

### User-facing Flow

**Tag 1 (Erst-Install auf neuer Maschine):**
1. `irm https://raw.githubusercontent.com/ChrisRudi/agentbox/main/install.ps1 | iex` in Admin-PowerShell
2. Installer laeuft: WSL-Check, evtl. `winget install Microsoft.WindowsTerminal`, Template-Build, Host-Distro-Import, EIN Desktop-Icon (`agentbox`)
3. Am Ende: neues Windows-Terminal-Fenster oeffnet sich automatisch, agentbox laeuft an, Projekt-Auswahl

**Alltag:**
1. Doppelklick auf `agentbox`-Icon
2. wt.exe oeffnet, wsl-ai-start.sh laeuft, Auto-Update-Check (24h-gated, ~1-2s wenn faellig, sonst null)
3. Projekt-Auswahl, Agent startet

**Seltenes Major-Update:**
1. Beim Start: "Neue Version 1.x.y verfuegbar [MAJOR]. [1] Jetzt aktualisieren [2] Skippen"
2. [1] → Elevated PS wird gespawnt, UAC-Prompt, Installer laeuft, User startet agentbox neu
3. Ab da wieder normaler Alltag

## [1.0.16] - 2026-04-15

### Changed

- **Update-Shortcut umbenannt: `agentbox-installer.lnk` → `agentbox-update.lnk`.**
  Inhaltlich identisch (Doppelklick → UAC → `irm … | iex`), aber der
  neue Name beschreibt besser, was der Shortcut in 99 % der Faelle
  tatsaechlich tut — Update, nicht Erst-Installation. Installer-Flow
  legt nach wie vor beide Desktop-Shortcuts an (`agentbox` zum Starten
  + `agentbox-update` zum Aktualisieren).
- **Legacy-Cleanup:** `install.ps1` loescht den alten
  `agentbox-installer.lnk` auf dem Desktop beim naechsten Update-Run,
  damit User nicht mit zwei fast-identischen Shortcuts dastehen.
  Fehler beim Loeschen werden geschluckt (Datei koennte vom User
  bereits manuell geloescht oder anderweitig im Gebrauch sein).
- **User-facing Texte angepasst:** die Reboot-Hinweise im Installer-Flow
  (nach `wsl --install`-Kernel-Update und nach dem WSL-Version-Auto-
  Update) verweisen jetzt explizit auf den `agentbox-update`-Shortcut
  am Desktop, statt generisch "agentbox-Installer-Shortcut" zu sagen.
- **Installer-Banner + Shortcut-Description:** `agentbox — Sandboxed AI
  Agent Runner` → `agentbox — Portable Sandboxed AI Agent Runner`.
  Portabilitaet ist inzwischen ein expliziter Bestandteil des Pitchs
  (siehe README-Aenderung unten), also auch in den beiden sichtbarsten
  Installer-Strings ausgewiesen.

### Docs

- **README.md + docs/README.de.md: Portabilitaet als explizites Verkaufs-
  argument.** Die Kern-Tagline ist jetzt "**Not in a portable sandbox.**
  / One command. Clean environment. Full control. Fully portable."
  (DE: "In einer portablen Sandbox nicht. / Ein Befehl. Saubere
  Umgebung. Volle Kontrolle. Komplett portabel."). Dazu ein neuer
  Abschnitt **"Built for digital nomads"** / **"Gemacht für digitale
  Nomaden"** direkt nach der Kurzbeschreibung, der die Nomad-USPs
  auflistet: one-line Install, Projekte in OneDrive/Cloud-Sync,
  Sessions sind by design disposable, neuer Rechner = eine Zeile +
  pro Agent einmal OAuth. Fokus auf den wechselnden-Rechner-Use-Case.

## [1.0.15] - 2026-04-15

### Changed

- **Agent Self-Update generalisiert: gilt jetzt fuer alle fuenf Agents,
  nicht mehr nur Claude Code (Folgearbeit zum 1.0.14-Fix).** Strukturell
  haben alle Agents (claude/codex/gemini/aider/goose) das gleiche
  EACCES-Problem mit ihren eingebauten Self-Updatern, weil sie alle im
  Template-Build als root in `/usr/lib/node_modules` (npm) bzw.
  `/usr/lib/python3/dist-packages` (pip) installiert werden, zur
  Sandbox-Laufzeit aber als unprivilegierter `$SANDBOX_USER` laufen.
  1.0.14 hatte nur Claude Code abgedeckt, weil das der einzige aktuell
  gemeldete Fall war — die anderen waren damit aber nicht fixed,
  sondern nur "noch nicht hochgekommen".

  Generalisierung in `wsl-sandbox-init.sh::_run_agent_update`:
  - Funktioniert jetzt agent-agnostisch ueber alle fuenf Agents.
  - Backend (npm vs. pip) und Package-Name werden aus `AGENT_INSTALL`
    geparst (siehe Parsing-Beispiele im Code-Kommentar). Respektiert
    `@scope/pkg@version` (npm scoped), `pkg@version` (npm unscoped) und
    `pkg==version` (pip).
  - Versions-Check-Backend per Type:
    - npm → `npm view <pkg> version`
    - pip → `pip3 index versions <pkg>` mit Fallback ueber die PyPI-
      JSON-API (`/pypi/<pkg>/json`), weil `pip index versions` je nach
      pip-Version eine Pre-Release-API ist und nicht garantiert greift.
  - Install-Command wird vom Host als `AGENT_INSTALL` durchgereicht
    statt im Sandbox-Script hardcoded — damit respektiert das Update
    User-Customisations in `config.json` (z.B. private Registry,
    Version-Pin).

  Aenderungen am Param-Vertrag:
  - `wsl-sandbox-init.sh` nimmt jetzt einen 9. Parameter `AGENT_INSTALL`
    entgegen (leerer String = Update-Check skippen).
  - `wsl-ai-start.sh::_load_enabled_agents` traegt zusaetzlich `agent_ids`
    nach (analog zu `agents` und `agent_cmds`), damit nach der Agent-
    Auswahl der Install-Command per `cfg_get "agent_<id>_install"`
    aufgeloest werden kann.
  - Beide Branches der Agent-Auswahl (Auto-Select bei einem aktiven
    Agent, manuelle Auswahl) setzen `AGENT_ID`, danach wird einmal
    `AGENT_INSTALL` aufgeloest und an `wsl-sandbox-init.sh` weiter-
    gereicht.

  Backwards-Compat: wenn jemand das neue `wsl-sandbox-init.sh` mit
  einem alten `wsl-ai-start.sh` kombiniert (8 Params), bleibt
  `AGENT_INSTALL` leer, der Update-Check wird stillschweigend
  uebersprungen, der Agent startet wie bisher. Kein Crash.

## [1.0.14] - 2026-04-15

### Fixed

- **Claude Code Auto-Update schlug im Sandbox fehl ("✗ Auto-update
  failed · Try claude doctor or npm i -g @anthropic-ai/claude-code").**
  Architektur-Mismatch zwischen Template-Build und Sandbox-Run:
  - Template-Build (`win-setup-core.ps1:453`) installiert Claude Code
    via `npm install -g @anthropic-ai/claude-code@latest` als **root**.
    Liegt damit unter `/usr/lib/node_modules/@anthropic-ai/claude-code/`
    mit `root:root`.
  - Sandbox-Run (`wsl-sandbox-init.sh:515`) startet den Agent als
    unprivilegierter `$SANDBOX_USER`.
  - Claude Code's eingebauter Self-Updater versucht im Hintergrund
    `npm install -g ...` → schreibt auf root-owned Pfad → **EACCES**
    → Fehlermeldung im Agent.

  "Manchmal", weil der Updater nur dann anschlaegt, wenn Anthropic eine
  neue Version released hat — die meisten Sessions sind schon aktuell,
  deshalb nur ab und zu sichtbar.

  Fix in `wsl-sandbox-init.sh`: Update-Schritt **als root uebernehmen**,
  bevor auf den Sandbox-User gewechselt wird. Damit sind die Permissions
  egal und Claude Code's Self-Updater hat zur Agent-Startzeit nichts
  mehr zu tun. Implementation:
  - Billiger Versions-Vergleich (`claude --version` lokal vs.
    `npm view @anthropic-ai/claude-code version` remote, ~2s).
  - Teures `npm install -g` nur wenn local und remote tatsaechlich diff
    (was praktisch immer beim ersten Sandbox-Start nach einem Anthropic-
    Release passiert, weil das gecachte Template noch die alte Version
    ausliefert).
  - **Bewusst ohne Skip-Marker:** jeder Sandbox-Start importiert die
    Distro frisch aus dem gecachten Template, also ist die installierte
    Claude-Code-Version immer der Stand des letzten Template-Builds.
    Eine 24h-Skip-Logik wuerde fast jede Session auf einer veralteten
    Version laufen lassen, statt sie zu verhindern.
  - Steady-state-Overhead pro Session: ~2s. Bei tatsaechlich faelligem
    Update: ~10-30s einmalig.
  - Lauft vor dem `su - $SANDBOX_USER` und nach den iptables-Regeln,
    d.h. das `npm install` muss durch genau dieselben Firewall-Rules
    raus wie der Agent spaeter — ist aber unkritisch, weil
    `registry.npmjs.org` ueber HTTPS/443 zu public IPs erreichbar ist
    und damit unter die "alle non-private Routen erlauben"-Regel faellt.
  - Non-Claude-Agents (codex/gemini/aider/goose) bleiben am bisherigen
    Verhalten (nur Version anzeigen, kein Auto-Update). Wenn dieselbe
    Update-Failure dort auftritt, kann der Block analog erweitert
    werden — fuer jetzt scope-genau am User-Report gehalten.

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
