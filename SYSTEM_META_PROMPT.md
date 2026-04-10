# SYSTEM_META_PROMPT.md
# Arbeitsvertrag fuer AI-Agenten in der agentbox-Sandbox

## Dein Arbeitsbereich

Du arbeitest in `/workspace/` — das ist dein Arbeitsverzeichnis.
Die Struktur sieht so aus:

```
/workspace/
  src/           ← Dein Hauptarbeitsverzeichnis (read-write)
  assets/        ← Statische Dateien (read-only)
  _tasks/        ← Task-Trigger fuer Build/Deploy (read-write)
  CLAUDE.md      ← Session-Kontinuitaet (read-write)
  project.json   ← Projektkonfiguration (read-only)
```

Dein Projekt ist beschrieben in `project.json` im Projektroot.
Lies diese Datei zu Beginn, um den Projekttyp und die Konfiguration zu verstehen.

## Was du NICHT hast

- Du hast keinen Zugriff auf andere Projekte.
- Du hast keinen Zugriff auf das Hostsystem.
- Du hast keinen Zugriff auf das Internet (ausser fuer deine eigene API).
- Du hast kein `sudo` und keine Administratorrechte.
- Du kannst keine Symlinks nach ausserhalb erstellen.

## Build und Deploy

Du kannst Build oder Deploy nicht selbst ausfuehren.
Es sind keine Build-Tools in deiner Umgebung installiert.

Stattdessen: Schreibe eine JSON-Datei nach `/workspace/_tasks/`.

### So triggerst du einen Build oder Deploy:

1. Erstelle die Task-Datei zuerst als `.tmp` (wichtig!):

```bash
cat > /workspace/_tasks/build_001.tmp << 'EOF'
{
  "project": "PROJEKTNAME",
  "action": "build",
  "timestamp": "2025-01-15T14:30:00"
}
EOF
```

2. Benenne sie dann zu `.json` um:

```bash
mv /workspace/_tasks/build_001.tmp /workspace/_tasks/build_001.json
```

**Warum erst `.tmp`?** Der externe Runner ueberwacht nur `.json`-Dateien.
Das Umbenennen stellt sicher, dass die Datei vollstaendig geschrieben ist,
bevor der Runner sie liest.

### Erlaubte Aktionen

- `"action": "build"` — Fuehrt den in `project.json` definierten Build aus
- `"action": "deploy"` — Fuehrt das in `project.json` definierte Deploy aus

Andere Aktionen werden abgelehnt.

### Ergebnis pruefen

Ein externer Runner auf dem Windows-Host wird die Aktion ausfuehren.
Das Ergebnis findest du in:

- `/workspace/_tasks/status_build.json` (nach einem Build)
- `/workspace/_tasks/status_deploy.json` (nach einem Deploy)

Moegliche Status-Werte:

| Status    | Bedeutung                              |
|-----------|----------------------------------------|
| `running` | Aktion wird gerade ausgefuehrt         |
| `done`    | Aktion erfolgreich abgeschlossen       |
| `failed`  | Aktion fehlgeschlagen (mit Fehlerdetail)|

Beispiel einer Status-Datei:

```json
{
  "status": "done",
  "timestamp": "2025-01-15T14:30:05"
}
```

Bei Fehler:

```json
{
  "status": "failed",
  "timestamp": "2025-01-15T14:30:05",
  "error": "npm ERR! missing script: build"
}
```

## Session-Kontinuitaet mit CLAUDE.md

`CLAUDE.md` liegt in `/workspace/CLAUDE.md` — lies sie zu Beginn jeder Session.

Sie enthaelt den Stand der letzten Session:
- Offene Punkte
- Getroffene Entscheidungen
- Naechste Schritte

**Aktualisiere CLAUDE.md am Ende jeder Session** mit deinem aktuellen Stand,
damit die naechste Session nahtlos weitermachen kann.

Regeln fuer CLAUDE.md:
- Schreibe keine Session-History, sondern nur den **aktuellen Stand**.
- CLAUDE.md ist ein lebendes Dokument, kein Log.
- Halte es kurz und praegnant: Was ist der Stand? Was fehlt noch? Was wurde entschieden?
