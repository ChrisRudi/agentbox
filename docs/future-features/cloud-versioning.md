# Future Feature: Cloud-Versionierung nutzen

## Idee

Projekte liegen standardmaessig in OneDrive (oder Google Drive / Dropbox via `base_path_override`). Diese Cloud-Services versionieren automatisch jede Dateiaenderung. agentbox kann das bewusst nutzen, um Speicherplatz zu sparen und den Versionsverlauf navigierbar zu machen.

## Geplante Aenderungen

### 1. Cloud-Provider-Erkennung

Anhand des Projektpfads erkennen, welcher Cloud-Service genutzt wird:

| Pfad enthaelt | Provider |
|---|---|
| `/OneDrive/` | OneDrive |
| `/Google Drive/` oder `/GoogleDrive/` | Google Drive |
| `/Dropbox/` | Dropbox |
| Keines davon | Lokal |

**Datei**: `wsl-ai-start.sh` (neuer Abschnitt nach Config-Laden, ~Zeile 168)

### 2. Session-Marker-Datei

`.agentbox_session.json` im Projekt-Root schreiben — jeweils bei Session-Start und Session-Ende:

```json
{
  "event": "session_start",
  "session_id": "20260411_143000_claude_MyProject",
  "agent": "Claude Code",
  "timestamp": "2026-04-11T14:30:00+02:00",
  "project": "MyProject"
}
```

Der Cloud-Service speichert automatisch beide Versionen. Dadurch kann der User im Versionsverlauf gezielt die Session-Grenzen finden und den Stand vor/nach einer Agent-Session wiederherstellen.

**Datei**: `wsl-ai-start.sh` (nach Snapshot-Erstellung ~Zeile 608 und nach Diff-Erfassung ~Zeile 734)

### 3. Konfigurierbarer Snapshot-Modus

Neues Feld `snapshot_mode` in `config.json`:

| Wert | Verhalten |
|---|---|
| `"full"` (default) | tar.gz-Snapshot wie bisher |
| `"cloud"` | Kein tar.gz — nur Marker + Diff (spart Speicherplatz) |
| `"hybrid"` | tar.gz + Marker (maximale Sicherheit) |

**Dateien**: `config.json`, `wsl-ai-start.sh` (Snapshot-Logik Zeilen 581-608)

**Hinweis**: Bei `snapshot_mode: "cloud"` ist der Replay-Modus nicht verfuegbar, da kein lokaler Snapshot existiert. Entsprechende Warnung anzeigen.

### 4. Cloud-Hinweis nach Session-Ende

Provider-spezifischer Hinweis in der Session-Ausgabe:

- **OneDrive**: `Rechtsklick auf Datei > Versionsverlauf fuer aeltere Staende`
- **Google Drive**: `Rechtsklick > Versionsverlauf verwalten`
- **Dropbox**: `Rechtsklick > Versionsverlauf`
- **Lokal**: Kein Hinweis (tar.gz-Snapshots reichen)

**Datei**: `wsl-ai-start.sh` (nach Session-Info-Ausgabe ~Zeile 756)

## Versionierungs-Limits der Cloud-Provider

| Provider | Aufbewahrung | Versionen |
|---|---|---|
| OneDrive | 30 Tage (M365: laenger) | bis 500 |
| Google Drive | 30 Tage | bis 100 |
| Dropbox Basic | 30 Tage | unbegrenzt |
| Dropbox Professional | 180 Tage | unbegrenzt |

## Spaetere Erweiterung (Optional)

Aktive API-Integration ueber Microsoft Graph / Google Drive API / Dropbox API:
- Versionen per CLI auflisten (`agentbox --versions MyProject`)
- Auf Cloud-Version zuruecksetzen (`agentbox --restore MyProject 2026-04-11`)
- Versionen benennen/pinnen

Aufwand: Hoch (OAuth2-Authentifizierung, Provider-SDKs). Erst sinnvoll wenn Rollback-per-API ein haeufiger Use-Case wird.
