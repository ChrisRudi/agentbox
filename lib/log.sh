#!/bin/bash
# log.sh — agentbox Logging-Helper
# Einbinden: . "$CONTROL_DIR/lib/log.sh"
#
# Bewusst klein gehalten. Nur 4 Levels, keine Filter, kein Zielwechsel.
# **Alle Levels auf stdout** — Verhalten identisch zur frueheren
# inline-Definition in wsl-ai-start.sh. Ein Wechsel auf stderr fuer
# WARN/ERROR waere semantisch sauberer, aber User-/Skript-Konsumenten
# koennten sich auf das aktuelle Verhalten verlassen (Pipe in Logfile).
# Aenderung bewusst verschoben, bis ein eigener Stream-Split als
# Ticket drin ist.
#
# ANSI-Farben: wir lassen sie immer drin. wsl-ai-start.sh laeuft
# praktisch immer interaktiv (Host-Terminal / WT / VS Code) oder mit
# `agentbox --auto` in TTY-Umgebung. TTY-Detection koennte in einem
# Nachfolge-Patch fuer CI-Ausgaben kommen.

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
    log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
    log_error() { echo -e "${RED}[FEHLER]${NC} $1"; }
fi
