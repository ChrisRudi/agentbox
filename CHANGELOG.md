# Changelog

All notable changes to agentbox are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.2.14] - 2026-04-18

### Added -- Default-Build-Command fuer type=powershell: build.ps1

Parallel zu `npm run build` (node) und `pip install -r requirements.txt`
(python) bekommt `type=powershell` jetzt einen konventions-basierten
Default-Build-Command: `powershell -NoProfile -ExecutionPolicy Bypass
-File build.ps1`. Wer ein neues PS-Projekt anlegt, legt einfach eine
`build.ps1` im Projekt-Root ab, und der Task-Runner feuert die beim
`[3] Benchmark ausfuehren`-Trigger. Kein Config-Gefummel mehr, kein
expliziter build.command in project.json noetig.

Geaenderte Dateien:

- `type_defaults.json`: powershell-Default von `build: null` auf
  build-Command + output_dir "build_out"
- `config.json`: neuer Whitelist-Eintrag (parallel zum existierenden
  bench.ps1-Eintrag aus 2.2.0)
- `win-task-runner.ps1`: Inline-Fallback-Whitelist um denselben
  Eintrag ergaenzt, damit die Runner-Logik auch ohne config.json-Read
  den Command akzeptiert
- `README.md` + `docs/README.de.md`: Auto-Detect-Tabelle zeigt jetzt
  `powershell -File build.ps1` statt `-` in der powershell-Zeile

Whitelist-Semantik bleibt **exakt-match, kein Wildcard, kein Prefix**
(CLAUDE.md-Regel). Der neue Eintrag ist ein fester String wie jeder
andere Whitelist-Eintrag -- die Konvention lebt ausschliesslich ueber
den Datei-Namen `build.ps1`, nicht ueber Pattern-Matching in der
Whitelist.

Bestehende Projekte (inkl. demo-benchmark, das `bench.ps1` direkt
nennt) sind unberuehrt: ihre project.json-Entries ueberschreiben den
Default.

## [2.2.13] - 2026-04-18

### Removed -- Historischer Kontext-Kommentar in Invoke-BuildAction

Der 12-Zeilen-Kommentarblock aus 2.2.11, der die cmd-chain-Historie +
den Parser-Landmine-Fix dokumentierte, ist raus. Nach dem erfolgreichen
End-to-End-Test beim User (Runner parst, 3 pending Tasks abgearbeitet,
bench.ps1 feuert durch) wird die Historie nicht mehr im Code benoetigt
-- sie steht im CHANGELOG (2.2.3, 2.2.11, 2.2.12). Im Code spricht der
direkte Start-Process-Aufruf fuer sich.

## [2.2.12] - 2026-04-18

### Fixed -- win-task-runner.ps1: non-ASCII chars (em-dash, arrow) brechen PS 5.1 Parser

Direkte Folge von 2.2.11: nachdem der `&&`-Kommentar-Landmine beseitigt
war, kam der Parser ein paar Zeilen weiter und fiel ueber den naechsten
Landmine -- die em-dashes (U+2014) in Write-Log-Messages und Comments.
Auf der Windows-Seite beim User liest PS 5.1 die Datei als ANSI/CP850,
die UTF-8-Em-Dash-Bytes (0xE2 0x80 0x94) werden als drei kaputte Zeichen
dekodiert, das verschiebt Tokenizer-Positionen und kaskadiert in Folge-
Zeilen. Konsequenz: wieder Exit-Code 1, diesmal am `"github" {` und
Closing-Brace.

**Fix:** in win-task-runner.ps1 alle non-ASCII chars durch ASCII-
Aequivalente ersetzt:
- Em-Dash `--` (zweimal Minus) statt `—` (10 Vorkommen: log-Messages,
  Comments)
- Arrow `->` statt `→` (2 Vorkommen in Comments)

Entspricht der laengst etablierten CLAUDE.md-Regel "ASCII-only in PS
5.1" -- die Regel existierte seit 1.0.9, wurde aber in win-task-runner.ps1
nicht konsequent durchgezogen. 2.2.3 hatte die cmd-chain-Brueche
gefixt, 2.2.11 den `&&`-Kommentar, 2.2.12 jetzt den Encoding-Rest.
Damit sollte der Parser-Crash-Landmine-Bestand abgeraeumt sein.

**Noch offen (NICHT in diesem Release):** install.ps1, win-setup-core.ps1,
win-setup.ps1, lib/config.ps1 enthalten ebenfalls non-ASCII chars. Die
werden aber vom install-Flow gehandelt, nicht vom Scheduled Task, und
haben keine User-Reports getriggert. Separate Putz-Aktion, wenn sich
jemand ueber Drift dort aergert.

**Deployment:** wie 2.2.11 -- reines Script-Update, kein Admin-Rerun
noetig. Naechster Session-Start pullt, pending Tasks in
demo-benchmark/_tasks/ werden abgearbeitet.

## [2.2.11] - 2026-04-18

### Fixed -- win-task-runner.ps1: Parser-Landmine im Kommentarblock der Invoke-BuildAction

Task-Runner starb seit 2.2.3 **konsistent mit Exit-Code 1 beim Parser-
Tokenize**, nicht im aktiven Code. Symptom beim User: blauer PowerShell-
Flash beim Trigger, aber keinerlei EventLog-Eintraege 1001/1002/1003,
pending Tasks stapeln sich in `_tasks/`, `_control/history/` bleibt
leer. diagnose.ps1 (2.2.10) hat das in 10 Sekunden lokalisiert.

**Root Cause:** Die in 2.2.3 hinzugefuegten Erklaer-Kommentare ueber
dem Start-Process-Aufruf enthielten den Bug-Trigger, den sie dokumen-
tieren sollten:

```
# PS 5.1 parset den vorher verwendeten Ausdruck
#   "cd /d <backtick>"$ProjectDir<backtick>" && $buildCmd"  <-- hier
# nicht korrekt -- trotz Backtick-Escape bricht der Parser am <backtick>&&<backtick>
```

Die `&&` zwischen Backticks sind eigentlich in einem `#`-Kommentar und
sollten vom Parser ignoriert werden. PS 5.1 hat aber einen Tokenizer-
Bug mit diesem speziellen Muster: Backticks gelten als Line-Continuation,
der Comment-Scope wird dadurch unklar gescopet, und das darin eingebet-
tete `&&` wird als Token `Das Token "&&" ist kein gueltiges
Anweisungstrennzeichen` geflagt. Der Tokenizer kaskadiert danach in
alle folgenden Zeilen (Function-Definitionen, switch-case, Closing-
Braces), die Datei wird als Ganzes als nicht parsebar verworfen, Exit-
Code 1 ohne jede Ausgabe.

Der 2.2.3-Fix damals hatte nur den aktiven Code fixgestellt (von cmd-
chain auf Start-Process umgestellt), die Erklaer-Kommentare darueber
aber unveraendert gelassen. Genau die Zeilen, die "so macht man es
NICHT" dokumentieren, waren selber der Bug-Trigger. Klassischer
schlafender Landmine ueber 8 Releases, weil auf Entwicklerseite (und
in der Codex-CI-Umgebung) der File mit UTF-8 BOM oder in PS 7 geparst
wird, wo der Bug nicht greift.

**Fix:** Kommentarblock so umformuliert, dass weder `&&` noch
Backtick-Escapes enthalten sind. Text paraphrasiert auf rein
beschreibende Sprache ("cmd-Operator-Zeichen", "die beiden Ampersands"),
historische Begruendung bleibt erhalten.

**Deployment-Pfad zum User:** reines Script-Update, kein Template-
Rebuild noetig, kein `install.ps1`-Admin-Rerun noetig. Der naechste
agentbox-Session-Start zieht das Update via Auto-Check in
`wsl-ai-start.sh`. Alternativ manuell:

```
irm https://raw.githubusercontent.com/ChrisRudi/agentbox/main/install.ps1 | iex
```

Nach dem Update: pending Tasks in `demo-benchmark/_tasks/` werden beim
naechsten Trigger oder AtLogon-Sweep abgearbeitet. `.update_class`
bleibt `minor`.

## [2.2.10] - 2026-04-18

### Added -- diagnose.ps1: Host-Side Diagnose fuer den Task-Runner-Flow

Neues Repo-Root-Skript `diagnose.ps1`, das die komplette Kette vom
Trigger-Event bis zum Bench-Output in einem Durchlauf pruefen laesst.
Motivation: wenn der `[3] Benchmark ausfuehren`-Menu-Punkt nur ein
blaues PowerShell-Fenster kurz aufploppen laesst und nichts passiert,
war es bisher frickelig zu lokalisieren, an welcher der vier Schichten
(Scheduled Task -> Event-Source -> config.json-Whitelist ->
project.json build.command -> Dateien im demo-benchmark-Ordner) der
Bruch ist.

Gecheckt werden in Reihenfolge:

1. Scheduled Task: existiert, Action ruft win-task-runner.ps1 mit
   -once + -WindowStyle Hidden auf, WorkingDirectory, Event-Trigger
   auf EventID 2000, AtLogon-Safety-Net, LastRunTime, LastTaskResult.
2. Event-Source `AIProjects` registriert.
3. config.json parsebar, build_whitelist enthaelt den exakten
   `powershell -NoProfile -ExecutionPolicy Bypass -File bench.ps1`-
   Eintrag.
4. win-task-runner.ps1 am erwarteten Speicherort.
5. demo-benchmark-Ordner geseedet (bench.ps1, bench.sh, project.json).
6. project.json:build.command matcht Whitelist **exakt** (char-by-char)
   -- der haeufigste Stolperstein bei Whitelist-Drift.
7. Pending Tasks in demo-benchmark/_tasks + letzter status_build.json.
8. _control/history: letzte 5 failed Tasks mit Error-Message.
9. Letzte 10 Application-Events von Source AIProjects (2000/1001/1002/
   1003 farbcodiert nach Rolle).
10. bench-results.json parsebar + .host / .agentbox_host Keys + Alter
    der index.html.
11. .version + .update_class sanity.

Output farbcodiert [OK]/[WARN]/[FAIL], am Ende Summary-Zeile und
Exit-Code (0 wenn alle OK, 1 bei >=1 FAIL). PS 5.1 kompatibel (keine
Here-Strings, kein `New-Item -LiteralPath`, ASCII-only) wie die Regel
in CLAUDE.md.

Aufruf:

```
powershell -NoProfile -ExecutionPolicy Bypass -File _control\diagnose.ps1
```

Laeuft vollstaendig im User-Kontext, braucht keine Admin-Rechte.

## [2.2.9] - 2026-04-18

### Changed -- Performance-Section im README: Verhaeltnisse statt Absolutwerte

Die README.md verkaufte bisher Sicherheit + Portabilitaet, aber nicht
den realen Performance-Vorsprung von WSL-on-vhdx gegenueber dem
Windows-Host. Der 2026-04-18-Bench aus `demo-benchmark/` zeigt
Disk-seq-write **18.7x**, Process-spawn **17.3x**, Disk-small-files
**9.1x** — das sind Headline-Zahlen, die mit rein muessen.

Einordnung / bewusste Design-Entscheidungen:

- **Nur Verhaeltnisse, keine Absolutwerte** im README. MB/s-Zahlen
  haengen an Hardware, altern schlecht und laden zu Zahlen-Klauberei
  ein ("aber mein Rechner macht nur 200 MB/s"). Ratios bleiben ueber
  typische Laptop-SSDs hinweg relativ stabil, weil die Ueberlegenheit
  strukturell ist (ext4 vs DrvFs, Linux fork/exec vs CreateProcess).
- **"Wirkungsgrad"-Spaltenueberschrift entfaellt**, weil der Ratio-
  Wert schon die Aussage ist. Kein Prozent-Theater mit 1867.8 %, nur
  `18.7x`.
- **Beide READMEs parallel** gepflegt (`README.md` + `docs/README.de.md`)
  mit identischer Ratio-Tabelle.
- **`tools/CLAUDE.md` als Engineering-Anker**: dort stehen weiterhin
  die Absolutwerte plus Ratio-Spalte als Referenz-Snapshot, damit ein
  Agent, der `bench.sh` anfasst, Regressionen an der eigenen Messung
  erkennt (500 MB/s sequentiell plausibel? 50 MB/s schon verdaechtig).
- **Ehrliches Framing beibehalten**: im README steht explizit, dass
  der gemessene WSL-Wert die **ungetunte** persistente Host-Distro
  (`agentbox_host`) ist. Die ephemere Session-Sandbox mit BBR,
  dnsmasq, ext4-Overlays liegt typischerweise noch hoeher — das
  staerkt die Aussage, statt sie zu schwaechen.
- **Keine neue Datei** (kein `BENCHMARKS.md`): Werbung gehoert an die
  Verkaufsflaeche, nicht in eine Seitendatei.

Position im README: direkt nach `### Built for digital nomads`, vor
`## Supported Agents`. So sieht ein Leser erst die Sicherheits-These
(Intro), dann Portabilitaet (Nomads), dann Performance, und erst
danach die Feature-Liste.

Keine Code-Aenderung, keine Bench-Script-Aenderung, kein
Template-Rebuild — reine Doku-Arbeit. Deshalb `.update_class=minor`.

## [2.2.8] - 2026-04-18

### Fixed -- PS 5.1 Parser-Bug in bench.ps1 HTML here-string ($var:)

User-Report: bench.ps1 lief beim Direkt-Aufruf nicht durch, Parser-
Fehler:
```
Ungueltiger Variablenverweis. Nach ":" folgte kein Zeichen, das fuer
einen Variablennamen gueltig ist.
In Zeile:295 Zeichen:75
+ Host: $host_stamp_txt &nbsp;|&nbsp; $wsl_label: $wsl_stamp_txt
                                      ~~~~~~~~~~~
```

Ursache: PS 5.1 (und PS 7) interpretieren `$foo:` in einem Double-
Quoted String als drive-scoped Variable (analog zu `$env:PATH` oder
`$global:x`). Weil `wsl_label` keinem bekannten Scope/Drive entspricht,
schlaegt der Parser zu.

Fix: `${wsl_label}:` mit explizitem Delimiter. Das zwingt den Parser,
nur `wsl_label` als Variablennamen zu nehmen und den Doppelpunkt
literal zu behandeln. `BENCH_VERSION` bump 3.0.2 -> 3.0.3.

Dieser Bug war nur in der 2.2.7-Fassung von bench.ps1 vorhanden --
v3.0.0 hatte das Label-Feld noch hardcoded "Sandbox:" ohne Variable,
deshalb kein Parse-Error. User sah den Bug erst, als die neue v3.0.2
per manuellem Copy-Item in sein demo-benchmark/ gewandert ist.

## [2.2.7] - 2026-04-18

### Changed -- Ehrliche Labels: bench-Spalte "sandbox" ist eigentlich "agentbox_host"

Beim User-Wunsch, auch eine Default-WSL-Distro mitzubenchmarken, fiel
auf: die bisherige "Sandbox"-Spalte misst gar nicht die ephemere
session-getunte Sandbox. Das Config-Submenue `[3] Benchmark ausfuehren`
laeuft aus der persistenten Host-Distro `agentbox-host` heraus --
**bevor** eine Agent-Session die ephemere Sandbox ueberhaupt importiert
und per `wsl-sandbox-init.sh` mit ext4-Overlay, BBR, dnsmasq-Cache
getuned hat. Die in den Tests gezeigten Zahlen sind also von
agentbox-host (Template + Sysctl), nicht von der session-getunten
Sandbox. Misleading.

Fix (Option A aus der Diskussion mit dem User):

- `bench.sh` bekommt eine neue Env-Variable **`BENCH_PLATFORM`**
  (Default `agentbox_host`). Der JSON-Schluessel und das `"platform"`-
  Feld in `bench-results.json` werden daraus abgeleitet. `BENCH_VERSION`
  bump 3.0.1 -> 3.0.2.
- `wsl-ai-start.sh _run_benchmark_menu` ruft jetzt
  `BENCH_PLATFORM=agentbox_host BENCH_OUT=... bash bench.sh`. Menu-Text
  entsprechend: "agentbox-host-Seite messen... Schluessel .agentbox_host".
- `bench.ps1` liest jetzt `.agentbox_host` primaer, faellt auf
  `.sandbox` zurueck fuer alte JSON-Dateien aus 3.0.x-Versuchen. HTML-
  Spaltenheader + Legende adaptieren sich an das `"platform"`-Feld aus
  der JSON (mit Fallback `agentbox-host`). Zusatz-Zeile in der Legende
  erklaert ehrlich, was gemessen wurde (Template + Sysctl, keine
  Session-Tunings).
- `bench.ps1`-Merge-Logik preserviert jetzt alle nicht-`host`-Keys im
  JSON, nicht nur `.sandbox`. Damit bleibt Platz fuer spaetere Keys
  (`.sandbox`, `.default_wsl`) ohne Code-Aenderung an dem Merge-Block.

### Future-Ready fuer echte Sandbox-Messung

`BENCH_PLATFORM` ist bewusst parametrisierbar. Ein spaeteres Feature
"`[4] Benchmark inkl. tuned Sandbox`" koennte `bench.sh` aus einer
frisch-importierten, session-getunten Sandbox heraus mit
`BENCH_PLATFORM=sandbox` aufrufen -- das landet neben `.agentbox_host`
unter `.sandbox` in derselben JSON. `bench.ps1` rendert dann 3 Spalten
(Host, agentbox-host, sandbox) -- kein Code-Aufwand beim HTML-Generator,
nur Zeilen-Layout anpassen.

Diese Erweiterung ist als Follow-up dokumentiert, nicht in 2.2.7
implementiert. Ein User-Aufruf "mit der Hand" laeuft schon jetzt:
```
BENCH_PLATFORM=sandbox BENCH_OUT=... bash bench.sh
```
aus jeder beliebigen WSL-Distro -- das HTML zeigt die Zahlen dann als
"sandbox"-Spalte.

### Docs

`tools/CLAUDE.md` + Root-`CLAUDE.md` umgeschrieben: ehrliche Benennung,
erklaert `BENCH_PLATFORM`, listet moegliche zukuenftige Keys
(`sandbox`, `default_wsl`). JSON-Schema-Beispiel aktualisiert auf 3.0.2
+ `agentbox_host` als Key-Name.

## [2.2.6] - 2026-04-18

### Changed -- bench.ps1 Wirkungsgrad-Formel: Sandbox / Host (statt host / sandbox)

User-Request: "Auch die Formel im HTML aendern: Wirkungsgrad = Sandbox
/ Host x 100 %".

Alte Formel in `tools/bench.ps1 Ratio()`: `host / sandbox`, gedeckelt
auf 100 %. Problem: wenn die Sandbox _schneller_ war als der Host
(ext4 in vhdx bei Small-Files-I/O deutlich ueber DrvFs/NTFS), gab es
`h/s < 1` und damit `< 100 %` -- das Tool zeigte einen schwaecheren
Wert gerade dann, wenn die Sandbox den Host schlug. Die obere Deckelung
auf 100 % kaschierte das bei langsamen Sandbox-Runs, aber der
Umkehr-Fall war falsch.

Neue Formel: `sandbox / host * 100 %`, **ohne Deckelung**. Damit:
- Sandbox = Host -> 100 %
- Sandbox doppelt so schnell wie Host -> 200 %
- Sandbox halb so schnell -> 50 %

Farb-Schwellen in `Pct()` bleiben gleich (>=100 gruen, >=50 gelb, sonst
rot) -- die Semantik passt jetzt erst wirklich zum agentbox-Selling-
Point: "ext4-in-vhdx schlaegt DrvFs, das sieht man beim Small-Files-
Test und beim Process-Spawn in 2-3x-Wirkungsgrad".

HTML-Footer-Text entsprechend angepasst. `BENCH_VERSION` bump auf 3.0.1
in beiden Scripts.

### Changed -- Seed-AgentboxDemoBenchmark unterscheidet jetzt Source vs. Config

Bei `install.ps1`-Rerun wurden bisher alle vorhandenen Dateien in
`demo-benchmark/` unberuehrt gelassen (Copy-only-if-missing). Das ist
richtig fuer User-Config (`project.json`, `CLAUDE.md`), aber falsch
fuer die Source-Scripts (`bench.ps1`, `bench.sh`, `index.html`) --
Bug-Fixes oder Formel-Updates im Repo erreichten den User nie.

Ab jetzt:
- `bench.ps1`, `bench.sh`, `index.html`: **immer overwriten**
  (Source-of-truth liegt im Repo, wird bei jedem Install-Rerun
  propagiert).
- `project.json`, `tools/CLAUDE.md`: **nur wenn fehlend** kopieren
  (User-Modifikationen bleiben).
- `bench-results.json`: weiterhin exkludiert (Runtime-State).

Damit bekommt der 2.2.6-Formel-Fix beim Rerun auch wirklich Wirkung
und landet in der User-Kopie.

## [2.2.5] - 2026-04-18

### Changed -- Task-Runner-Architektur: Watch-Daemon -> EventLog-Trigger

User-Vorschlag nach dem Trouble mit dem 2.2.1-Watch-Daemon:
> "warum daemon das geht ja viel eleganter: Ein Windows-Eventtrigger
> startet Aktionen basierend auf Protokollereignissen in der
> Ereignisanzeige, konfigurierbar ueber die Aufgabenplanung"

Zustimmung. Der Watch-Daemon hatte mehrere Nachteile:
- Long-running Process, Keepalive-Problem, Restart-Logik.
- FileSystemWatcher auf OneDrive-Folder unzuverlaessig (DrvFs/Reparse-
  Points vs. Event-Propagation).
- Debug-schwierig -- keine Logs wenn Daemon still crasht.

Neue Architektur:

1. **Scheduled Task** `agentbox-task-runner` laeuft wieder als `-once`
   (kein Daemon). Zwei Trigger parallel registriert:
   - **EventLog-Subscription**: feuert bei jedem Event mit
     `Source='AIProjects'` + `EventID=2000`. CIM-basiert
     (`MSFT_TaskEventTrigger`) weil PS 5.1 Keine direkten
     Event-Trigger-Cmdlets hat.
   - **AtLogon-Sweep**: Safety-Net fuer Tasks, die waehrend System-Off
     queued wurden. Drained den Backlog, dann sauberer Exit.
2. **wsl-ai-start.sh `_run_benchmark_menu`** emittiert nach dem
   Task-File-Write ein Trigger-Event via `powershell.exe`-Interop:
   ```
   powershell.exe Write-EventLog -LogName Application `
       -Source AIProjects -EventId 2000 `
       -EntryType Information -Message "..."
   ```
   Keine Admin-Rechte noetig (Source existiert schon), Write-EventLog
   auf bestehende Source ist fuer normale User erlaubt.
3. **Task Scheduler** startet den Runner innerhalb von ~1s nach dem
   Event. `-once`-Mode: Process-AllTasks sweep, dann exit. Kein
   persistent Process, kein FileSystemWatcher-Risiko, lazy Execution.
4. **MultipleInstances=Queue**: zwei schnell hintereinander gefeuerte
   Events fuehren zu zwei Runs nacheinander, damit keine Task-Files
   verloren gehen.

### Audit-Trail

Event-Log > Application > Source `AIProjects`:
- **2000**: getriggert (von wsl-ai-start.sh oder Agent)
- **1001**: Task gestartet (vom Runner)
- **1002**: Task erledigt
- **1003**: Task fehlgeschlagen

### Hotfix-Kette 2.2.0-2.2.4 auflaufen lassen

Der Weg bis hier war ein Debug-Marathon: 2.2.0 (-once ohne Trigger),
2.2.1 (Watch-Daemon-Versuch), 2.2.2 (Seed-Reihenfolge), 2.2.3 (PS 5.1
Parse-Bug am &&), 2.2.4 ($MyInvocation-Fallback). Alles Fixes, aber auf
falschem Architektur-Fundament. 2.2.5 ist der Architektur-Rewrite, der
die Probleme an der Wurzel packt -- kein Daemon, keine Watcher, nur
Event-basiertes Lazy-Scheduling wie von Task Scheduler selbst angeboten.

### Migration

- `.update_class` bleibt **major**. Installer-Rerun noetig fuer
  Task-Re-Register mit neuen Triggern.
- Nach Rerun: AtLogon-Sweep verarbeitet alle angesammelten Task-Files
  aus den 2.2.x-Versuchen. Wahrscheinlich bekommt der User mehrere
  Browser-Fenster nacheinander -- danach ist der Queue leer.
- `[3] Benchmark ausfuehren` loest ab jetzt den Host-Build binnen ~1s
  nach Menu-Auswahl aus.

## [2.2.4] - 2026-04-18

### Fixed -- win-task-runner.ps1 Default-Mode Self-Invoke-Crash

Nach 2.2.3 (Parse-Error gefixt) zeigte sich der naechste pre-existing
Bug: wenn der Script ohne `-once`/`-watch`-Arg aufgerufen wird (z.B.
direkt per `& '<path>\win-task-runner.ps1'`), loeste die Default-Branch
am Ende via `& $MyInvocation.MyCommand.Path -watch` einen Self-Invoke
aus. In manchen Aufruf-Kontexten ist `$MyInvocation.MyCommand.Path`
unter PS 5.1 jedoch `$null` -- Ergebnis:

```
Der Ausdruck nach "&" in einem Pipelineelement hat ein ungueltiges
Objekt erzeugt. Der Ausdruck muss einen Befehlsnamen, Skriptblock
oder ein CommandInfo-Objekt ergeben.
```

Fix: Self-Invoke entfernt. Wenn weder `-once` noch `-watch` gesetzt
ist, wird `$watch = $true` direkt gesetzt und der Script laeuft inline
im Watch-Modus weiter. Kein Subprozess, kein `$MyInvocation`-Grenzfall.

Der Scheduled Task uebergibt sowieso explizit `-watch`, aber der
manuelle Aufruf (`powershell -File ...\win-task-runner.ps1`) ohne Args
funktioniert jetzt auch sauber -- der Daemon startet und der Usage-
Hinweis wird als Zeile gezeigt, ohne Re-Exec-Crash.

## [2.2.3] - 2026-04-18

### Fixed -- PS 5.1 Parse-Error in `win-task-runner.ps1:233` (Invoke-BuildAction)

Diagnose des Users nach 2.2.2-Rerun: Scheduled Task-State = "Ready",
keine Events im Task-Scheduler-Log, kein PS-Prozess. Manueller Start
von `win-task-runner.ps1 -once` zeigte die Ursache direkt:

```
Das Token "&&" ist in dieser Version kein gueltiges Anweisungstrennzeichen.
   -ArgumentList "/c", "cd /d `"$ProjectDir`" && $buildCmd" `
                                              ~~
```

PS 5.1 bricht an dem Backtick-escapten String aus und parset `&&` als
Operator. Das ist ein pre-existing Bug -- schon vor 2.2.0 da, aber nie
getriggert weil der alte `-once`-Task offenbar nie wirklich lief (oder
lief nur wenn PS 7 als Default aktiv war). Mit dem neuen Watch-Daemon
lud PS 5.1 den Script-Inhalt beim Task-Start, scheiterte am Parse, und
beendete sich sofort -- daher Task immer in "Ready"-State, keine Events
im Task-Scheduler-Log (Task startete nie erfolgreich).

Fix in `Invoke-BuildAction`:

```powershell
# vorher
Start-Process -FilePath "cmd.exe" `
    -ArgumentList "/c", "cd /d `"$ProjectDir`" && $buildCmd" `
    -Wait -NoNewWindow -PassThru

# nachher
Start-Process -FilePath "cmd.exe" `
    -ArgumentList "/c", $buildCmd `
    -WorkingDirectory $ProjectDir `
    -Wait -NoNewWindow -PassThru
```

Kein `&&`-Chain mehr. Start-Process setzt die CWD ueber das
`-WorkingDirectory`-Parameter, cmd.exe /c bekommt nur den reinen
Build-Command. Kein Backtick-Escape-Grenzfall mehr.

### Migration

- `.update_class` bleibt **major**. Installer-Rerun ist Pflicht.
- Nach Rerun: Daemon startet erfolgreich (Script ist parsbar), Task
  geht auf "Running"-State. Initial-Sweep `Process-AllTasks` verarbeitet
  **alle angesammelten Task-Files** aus den 2.2.0/2.2.1/2.2.2-Versuchen.
  User bekommt beim ersten Daemon-Start einen Schwall HTML-Browser-
  Fenster (eins pro queued Task-File) -- danach ist der Queue leer und
  [3] Benchmark laeuft live.

## [2.2.2] - 2026-04-18

### Fixed -- Seed-Reihenfolge: demo-benchmark VOR Task-Runner-Registrierung

User-Report nach 2.2.1-Fix: "Audit-Trail Event-Log Application Source
AIProjects keine Eintraege obwohl ich [3] Benchmark ausfuehren gemacht
habe und vorher neu installiert."

Root Cause: Race Condition in `win-setup-core.ps1`. `Register-AgentboxTaskRunner`
lief VOR `Seed-AgentboxDemoBenchmark` (beide Install-Pfade). Der 2.2.1-
Watch-Daemon startet sofort via `Start-ScheduledTask` und enumeriert die
Projekt-Verzeichnisse **einmalig** in `win-task-runner.ps1:441-444`
(`Get-ChildItem -LiteralPath $baseDir -Directory`). Zu diesem Zeitpunkt
existierte `demo-benchmark/` noch nicht -- der Daemon setzte keinen
FileSystemWatcher auf `demo-benchmark/_tasks/`. Folge: Task-Files aus dem
Benchmark-Menue-Handler landen im Ordner, niemand greift sie auf, kein
EventLog-Audit, kein Host-Build.

Fix: Aufruf-Reihenfolge getauscht. In beiden Install-Pfaden
(Skip-Build und Full-Build) laeuft `Seed-AgentboxDemoBenchmark` jetzt
**vor** `Register-AgentboxTaskRunner`. Der Daemon sieht beim Start das
existierende `demo-benchmark/`-Projekt, setzt den FileSystemWatcher auf
`_tasks/` und verarbeitet Benchmark-Task-Files live.

Kommentar am `Seed-AgentboxDemoBenchmark`-Funktionsprototyp entsprechend
korrigiert (war: "nach Register", jetzt: "vor Register mit Begruendung").

### Migration

- `.update_class` bleibt **major**. Installer-Rerun ist Pflicht: der
  Daemon muss mit der neuen Projekt-Liste neu starten. Durch
  `Stop-ScheduledTask`+`Unregister-ScheduledTask` in
  `Register-AgentboxTaskRunner` (2.2.1) wird der alte Daemon sauber
  beendet, bevor der neue hochfaehrt.
- **Task-Files aus fruehem 2.2.1-Versuch** liegen evtl. noch in
  `demo-benchmark/_tasks/`. Beim naechsten Daemon-Start werden sie durch
  den Initial-Sweep (`Process-AllTasks` in `win-task-runner.ps1:439`)
  aufgegriffen und verarbeitet.

## [2.2.1] - 2026-04-18

### Fixed -- Scheduled Task `agentbox-task-runner` laeuft jetzt als Daemon (watch statt once)

Die 2.2.0-Doku behauptete, der Scheduled Task laufe im `-watch`-Modus
als FileSystemWatcher-Daemon und greife Task-Files live auf. Tatsaechlich
war er mit `-once` registriert (`win-setup-core.ps1:160`), lief also nur
einmal bei Logon, verarbeitete bereits queued Tasks und beendete sich.

Konsequenz fuer den 2.2.0 Benchmark-Flow: Config-Menue `[3] Benchmark
ausfuehren` schrieb zwar korrekt ein Task-JSON in
`demo-benchmark/_tasks/`, aber niemand hat es aufgegriffen -- kein
Host-Build, kein `bench.ps1`-Run, kein HTML, kein Browser. Erst beim
naechsten Logon waere die Datei verarbeitet worden. User-Report:
"[3] Benchmark geht in WSL, aber dachte es triggert auch build und das
Powershell und zeigt am Schluss das html?"

Fix in `Register-AgentboxTaskRunner` (`win-setup-core.ps1:141-169`):

- **Argument-Switch** `-once` -> `-watch`. Der Daemon laeuft ab Logon
  dauerhaft mit FileSystemWatcher auf `<project>/_tasks/*.json` und
  verarbeitet neue Tasks innerhalb von ~500ms.
- **`-WindowStyle Hidden`** zusaetzlich, damit kein Console-Fenster beim
  Logon blitzt.
- **`-ExecutionTimeLimit` = 0** (`New-TimeSpan -Seconds 0`). Ohne diesen
  Setter killt Task Scheduler den Prozess nach Default-3-Tagen. Fuer
  einen Daemon toedlich.
- **`-MultipleInstances IgnoreNew`**: bei einem zweiten Logon-Trigger
  wird kein zweiter Daemon hochgefahren, solange der erste laeuft.
- **Restart-on-Crash**: `-RestartCount 3 -RestartInterval 1min`. Wenn der
  Daemon stirbt, probiert Task Scheduler dreimal im 1-Minuten-Abstand
  neu zu starten.
- **Stop-ScheduledTask vor Unregister**: bei `install.ps1`-Rerun muss
  der alte Daemon-Prozess erst terminiert werden, sonst laeuft er
  (mit altem Script) weiter.
- **Start-ScheduledTask nach Register**: der Daemon startet sofort,
  nicht erst beim naechsten Logon. User bekommt Live-Task-Processing
  unmittelbar nach dem Installer-Rerun.

Bestehender Initial-Sweep in `win-task-runner.ps1:439` (`Process-AllTasks`
am Anfang von `-watch`) bleibt -- er drained Tasks, die waehrend
Daemon-Downtime queued wurden, bevor der FileSystemWatcher aktiv wird.

### Migration / Rollout

- `.update_class` bleibt **major**. Installer-Rerun ist Pflicht, damit
  der Task neu registriert wird. Der neue Daemon startet sofort mit
  `Start-ScheduledTask` am Ende von `Register-AgentboxTaskRunner`.
- **Bestehende Task-Files** in `<project>/_tasks/` werden beim
  Daemon-Start durch den Initial-Sweep aufgegriffen. Der 2.2.0-Benchmark-
  Versuch eines Users liegt da evtl. noch -- er wird beim ersten Daemon-
  Start verarbeitet.

## [2.2.0] - 2026-04-18

### Added -- `tools/` als mitgeliefertes Benchmark-Demoprojekt

Bisher war `tools/` nur eine Sammlung aus `bench.ps1`/`bench.sh` plus
einem static `index.html` -- nirgends aus aktivem Code referenziert,
vom User nur manuell aufrufbar. Jetzt wird es ein voll integriertes
Demo-Projekt, das agentbox' WSL-Performance-Vorsprung zeigt und
gleichzeitig demonstriert, wie der `project.json`-Build-Hook ueber den
bestehenden Task-Runner an Host-Scripts delegiert.

**Neue Komponenten:**

- **`tools/project.json`** -- macht das Verzeichnis zu einem agentbox-
  erkennbaren Projekt mit `build.command =
  "powershell -NoProfile -ExecutionPolicy Bypass -File bench.ps1"`.
- **`tools/CLAUDE.md`** -- Agent-Doku fuer das Demo-Projekt (JSON-
  Schema, Metriken, Task-Runner-Flow, do/don't-Regeln).
- **Installer-Seed** via neuer Funktion
  `Seed-AgentboxDemoBenchmark` in `win-setup-core.ps1`: kopiert den
  Inhalt von `tools/` idempotent nach `<AI_PROJECTS_ROOT>\demo-benchmark\`.
  Greift sowohl im Skip-Build-Pfad (Template aus Cache) als auch im
  Full-Build-Pfad. User-Modifikationen an der Kopie bleiben unberuehrt
  (Copy-only-if-missing).
- **Config-Submenue-Eintrag `[3] Benchmark ausfuehren`** in
  `wsl-ai-start.sh` (`_config_menu` -> `_run_benchmark_menu`): misst
  die Sandbox-Seite synchron und legt ein Task-JSON in
  `demo-benchmark/_tasks/bench-<ts>.json` ab. Der bestehende
  Scheduled-Task `agentbox-task-runner` (AtLogon-getriggert,
  `win-task-runner.ps1 -watch`, `FileSystemWatcher`) greift das
  Task-File ueber die existierende Pipeline auf, fuehrt bench.ps1 aus
  und schreibt Audit-Events 1001/1002/1003 ins Windows
  Application-Event-Log (Source `AIProjects`) -- kein neuer
  Trigger-Pfad, nur Andocken an den existierenden.

### Changed -- bench-Output: JSONL-Append -> JSON-Overwrite

`bench-results.jsonl` ist weg. `bench.{ps1,sh}` schreiben jetzt in
`bench-results.json` mit strict-overwrite-Schema:

```json
{
  "host":    { "timestamp": "...", "version": "3.0.0", "net_mbs": ..., ... },
  "sandbox": { "timestamp": "...", "version": "3.0.0", "net_mbs": ..., ... }
}
```

- Jeder Run liest das File, ersetzt **nur seine eigene Seite**
  (`host` oder `sandbox`) und schreibt zurueck. Die andere Seite
  bleibt erhalten. Keine History-Akkumulation mehr.
- `bench.ps1`-HTML-Renderer nutzt jetzt single-latest-run pro Seite
  statt Durchschnitt ueber alle Runs (der Durchschnitt war nur ein
  Workaround fuer das Append-Schema).
- `bench.sh` nutzt `python3` (im Template garantiert) statt
  `jq`-Abhaengigkeit fuer den JSON-Merge.
- `BENCH_VERSION` in beiden Scripts bump `2.2.0` -> `3.0.0`.

### Added -- bench.ps1 oeffnet HTML automatisch

Nach dem HTML-Build ruft `bench.ps1` `Start-Process $htmlOut`, was
den Default-Browser mit dem Ergebnis oeffnet. Nur auf dem Host;
`bench.sh` triggert bewusst keinen Browser (Sandbox hat keinen
und sollte auch keinen Host-Call machen).

### Added -- `build_whitelist` um bench.ps1 erweitert

Sowohl `config.json` als auch der hardcoded Fallback in
`win-task-runner.ps1:70-80` enthalten jetzt das Pattern
`powershell -NoProfile -ExecutionPolicy Bypass -File bench.ps1`.
Ohne diese Erweiterung wuerde der Task-Runner den Demo-Build mit
"Build-Kommando nicht in Whitelist" ablehnen.

### Docs -- Root-`CLAUDE.md` erweitert

Neuer Abschnitt **`tools/ -- Benchmark-Demoprojekt`** nach der
Config-Topologie. Verweist fuer Details auf `tools/CLAUDE.md`, haelt
die Kern-Invarianten (Seed-Mechanismus, Task-Runner-Andockung,
JSON-Schema) auf Projekt-Memory-Ebene fest.

### Migration

- Alte `bench-results.jsonl` wird von der neuen Version ignoriert,
  keine Auto-Migration. Einfach zwei frische Runs (1x bench.ps1 +
  1x bench.sh) und der neue JSON ist da.
- Nach `install.ps1`-Rerun ist `demo-benchmark/` im Projekt-Menue
  sichtbar. User, die den Menue-Eintrag `[3] Benchmark` nicht sehen:
  auch nach `install.ps1`-Rerun muss `wsl-ai-start.sh` aktuell sein
  (auto-update-Mechanismus greift beim naechsten Start).

## [2.1.4] - 2026-04-18

### Added -- `tools/bench.{ps1,sh}` Versions-Stempel im Output

User-Feedback: "ich erkenne nicht ob ich die neue Version habe, eine
Version im Header waere schoen." Fair. Jetzt:

- **`BENCH_VERSION` Konstante** oben in beiden Scripts (`2.1.4`),
  kuenftig bei jedem bench-Release mitbumpen.
- **Header-Zeile auf stdout** zeigt `agentbox-bench v2.1.4 platform=<host|sandbox>`
  in Cyan (PS) bzw. normaler Schrift (sh).
- **Summary-Zeile** und **bench-results.txt-Header** enthalten
  `version=2.1.4` -- damit ist beim Diffen zwischen Runs sofort
  ersichtlich welche Version welche Zahlen produziert hat.

Statt `agentbox-bench v1 platform=host` steht jetzt
`agentbox-bench version=2.1.4 platform=host` im Summary. Das bricht
bestehende Parser die strikt auf `v1` matchen -- unwahrscheinlich,
bei Bedarf per sed regex fixierbar.

## [2.1.3] - 2026-04-18

### Fixed — `tools/bench.{ps1,sh}`: ASCII-only, PS 5.1 ParseError behoben

User-Report: `bench.ps1` liess sich nicht laufen, PS 5.1 warf Parser-
Fehler "Unerwartetes Token" wegen Mojibake:

```
$errMsg = if ($r.error) { " â€" $($r.error.Trim())" } else { "" }
```

Ursache: das Em-Dash `U+2014` in meinen Strings wird UTF-8-encoded zu
3 Bytes (E2 80 94), die PS 5.1 ohne BOM als Windows-1252 decodiert
(`â€"`) -- und die mojibake-Zeichen brechen den Tokenizer. Gleiche
Falle wie `-Encoding utf8NoBOM` in CLAUDE.md.

Fix: alle Em-Dashes in beiden Scripts durch ASCII `--` ersetzt.
Gleiches fuer `->`-Pfeile in bench.sh (nicht parse-breaking, aber
konsistent). Beide Files jetzt 100 % ASCII.

## [2.1.2] - 2026-04-18

### Fixed — `tools/bench.{ps1,sh}`: robuster bei SNI-Filter + Progress

User-Report vom Host-Run: `speed.cloudflare.com` blockiert (vermutlich
SNI-Filter-Subdomain-unscharf), `curl.exe -s` hat den Fehler still
geschluckt → `0 MB/s` ohne Hinweis. Small-Files-Test schien zu
haengen, weil kein Progress-Indikator.

Aenderungen beide Scripts symmetrisch:

- **`BENCH_URL` / `$env:BENCH_URL` Override** fuer den Download-Endpoint.
- **Fallback-Kette** wenn kein Override: Cloudflare → npm-Registry →
  OVH (100 MB). Erstes funktionierendes Ziel gewinnt, ~80 MB reichen
  auch fuer ne stabile MB/s-Messung wenn die 500-MB-Targets alle
  blockiert sind.
- **Verbose Curl-Output** mit HTTP-Code + Size-Downloaded + Exit-Code
  pro Versuch. Bei Fehlschlag sichtbarer `[FAIL]`-Tag mit Grund.
- **Progress-Indikator bei small-files**: alle 1000 Files wird der
  aktuelle Durchsatz in DarkGray ausgegeben. Unter Windows-Defender-
  Real-Time-Scan dauert der Test teils 30+ Sekunden — mit Progress
  klar dass er laeuft.
- **TEMP-Drive-Info im Header** (nur PS1): manche Setups haben
  `D:\Temp` oder ein externes Drive, das erklaert langsame Zahlen.
- **`net_url=` im Summary-Block**: welcher Endpoint erfolgreich war,
  wichtig fuer die Fairness-Debatte im README.

Hinweis im Script-Header neu: Windows-Defender-Real-Time-Scan kann
die Disk-Zahlen um 50 %+ druecken — fuer "saubere" Messung kurz
Defender-Exclusion auf `$env:TEMP` setzen.

## [2.1.1] - 2026-04-18

### Added — `tools/bench.{ps1,sh}` Host/Sandbox-Perf-Vergleich

Zwei Paar-Scripts um Durchsatz Host vs. Sandbox zu messen. Gleiches
Output-Format auf beiden Seiten, **gleiche `bench-results.txt`** wenn
aus einem agentbox-Projektordner ausgefuehrt (CWD bind-mounted in die
Sandbox → beide Runs appenden in dieselbe Datei, direkt vergleichbar).

Tests:
1. **Netzwerk:** 500 MB download von `speed.cloudflare.com/__down` —
   Cloudflare ist SNI-unauffaellig, umgeht ggf. vorhandene Upstream-
   Filter. Miss in MB/s.
2. **Disk seq write:** 1 GB via 1 MB-Chunks mit fsync (Linux
   `conv=fdatasync` / Windows `FileStream.Flush($true)` — fair).
3. **Disk small-files:** 10'000 × 4 B create — das ist der
   `npm install`-Proxy, wo agentbox's ext4-Overlay-Architektur
   glaenzt.

Default-Ausgabe: `./bench-results.txt` in CWD, Append-Mode,
Separator-Header mit Timestamp + Platform. Ueberschreibbar via
`BENCH_OUT=/pfad` (bash) bzw. `$env:BENCH_OUT='...'` (PS).

Sandbox-Script akzeptiert `BENCH_DIR=/workspace/src` fuer DrvFs-
Messung statt der /tmp-ext4-Default.

Typischer Workflow: neues agentbox-Projekt anlegen (`benchmarks/`),
beide Scripts rein kopieren, `tools/bench.ps1` am Host + `tools/
bench.sh` in der Sandbox laufen lassen → `bench-results.txt` hat
beide Runs untereinander, Ratio fuer README rechenbar.

## [2.1.0] - 2026-04-18

### Added — `networkingMode=mirrored` Default bei WSL 2.0+/Win11 22H2+

Sandbox-Netzwerk-Durchsatz war durch WSL2-NAT ca. halbiert (~16 MB/s
Sandbox vs. ~33 MB/s Host, ~264 Mbps). Microsofts experimentelles
`networkingMode=mirrored` umgeht das NAT komplett. Nachteil: die
Sandbox haengt dann direkt am Host-Netz-Stack statt hinter NAT — ohne
Gegenmassnahmen ein Bruch der CLAUDE.md-Invariante `kein Host-LAN`.

Mit dem erweiterten Firewall-Hardening in `wsl-sandbox-init.sh` (siehe
unten) ist mirrored mode in der agentbox-Sandbox **genauso LAN-
isoliert** wie NAT — nur ohne den NAT-Overhead.

**Aktivierung:**

- **`config.json` Key `network_mode`** neu eingefuehrt. Werte:
  - `"auto"` (Default) — `install.ps1` probed `wsl --version` und
    Windows-Build. Bei WSL 2.0+ und Win11 22H2+ (Build ≥22621) wird
    `"mirrored"` persistiert; sonst `"nat"`.
  - `"mirrored"` erzwingt mirrored, unabhaengig von Detection.
  - `"nat"` erzwingt NAT (Rueckweg bei Problemen).
- **`.wslconfig` merge-aware Rewrite:** der `# agentbox`-Block wird
  bei jedem Install idempotent neu geschrieben (User-Content davor
  bleibt). Bei `network_mode=mirrored` enthaelt der Block zusaetzlich
  `networkingMode=mirrored`, `firewall=true`, `dnsTunneling=true`,
  `autoProxy=false`.
- **`wsl --shutdown` automatisch** am Ende des Installers wenn
  `.wslconfig` veraendert wurde — damit die neuen Werte beim naechsten
  Start auch fuer andere WSL-Distros (docker-desktop etc.) greifen.
- **Gelbe Warnung** wenn mirrored aktiviert wird: `.wslconfig`-Setting
  ist **global**, betrifft ALLE WSL-Distros am Host. User wird auf
  den Rueckweg (`network_mode=nat` + re-install) hingewiesen.

### Added — Firewall-Hardening laeuft jetzt immer, unabhaengig vom Mode

`wsl-sandbox-init.sh` bekommt fuenf zusaetzliche Regel-Familien die
pure Safety-Additions sind — kein Performance-Cost, laeuft auch unter
NAT (wo sie meist redundant zur existierenden OUTPUT-Kette sind).
Kritisch werden sie unter mirrored mode.

1. **INPUT-Chain default-deny**: nur loopback + ESTABLISHED erlaubt.
   In NAT Mode ohnehin unerreichbar, unter mirrored schliesst das
   versehentlich geoeffnete Agent-Ports vom LAN aus.
2. **FORWARD default-deny**: Sandbox ist kein Router.
3. **ip6tables-Mirror**: OUTPUT default-deny mit 443/80/DNS-Ausnahmen,
   IPv6-Private-Ranges (`fc00::/7`, `fe80::/10`, `::1/128`) + Multicast
   (`ff00::/8`) explizit DROPped. INPUT chain analog. Schuetzt wenn
   sysctl-IPv6-Disable durch eine kuenftige Regression fehlschlaegt.
4. **Multicast-IPv4-Block** (`224.0.0.0/4`): blockt mDNS/SSDP-Discovery.
5. **Host-IP-Autodetect-DROP**: `ip route show default` → erste Hop-
   IP wird explizit per `/32` geblockt. Belt-and-suspenders gegen
   Carrier-Grade-NAT (`100.64/10`) oder seltene Gateway-Ranges die
   nicht von RFC1918 abgedeckt sind.

### Added — Firewall-Seal-Test als Pre-Flight-Check

Nach Firewall-Apply wird versucht, zwei RFC1918-Canary-IPs (`192.168.1.1`,
`10.0.0.1`) zu erreichen. Schlaegt das durch (= Firewall hat ein Leck),
wird die Sandbox sofort abgebrochen statt den Agent in ein offenes
Netz zu spawnen. Zwei Canaries × 1s Timeout = ~2s Init-Overhead.

### Changed — `.update_class` = major

Siehe oben: `.wslconfig` wird global aktualisiert und `wsl --shutdown`
ist noetig. Der User kriegt den bewussten `[1]/[2]`-UAC-Prompt statt
stillem Upgrade.

## [2.0.19] - 2026-04-18

### Changed — Post-Install-Prompt auf Read-Host umgestellt

Zwei User-Reports (2.0.15, 2.0.17) mit "v tut nichts" trotz aller
Defensive-Input-Versuche (ConsoleKey-Enum + KeyChar + `$Host.UI.RawUI`
+ `[Console]` dual-polling). Verdacht: der PS-Host unter UAC-Elevation
oder in bestimmten Terminal-Konfiguration exposed keine der beiden
Key-APIs zuverlaessig. Weiter raten ist sinnlos.

Jetzt: `Read-Host` statt Timer-Polling. Blockt bis Enter, arbeitet aber
garantiert in jedem PS-Host. Timeout-Komfort geht verloren — der User
kann Enter ohne Eingabe druecken fuer den Default.

```
Jetzt agentbox starten?
  [1] Ja                  — starten mit aktuellem Launcher (Default)
  [2] Nein                — manuell via Desktop-Shortcut starten
  [3] VS Code + Filewatch — starten UND neuen Default setzen
  Auswahl [1/2/3, Enter = 1]  [2.0.19]:
```

Akzeptierte Eingaben: `1`/`2`/`3` (primaer, konsistent mit dem frueheren
Launcher-Prompt), `J`/`N`/`V` (Muscle-Memory-Kompat), leer = Default.
Unbekannte Eingabe → Hinweis + Default-Fallback.

Versionsmarke `[2.0.19]` in der Auswahlzeile. Bei GitHub-CDN-Cache-Hits
sieht der User sofort welche install.ps1-Version laeuft — Ursachen-
Trennung zwischen "Code-Bug" und "Datei aus Cache".

## [2.0.18] - 2026-04-18

### Changed — Post-Install-Timer als aufgelistetes Menue [1/2/3]

User-Report (Forts.): "v tut nichts" — Ursache war UX, nicht Code. Die
inline-Prompt `[J/n/v] (10s Timeout = ja, v = VS Code + Filewatch)` war
nicht als auswaehlbares Menue erkennbar. Der User hat auf eine Auflistung
gewartet und in der Zwischenzeit die 10s Timeout abgelaufen.

Jetzt identisches Multi-Line-Format wie der fruehere Launcher-Prompt
(Z. 1025–1063):

```
Jetzt agentbox starten?
  [1] Ja                 — starten mit aktuellem Launcher (Default)
  [2] Nein               — manuell via Desktop-Shortcut starten
  [3] VS Code + Filewatch — starten UND neuen Default setzen
  Auswahl [1/2/3, 10s Timeout = 1]  [2.0.18]:
```

Ziffern `1`/`2`/`3` als Primaer-Eingabe (konsistent mit dem Launcher-
Prompt), alte Buchstaben `J`/`N`/`V` weiter akzeptiert fuer
Rueckwaerts-Kompat mit Muscle-Memory. Versionsmarke `[2.0.18]` bleibt
am Ende der Auswahlzeile. Beim Timeout wird `1  (Timeout)` in DarkGray
echoed, damit sichtbar ist dass der Default ausgeloest wurde (statt nur
stummer Leerzeile).

## [2.0.17] - 2026-04-18

### Fixed — Post-Install-Timer: Key-Input robuster + Versionsmarke

User-Report: `[v]` liess sich nicht druecken, die Auswahl reagierte
nicht. Ursachen-Hypothesen und Gegenmassnahmen:

**1. Key-Detection auf zwei APIs erweitert.** Statt nur `[Console]::
KeyAvailable` / `[Console]::ReadKey` wird jetzt zuerst `$Host.UI.RawUI.
KeyAvailable` / `ReadKey("NoEcho,IncludeKeyDown")` gepollt — das ist
die PS-native Input-API und funktioniert auch in Hosts wo die
Console-Klasse vom Shell anders exposed wird (insbesondere bei
`irm ... | iex`, dem dokumentierten Bootstrap-Pattern). Erst wenn
`$Host.UI.RawUI` nichts liefert, faellt der Code auf `[Console]`
zurueck. Gleicher Buchstabenvergleich (case-insensitive) fuer beide.

**2. Versionsmarke im Prompt.** Der Timer-Prompt zeigt jetzt `[2.0.17]`
am Ende. Falls der User-Report "v tut nichts" wieder kommt, sieht man
sofort an der Marke ob die aktuelle install.ps1 laeuft oder ob eine
lokale/CDN-gecachte alte Version drinhaengt.

**3. Direktes Echo bei Unknown-Keys.** Wenn der User eine nicht
erwartete Taste drueckt, steht `[?=x ignoriert]` in DarkGray hinter
dem Prompt. So ist sofort ersichtlich, ob der Key-Input grundsaetzlich
ankommt.

**4. Timeout von 5s auf 10s erhoeht.** Drei Optionen statt zwei
brauchen mehr Lesezeit; 5s war fuer neu hinzugekommene v-Option zu
knapp.

## [2.0.16] - 2026-04-18

### Fixed + Changed — `[v]`-Key im Post-Install-Timer: jetzt reaktiv + persistent

Zwei Fixes am 2.0.15-Feature, basierend auf Praxis-Feedback:

**1. `V` wurde stumm geschluckt.** Die Key-Loop hat nur `$key.Key` gegen
den ConsoleKey-Enum gematcht. In manchen PS-Hosts (abhaengig vom
Keyboard-Layout / Input-Mode) kommt das Zeichen aber nur in
`$key.KeyChar` an. Jetzt wird beides geprueft (`$key.Key -eq 'V'
-or $kc -eq 'V'`), und der gedrueckte Buchstabe wird direkt nach der
Loop farbig echoed (` v`, ` j`, ` n`) — damit sieht der User sofort
dass die Taste registriert wurde. Gleiche Defensive auch fuer `N` /
`J` / `Y`.

**2. `V` persistiert jetzt als Default — nicht nur einmalig.** Bisher
war `V` ein reiner Session-Override: Config + Shortcut blieben wie
vorher. Das widersprach der User-Intuition ("was ich da waehle, soll
der Default sein"). Jetzt laeuft bei `V` die volle VS-Code-Umstellung:

- `launch_ui=vscode` wird in `config.json` persistiert (gleicher
  Smart-Merge wie der fruehere Launcher-Prompt).
- Das VS-Code-Terminal-Profil wird via `Merge-AgentboxVsCodeSettings`
  in die User-`settings.json` gemerged (falls vorher `launch_ui=wt`
  war, ist das noch nie passiert).
- Alter `agentbox.lnk` (wt) wird von Desktop + Start-Menue geloescht,
  `agentbox (VS Code).lnk` angelegt (`New-AgentboxShortcut -Mode
  vscode`).
- Fehlt VS Code komplett und winget ist da, wird VS Code on-the-fly
  via `winget install Microsoft.VisualStudioCode` nachgezogen
  (~100 MB, einmalig). Schlaegt auch das fehl → Warnung + Fallback
  in die wt/wsl-Chain, kein Config-Change.

Prompt-Text ergaenzt: `(..., v = VS Code + Filewatch, wird neuer
Default)` — damit klar ist dass es kein Session-Override mehr ist.

## [2.0.15] - 2026-04-18

### Added — Einmalige VS-Code-Option im Post-Install-Timer

Der 5-Sekunden-Timer am Ende von `install.ps1` akzeptiert jetzt `[v]`
als dritten Key neben `[J/n]`. Startet agentbox einmalig via
`agentbox.code-workspace` (Filewatch + Agent-Terminal im Editor),
unabhaengig vom persistierten `launch_ui`. Kein Config-Change — das
Shortcut-Verhalten bleibt wie konfiguriert.

VS Code wird on-the-fly via der bestehenden `Find-VsCodeExe`-Probe
gesucht, auch wenn `launch_ui=wt` vorher kein `$needVsCode` gesetzt
hat. Fehlt VS Code (oder das Workspace-File), greift ein Fallback mit
gelber Warnung in die bestehende wt/wsl-Launcher-Chain — der Timer-
"ja"-Pfad endet also nie in einer Sackgasse.

Prompt-Text: `Jetzt agentbox starten? [J/n/v] (5s Timeout = ja, v = VS
Code + Filewatch)`. Keine Aenderung am frueheren Launcher-Prompt (Z.
1025–1063), der `launch_ui` in `config.json` persistiert — die beiden
Konzepte bleiben bewusst getrennt (persistent vs. einmalig).

## [2.0.14] - 2026-04-17

### Changed — Error-Level-Konsistenz auf Bash-Seite + Stderr-Split

Der letzte offene Follow-up aus `refactor.md` ist durch. Zwei
zusammenhaengende Aenderungen in einem Commit:

**1. Stderr-Split fuer `log_warn` + `log_error`**

- `lib/log.sh`: `log_warn` und `log_error` schreiben jetzt auf
  stderr (`>&2`). `log_info` und `log_ok` bleiben auf stdout.
  Damit kann der User `agentbox 2>errors.log` zum sauberen
  Trennen nutzen.
- `wsl-sandbox-init.sh`: gleiche Aenderung in den inline-Kopien
  der Funktionen (Script laeuft in der Sandbox ohne `_control/`-
  Mount, kann `lib/log.sh` nicht sourcen).

**2. Bash-Harmonisierung: `echo "FEHLER: ..."` → `log_error`**

Im ganzen Codebase existierten zwei parallele Error-Conventions:
die kanonische `log_error "msg"` (nur 4 Call-Sites) und die
dominantere Plain-Form `echo "FEHLER: ..."` (~8 Call-Sites auf
Hard-Exit-Pfaden). Das war vor der stderr-Umstellung rein
kosmetisch, danach wirkte es — die Plain-Form haette weiter auf
stdout geschrieben und den Split unterlaufen.

- Alle `echo "FEHLER: ..."` in `wsl-ai-start.sh` und
  `wsl-sandbox-init.sh` → `log_error "..."` (wo Helper verfuegbar)
  oder `echo "FEHLER: ..." >&2` (fuer die paar Early-Exit-Pfade,
  die vor dem lib/log.sh-Source laufen).
- Follow-up-Zeilen nach `log_error`-Blocks bekommen `>&2`, damit
  der gesamte Fehlerkontext zusammen auf stderr landet.
- `echo "[WARN] Migration ..."` → `log_warn "..."`.
- `wsl-sandbox-init.sh:77` (Sandbox-User-Root-Check, der auf
  Default `agent` recovered) semantisch korrigiert: vorher
  irrefuehrend als `FEHLER` geloggt, jetzt `log_warn` — der Code
  exitet nicht, warnt nur.

**3. Ordering-Fixes fuer frueh verfuegbare Helper**

- `wsl-ai-start.sh`: Der `lib/log.sh`-Source-Block wurde von
  ~Z.345 zu Z.75 vorgezogen (direkt nach der `CONTROL_DIR`-
  Definition), damit `log_error`/`log_warn` moeglichst frueh
  verfuegbar sind. Pre-2.0.5-Inline-Fallback bleibt als
  Kompatibilitaetsnetz drin, ebenfalls mit stderr-Split.
- `wsl-sandbox-init.sh`: Die Inline-log-Defs wurden an den
  absoluten Script-Anfang (direkt nach `set -euo pipefail`)
  gezogen — auch die Parameter-Validierung ganz oben kann
  jetzt `log_error` nutzen.

### Notes

- Semantisch identisches Format `[LEVEL] message` — Scripts, die
  nach Prefixen grep'en, bleiben funktionsfaehig. Einzige
  User-sichtbare Aenderung: FEHLER-Zeilen haben jetzt **Brackets**
  und ANSI-rot (frueher `FEHLER: ...` ohne Brackets, ohne Farbe).
- **Pipe-Breaking-Warnung**: User, die ihren agentbox-Output in
  eine Logdatei umleiten und dabei **nur** stdout erwischen
  (z.B. `agentbox > log.txt`), sehen ab 2.0.14 WARN/ERROR-Zeilen
  nicht mehr in der Datei. Fuer alle Zeilen zusammen:
  `agentbox > log.txt 2>&1`. Fuer saubere Fehlertrennung:
  `agentbox 1>info.log 2>errors.log`.
- PowerShell-Seite bewusst unberuehrt. `Write-Host` in PS laeuft
  outside dem stdout/stderr-Modell; Migration haette keinen
  praktischen Nutzen, nur Kosten (Option C wurde verworfen).
- Damit ist der einzige dokumentierte Follow-up aus dem Umbrella-
  Refactor erledigt. `refactor.md` verliert den letzten offenen
  Punkt.

## [2.0.13] - 2026-04-17

### Docs — refactor.md auf Philosophie reduziert

Pure Doku-Release. Nach Abschluss des Umbrella-Refactors (2.0.2–
2.0.12) enthielt `refactor.md` knapp 250 Zeilen Befundkatalog + pro-
Etappe-Checklisten, die alle durch waren und Details nur noch im
CHANGELOG aktuell gehalten werden mussten.

- `refactor.md` auf ~70 Zeilen geschrumpft. Behalten: die
  Grundregeln fuer agentbox-Refactors (Commit-auf-main, Installer
  muss nach jeder Etappe gruen bleiben, Kosten/Nutzen-Check,
  Minor-Release-mit-Fallback, `.update_class`-Hygiene,
  `template_schema`-Bump-Regel, Doku-im-selben-Commit), die
  „bewusst-nicht-gemacht"-Liste als Richtungshinweis fuer
  Nachfolge-Refactors, und der eine offene Follow-up
  (Stderr-Split).
- `CLAUDE.md`: Section „Laufender Architektur-Refactor" wurde
  in „Architektur-Refactor (abgeschlossen 2026-04-17)"
  umbenannt und auf einen 5-Zeiler reduziert. Verweist weiter
  auf `refactor.md` als Startpunkt fuer zukuenftige Refactors
  auf derselben Basis.

Keine Code-Aenderung. `.update_class` bleibt `minor`.

## [2.0.12] - 2026-04-17

### Decided — Etappe 3 Teil E wird nicht umgesetzt

Dokumentation-only Commit. `refactor.md` haelt jetzt fest, dass der
Umstieg von `$ErrorActionPreference="Continue"` auf `"Stop"` in
`win-setup-core.ps1` **bewusst nicht gemacht** wird.

Gruende:
- Survey zeigt 19 native `wsl.exe`-Calls im Template-Builder, viele
  an kritischen Phasen (`--import`, `--export --vhd`, `--export`,
  `--unregister`). Umbau auf `Invoke-Native`-Wrap haette fuer jeden
  Call Kompatibilitaet mit bestehenden Output-Captures + Pipes
  sicherstellen muessen — plus vollstaendigen Template-Build-
  Regressions-Test auf Windows-Host.
- Die **originale Motivation** aus dem Architektur-Review (Befund E:
  angeblicher „latenter Crash" in `win-task-runner.ps1:252-265`
  unter `"Stop"` ohne Wrap) hat sich in Etappe 3 Teil D (2.0.11)
  als **Fehldiagnose** entpuppt. Der Block nutzt
  `Start-Process -PassThru` statt direkter `&`-Invocation; Stderr
  wird nicht durch den PS-Error-Stream geroutet, `ExitCode` kommt
  aus dem Process-Objekt. Kein Crash-Risiko.
- Ohne echten Crash-Pfad ist die Inkonsistenz zwischen den drei
  Scripts ein Smell, kein Bug. Aktueller Zustand (Continue hier,
  Stop in den anderen beiden) laeuft seit mehreren Releases
  problemlos.
- Kosten/Nutzen: hoch/null.

Wenn zukuenftig ein echter Bug auftaucht, der `"Stop"` in
`win-setup-core.ps1` erzwingt, wird Teil E gezielt aufgegriffen.

### Status — Architektur-Refactor aus 2.0.2ff

- Etappe 1 (Drift-Fixes): ✅ 2.0.2–2.0.3
- Etappe 2 (--list-sessions-Regression): ✅ 2.0.3
- Etappe 3 (lib/config.ps1, Teil A–D): ✅ 2.0.7–2.0.11; Teil E skipped
- Etappe 4 (Agent-Liste aus Config): ✅ 2.0.4 + Hotfix 2.0.8
- Etappe 5 Teil 1+2 (lib/log.sh + Config-Topologie-Doku + sandbox-
  init-[OK]): ✅ 2.0.5–2.0.6; Teil 3 (Stderr-Split) bleibt Follow-up.

Der Umbrella-Refactor aus dem Session-Start ist damit funktional
abgeschlossen. Eine offene Leftover-Position (5 Teil 3) dokumentiert,
keine offene Risk-Position mehr.

## [2.0.11] - 2026-04-17

### Changed — win-task-runner.ps1 nutzt lib/config.ps1

Etappe 3 Teil D aus `refactor.md`. Gleiche Struktur wie Teil B+C:
Config-Parse (Z.27-36) ueber `Read-AgentboxConfig` mit Test-Path-
guarded + try/catch-wrapped Source und Inline-Fallback.

### Revidiert — kein Invoke-Native-Wrap in Teil D

Das Original-Ziel 3.4 aus `refactor.md` („Native-Calls Z.252-265 in
`Invoke-Native` einhuellen — latenter Crash-Fix") war eine
Fehldiagnose. Z.252-265 nutzt `Start-Process -Wait -NoNewWindow
-PassThru` (nicht direkte `& git.exe`-Invocation). Stderr wird dabei
nicht durch PowerShells Error-Stream geroutet; der ExitCode kommt
aus dem Process-Objekt. Kein Crash-Risiko unter
`$ErrorActionPreference="Stop"`, also kein Wrapper noetig.

### Bewusst nicht gemacht

`Write-Log` (Z.77-87) bleibt als lokale Funktion. 30+ Call-Sites
referenzieren den Namen; Umbenennen auf `Write-AgentboxLog` waere
reine Noise bei semantisch identischem Verhalten. Die lokale
Definition ist bereits aequivalent.

### Notes

Kein Template-Rebuild, kein Installer-Struktur-Wechsel.
`.update_class` bleibt `minor`. Damit ist Etappe 3 Teil B/C/D
komplett — die drei PS-Installer-Scripts nutzen jetzt alle
`lib/config.ps1` mit sicherem Fallback. Nur Teil E (Stop-Mode +
breiter Invoke-Native-Wrap in win-setup-core.ps1) bleibt offen
und ist bewusst auf eine dedizierte Session verschoben.

## [2.0.10] - 2026-04-17

### Changed — win-setup-core.ps1 nutzt lib/config.ps1

Etappe 3 Teil C aus `refactor.md`. Gleiche Struktur wie Teil B:
Config-Parse-Block (Z.73-82) ueber `Read-AgentboxConfig` mit
Test-Path-guarded + try/catch-wrapped Source und Inline-Fallback.

- Guard: `Get-Command Read-AgentboxConfig -ErrorAction SilentlyContinue`
  entscheidet, ob die Lib schon geladen ist. Bei Rerun aus
  `install.ps1` heraus ist sie das bereits (Teil B). Bei Standalone-
  Aufruf (User fuehrt `win-setup-core.ps1` direkt aus) wird aus
  `$scriptDir\lib\config.ps1` nachgeladen.
- Verhalten identisch: gleiche Log-Zeile bei Fehler
  (`[INFO] config.json nicht lesbar ...`), gleiche `$config=$null`-
  Semantik.

### Notes

`win-setup-core.ps1` laeuft mit `$ErrorActionPreference="Continue"` —
kein Umstellen auf `Stop` in diesem Commit. Das ist Teil E und hat
eigene Invoke-Native-Wrap-Voraussetzungen. Kein Template-Rebuild
erzwungen, kein Installer-Struktur-Wechsel. `.update_class` bleibt
`minor`.

## [2.0.9] - 2026-04-17

### Changed — install.ps1 nutzt lib/config.ps1 an post-Clone-Stelle

Etappe 3 Teil B aus `refactor.md`. Minimaler Einstieg in die
PS-Migration: **nur** der Config-Parse bei Z.955+ (`$installConfig`
fuer `.wslconfig`) wird umgestellt. Die Pre-Clone-Stelle bei Z.474
bleibt auf Inline-Muster — lib/config.ps1 liegt zu dem Zeitpunkt
strukturell noch nicht auf Disk (der Repo-Clone folgt erst).

Pattern: `Get-Command Read-AgentboxConfig -ErrorAction
SilentlyContinue` als Fuehrungs-Guard. Wenn die Funktion noch nicht
geladen ist, wird `$controlDir/lib/config.ps1` Test-Path-guarded und
try/catch-wrapped gesourced. Gelingt das, nutzt der Aufruf die Lib;
scheitert es, faellt der Block auf das urspruengliche
`Get-Content | ConvertFrom-Json`-Muster zurueck. Die Logik ist
zeile-fuer-zeile revert-bar (einfach den neuen Wrapper-Block
ersetzen durch die drei alten Zeilen).

### Notes

- Verhalten auf existierender Installation: identisch. Alte Nutzer
  ziehen lib/config.ps1 via Auto-Update (2.0.7+), und der Installer
  bei manuellem Rerun nimmt den neuen Pfad, ohne dass sich die
  Semantik aendert.
- Frische `irm | iex`-Installation: der Clone-Schritt bringt
  lib/config.ps1 mit rein, also ist die Lib zum Zeitpunkt Z.955
  garantiert da.
- Kein Template-Rebuild, kein Installer-Struktur-Wechsel.
  `.update_class` bleibt `minor`.
- Etappe 3 Teil C (`win-setup-core.ps1`) und Teil D
  (`win-task-runner.ps1`) folgen als separate Commits.

## [2.0.8] - 2026-04-17

### Fixed — Hotfix fuer Etappe-4-Regression

Zwei Bugs aus dem 2.0.4-Refactor der Auth-Mount-Liste, die den
agentbox-Start in eine Endlosschleife geschickt haben:

- **`AGENTBOX_AUTH_AGENTS: unbound variable`** (`wsl-ai-start.sh:1069`):
  Ich hatte die Variable im Zuge von 2.0.4 entfernt, aber den Log-
  Verweis am Ende des Auth-Setup-Blocks uebersehen. Mit `set -u`
  aktiv killte das den Start. Ersetzt durch `$AGENTBOX_AUTH_IDS`,
  das parallel zur `AUTH_SPEC` in der neuen while-Loop aufgebaut
  wird.
- **`cfg_get_agents_all: command not found`** (`wsl-ai-start.sh:920`):
  Wenn `lib/config.sh` auf dem Host aus irgendeinem Grund noch die
  Pre-2.0.4-Version ist (OneDrive-Sync-Skew, teilweise erfolgreicher
  Auto-Update-Pull), bricht der Aufruf der neuen Funktion mit einem
  Fatal-Error. Jetzt wird `declare -F cfg_get_agents_all` vor dem
  Aufruf geprueft; fehlt die Funktion, wird ein Hardcode-Shim mit
  dem 5-Agent-Fallback inline injiziert — identisch zum
  Fallback-Block in `lib/config.sh` selbst.

### Notes

- Betrifft nur User, die zwischen 2.0.3 und 2.0.8 auf die 2.0.4-Auth-
  Refactor-Version gepullt haben. Frischer Install ist nie betroffen.
- Nach Pull von 2.0.8 sollte der Start wieder durchlaufen, egal welche
  lib/config.sh-Version gerade aktiv ist. Der Log zeigt:
  `[OK] Auth-Cache: <pfad> (Logins persistiert: claude codex gemini aider goose)`
- Kein Template-Rebuild. `.update_class` bleibt `minor`.

## [2.0.7] - 2026-04-17

### Added — `lib/config.ps1` (additiv)

Etappe 3 Teil A aus `refactor.md`. Rein additiv: neue Datei, keine
Call-Site-Aenderungen, kein Installer-Pfad-Wechsel.

- `lib/config.ps1`: drei PS-5.1-kompatible Helper als gemeinsame
  Grundlage fuer `install.ps1`, `win-setup-core.ps1` und
  `win-task-runner.ps1`:
  - `Read-AgentboxConfig` — `Test-Path` + `Get-Content -LiteralPath`
    + `ConvertFrom-Json`, silent bei Fehler, Drop-in fuer die drei
    parallelen Inline-Bloecke.
  - `Invoke-Native` — verbatim aus `install.ps1:27-38` extrahiert,
    wrappt native Calls (`wsl.exe`/`git.exe`/...) unter
    `$ErrorActionPreference='Continue'` und stellt den vorherigen
    Wert wieder her.
  - `Write-AgentboxLog` — Zeitstempel + Level + Farbe, kompatibel
    zur bestehenden `Write-Log` in `win-task-runner.ps1:77-87`
    (gleiche Level-Namen, gleiche Farben, gleiches Format).

### Notes

Dieser Commit stellt **keine** Call-Site um. Die bestehenden
Inline-Bloecke bleiben unveraendert aktiv. Die Folge-Commits (Teil B
= `install.ps1`, C = `win-setup-core.ps1`, D = `win-task-runner.ps1`)
schalten je ein Script um, damit ein Regressions-Revert pro Script
moeglich bleibt. `.update_class` `minor`, kein Template-Rebuild.

## [2.0.6] - 2026-04-17

### Changed — Sandbox-Init-Logging angeglichen

Etappe 5 Teil 2 aus `refactor.md`.

- `wsl-sandbox-init.sh`: die ~34 `echo "[OK] ..."` / `"[INFO] ..."` /
  `"[WARN] ..."` / `"[FEHLER] ..."`-Zeilen wurden durch
  `log_ok`/`log_info`/`log_warn`/`log_error` ersetzt. Dadurch
  bekommt der Sandbox-Init jetzt die gleichen ANSI-Farben wie
  `wsl-ai-start.sh` (zuvor: nur im Host-Part gruen/gelb/rot, in der
  Sandbox plain).
- Die `log_*`-Funktionen sind **inline** am Anfang von
  `wsl-sandbox-init.sh` definiert (nicht aus `lib/log.sh` gesourced),
  weil das Script in der ephemeren Distro laeuft und `_control/lib/`
  dort nicht gemounted ist — bewusst: keine neue Mount-Route nur fuer
  Logging. Kleine Duplikation mit `lib/log.sh` im Kauf genommen.

### Notes

Semantisch identisches Output-Format (`[LEVEL] message`) — Scripts
oder Hooks, die nach den Prefixen grep'en, bleiben unveraendert
funktionsfaehig. Kein Template-Rebuild noetig, kein Installer-Pfad-
Wechsel. `.update_class` bleibt `minor`.

## [2.0.5] - 2026-04-17

### Changed — Logging-Helper zentralisiert, Config-Topologie dokumentiert

Etappe 5 Teil 1 aus `refactor.md`.

- **Neu: `lib/log.sh`.** `log_info`/`log_ok`/`log_warn`/`log_error` +
  ANSI-Farb-Vars (`RED`/`GREEN`/`YELLOW`/`CYAN`/`NC`) jetzt an einer
  zentralen Stelle. `wsl-ai-start.sh` sourced die Lib; inline-
  Definitionen bleiben als Fallback drin, damit ein Pre-2.0.5-Clone
  ohne `lib/log.sh` nicht sofort bricht (Upgrade-Pfad-Safety). Verhalten
  identisch: alle Levels auf stdout, Farben immer aktiv. Ein Stderr-
  Split fuer WARN/ERROR ist als Ticket vorgemerkt.

- **CLAUDE.md: neue Section "Config-Topologie".** Dokumentiert die
  Trennung `config.json` (System/Agents/Resources, faellt in den
  Template-Config-Hash) vs. `type_defaults.json` (Projekt-Type-Defaults,
  nur beim Erst-Anlegen einer `project.json` relevant). Schliesst
  Befund H aus dem Refactor-Plan: keine Cross-File-Fallbacks, keine
  ueberlappenden Keys, und die einzige Bash-Lese-Schnittstelle ist
  `lib/config.sh` (`cfg_get` / `cfg_get_array` / `cfg_get_agents` /
  `cfg_get_agents_all`).

### Notes

`wsl-sandbox-init.sh` benutzt weiterhin plain `echo "[OK] ..."` — der
Bulk-Replace auf `log_ok` ist Etappe 5 Teil 2 und kommt in einem
eigenen Commit, weil er ~20+ Zeilen anfasst und keinen eigenen
strukturellen Wert hat.

Kein Template-Rebuild, kein Installer-Pfad-Wechsel. `.update_class`
bleibt `minor`.

## [2.0.4] - 2026-04-17

### Changed — Agent-Auth-Mount aus Config, nicht mehr hartcodiert

Etappe 4 aus `refactor.md`. Befund C: die 5-Agent-Liste war an vier
Stellen parallel hartcodiert; ein 6. Agent haette vier Dateien
angefasst. Jetzt zieht die Auth-Persistenz ihre Agent-Liste aus
`config.json`.

- `lib/config.sh`: neue Funktion `cfg_get_agents_all`. Liefert **alle**
  in `config.json` bekannten Agents (enabled + disabled) als
  `id:auth_dir`-Zeilen. Default fuer `auth_dir` ist `.<id>` — matcht
  Claude/Codex/Gemini/Aider. Abweichler muessen `agent_<id>_auth_dir`
  explizit setzen.
- `config.json`: neuer Key `agent_goose_auth_dir: ".config/goose"`
  (der einzige Agent mit abweichendem Home-Pfad).
- `wsl-ai-start.sh`: die harte Liste `AGENTBOX_AUTH_AGENTS="claude codex
  gemini aider goose"` ist weg. Stattdessen baut das Script ein
  `AGENTBOX_AUTH_SPEC="id=auth_dir;id=auth_dir;..."` aus
  `cfg_get_agents_all`, legt die Per-Agent-Unterordner unter `AUTH_BASE`
  entsprechend an und uebergibt die Spec als 7. Parameter an
  `wsl-sandbox-init.sh`.
- `wsl-sandbox-init.sh`: akzeptiert `AUTH_SPEC` als 7. Parameter,
  parst semikolon-separiert in ein Bash-Array und iteriert darueber
  statt die 5 `_auth_mount_agent`-Calls hartzucoden. Leer → Legacy-
  Hardcode-Fallback, damit aeltere Host-Scripts oder fehlendes python3
  die Auth-Persistenz nicht komplett kaputt machen.

### Notes

- Neuer Agent hinzufuegen = nur noch `config.json`-Block ergaenzen.
  Mount-Code muss nicht mehr angefasst werden.
- Template wird beim naechsten `install.ps1`-Rerun einmalig neu
  gebaut, weil der neue Config-Key `agent_goose_auth_dir` in den
  Config-Hash faellt (`Get-AgentboxConfigHash` matcht `^agent_`).
  Einmaliger Rebuild; kein Installer-Pfad-Aenderung. `.update_class`
  bleibt `minor`.
- Auto-Approve-Flag-Block in `wsl-sandbox-init.sh:~841` (Befund C
  Teil 2) wurde bewusst **nicht** angefasst — er ist mit nur 2
  Eintraegen (Gemini+Aider) klein und bewusst hartgecodet fuer
  Injection-Safety. Config-Treiber kostet dort mehr als er bringt.

## [2.0.3] - 2026-04-17

### Fixed — `agentbox --list-sessions` / `--compare` repariert

Die beiden Session-Kommandos hatten nach der 2.0-Layout-Migration
ins Leere gegriffen: sie lasen noch aus dem alten Pfad
`${AI_PROJECTS_ROOT}/_control/sessions`, waehrend Sessions seit 2.0
unter `%LOCALAPPDATA%\agentbox\sessions\` liegen. Ergebnis: leere
Liste bzw. "not found" bei Existenz.

- `wsl-ai-start.sh`: Argparse-Loop entkoppelt von Execution. Die
  `--list-sessions`- und `--compare`-Bloecke laufen jetzt erst, nachdem
  `_resolve_agentbox_local_root` + `$SESSIONS_DIR` definiert und die
  einmalige Migration aus `_control/sessions` durchgelaufen ist.
  Konkret: neues Flag `LIST_SESSIONS_MODE`, ansonsten identische
  Ausgabe- und Diff-Logik.

### Changed — README-Dateistruktur auf 2.0-Layout

Die File-Structure-Abschnitte in `README.md` und `docs/README.de.md`
zeigten noch das Pre-2.0-Layout mit `_control/sandbox/`,
`_control/cache/` und `_control/sessions/`. Das widersprach dem
Architektur-Vertrag aus `CLAUDE.md` ("Runtime-State liegt strikt
ausserhalb `_control/`"). Neu: zwei getrennte Trees — versioniert
(`_control/` in OneDrive) und lokal (`%LOCALAPPDATA%\agentbox\`).
Auch der "What Persists"-Abschnitt zeigt die Paket-Caches jetzt korrekt
unter `%LOCALAPPDATA%\agentbox\cache\…`.

### Notes

Kein Template-Rebuild. Das ist ein reiner Runtime-/Doc-Fix. `.update_class`
bleibt `minor`.

## [2.0.2] - 2026-04-17

### Fixed — Konsistenz & Drift

- **`.update_class` von `major` auf `minor` korrigiert.** 2.0.1 war eine
  reine Build-Zeit-Optimierung; kein `install.ps1`-Rerun als Admin
  notwendig. Der Bump auf `major` hatte User einen unnoetigen
  `[1]/[2]`-UAC-Prompt eingebracht und die laufende Session beendet.
  Faustregel siehe `CLAUDE.md` § Release-Prozess.

- **Gemini-Install-Fallback angeglichen.** Der statische Fallback in
  `win-setup-core.ps1` (aktiv nur wenn `agent_gemini_install` aus
  `config.json` fehlt) zeigte `pip3 install google-gemini-cli`, waehrend
  die Laufzeit-Installation via `config.json` das offizielle npm-Paket
  `@google/gemini-cli@latest` nutzt. Fallback jetzt identisch. Doku-
  Tabelle in `README.md` + `docs/README.de.md` ebenfalls auf **npm**
  gezogen — sie behaupteten bisher `pip` und widersprachen damit
  `config.json`.

### Added

- **`refactor.md` im Repo-Root.** Session-uebergreifender
  Architektur-Aufraeum-Plan mit 5 Etappen (Drift-Fixes, Regression-
  Repair, zentrale PS-Lib, Agent-Liste aus Config ziehen, Log-Refactor).
  CLAUDE.md verweist jetzt oben drauf, damit neue Sessions die naechste
  offene Etappe finden.

### Notes

Kein Template-Rebuild-Zwang — `template_schema` bleibt bei `3`, weil
der tatsaechliche Install-Command aus `config.json`
(`agent_gemini_install`) sich nicht aendert und damit auch der
Config-Hash identisch bleibt. Nur Fallback-/Doku-Drift beseitigt.

## [2.0.1] - 2026-04-17

### Added — Build-Beschleunigung (Template-Rebuild ~2-4 min schneller)

Rein Build-Time-Optimierung des Template-Builds in `win-setup-core.ps1`.
Session-Start / Runtime unberuehrt.

- **`force-unsafe-io` in dpkg.cfg.d** — dpkg ruft per Default nach jeder
  installierten Datei `fdatasync()`. Bei Ubuntu Noble + nodejs + python3
  sind das ~5000 Dateien, ~30-50s. Im ephemeren Template-Build (wird bei
  Crash ohnehin verworfen) ist Sync unnoetig.

- **apt-Pipelining** — `/etc/apt/apt.conf.d/99-agentbox-fastbuild` mit
  `Acquire::http::Pipeline-Depth=20` + `Queue-Mode=access`. Parallele
  Paket-Downloads aus der Quelle, spart 20-30s bei dicken Paketen.

- **Parallele Agent-Installs** — `npm install -g claude-code` /
  `npm install -g codex` / `pip3 install gemini-cli` laufen via
  `_run_agent ... &` gleichzeitig statt nacheinander. Jedes eigenes
  Logfile (`/tmp/agent-*.log`), Fail-Tail wird in den Haupt-Install-Log
  gespiegelt. Spart 30-60s.

- **tar.gz-Export nur noch als Fallback** — `wsl --export --vhd` laeuft
  jetzt zuerst. Wenn erfolgreich: tar.gz wird gar nicht mehr gebaut
  (~3GB gzip → ~60-90s). tar.gz kommt nur noch bei WSL-Versionen ohne
  vhdx-Support als Ersatz. `wsl-ai-start.sh` akzeptiert jetzt auch
  einen Template-Zustand mit nur vhdx und ohne tar.gz.

- **apt-Basis-Install gemergt** — `apt-utils bash curl wget git ...`
  laufen in einem `apt-get install`-Call statt zwei. ~5-10s.

### Changed

- `template_schema=3` im Config-Hash erzwingt Rebuild bei bestehenden
  Installationen (damit die neuen Build-Optimierungen + die neue
  Export-Reihenfolge beim naechsten `install.ps1`-Rerun greifen).

### Notes

Erwartete Gesamt-Ersparnis: **~140-230s pro Template-Rebuild** (≈40%
schneller). Laufzeit-Verhalten (Netzwerk-Tuning, Hybrid-Overlays, vhdx-
Fastpath beim Session-Start) unveraendert zu 2.0.0.

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
