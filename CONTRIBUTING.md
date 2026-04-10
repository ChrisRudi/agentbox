# Contributing to agentbox

Danke fuer dein Interesse an agentbox!

## Wie du beitragen kannst

### Bugs melden

1. Oeffne ein [Issue](https://github.com/ChrisRudi/agentbox/issues)
2. Beschreibe: Was hast du erwartet? Was ist passiert?
3. Windows-Version, WSL-Version und welcher Agent (Claude/Codex/Gemini)

### Feature vorschlagen

1. Oeffne ein Issue mit dem Label `enhancement`
2. Beschreibe das Problem, das du loesen willst (nicht nur die Loesung)

### Code beitragen

1. Fork das Repo
2. Erstelle einen Branch: `git checkout -b mein-feature`
3. Halte dich an die bestehenden Konventionen:
   - `win-*` = PowerShell (laeuft auf Windows)
   - `wsl-*` = Bash (laeuft in WSL)
   - Max. 20 kB pro Datei
   - Zeile 1: Dateiname als Kommentar
4. Teste auf einem echten Windows 11 + WSL2 System
5. Oeffne einen Pull Request

### Sicherheitsluecken

Bitte melde Sicherheitsprobleme **nicht** als oeffentliches Issue.
Schreibe stattdessen eine private Nachricht ueber GitHub.

## Regeln

- Keine neuen Abhaengigkeiten (kein Docker, kein Python-Framework, etc.)
- Whitelists nur erweitern wenn es einen klaren Use-Case gibt
- Sicherheit > Features
- Einfachheit > Konfigurierbarkeit

## Entwicklungsumgebung

```bash
# Repo klonen
git clone https://github.com/ChrisRudi/agentbox.git
cd agentbox

# Testen: win-setup.ps1 als Admin in PowerShell ausfuehren
# Dann: WSL oeffnen und wsl-ai-start.sh starten
```

Es gibt keine Build-Pipeline. Die Skripte laufen direkt.
