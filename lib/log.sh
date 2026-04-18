#!/bin/bash
# log.sh — agentbox Logging-Helper
# Einbinden: . "$CONTROL_DIR/lib/log.sh"
#
# Bewusst klein gehalten. Nur 4 Levels, keine Filter.
# - log_info / log_ok    → stdout
# - log_warn / log_error → stderr  (seit 2.0.14, Stderr-Split)
#   Damit koennen User Output mit `agentbox 2>errors.log` sauber
#   trennen. Call-Sites mit Follow-up-Zeilen fuegen dort manuell
#   `>&2` hinzu, damit der ganze Block zusammen geht.
#
# ANSI-Farben immer aktiv — wsl-ai-start.sh + wsl-sandbox-init.sh
# laufen praktisch immer in einem TTY (WT, VS Code, agentbox-Shortcut).
# TTY-Detection koennte in einem Nachfolge-Patch fuer CI-Ausgaben
# kommen; heute kein Bedarf.

# Nur definieren, falls noch nicht gesetzt — erlaubt ueberschreiben
# durch spezialisierte Scripts und Re-Source ohne Kollision.
if [ -z "${AGENTBOX_LOG_SH_SOURCED:-}" ]; then
    AGENTBOX_LOG_SH_SOURCED=1

    # ANSI-Farben mit unprefixten Namen, damit das Source ein Drop-in
    # fuer die bisherigen inline-Definitionen in wsl-ai-start.sh ist.
    # Diverse Stellen im Script nutzen RED/GREEN/YELLOW/CYAN/NC direkt
    # ausserhalb der log_*-Funktionen — die bleiben damit funktionsfaehig.
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    NC='\033[0m'

    log_info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
    log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
    log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
    log_error() { echo -e "${RED}[FEHLER]${NC} $1" >&2; }
fi
