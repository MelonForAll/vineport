#!/bin/bash
# common.sh — shared helpers for Vineport launch scripts.
#
# Source from a launch script:
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   source "${SCRIPT_DIR}/common.sh"
#
# Centralizes Wine path resolution, prefix detection, environment setup and
# wineserver lifecycle so the launch scripts can't drift out of sync.

# Resolve the Wine install dir for both the git-clone layout and the .app
# bundle layout. Sets: WINE_DIR, WINE_BIN (the bin/ dir), WINE_LIB, WINESERVER_BIN
vineport_resolve_wine() {
    local script_dir="$1"
    if [[ "${script_dir}" == *".app/Contents/Resources"* ]]; then
        WINE_DIR="${HOME}/Library/Application Support/Vineport/wine"
    else
        WINE_DIR="${script_dir}/wine"
    fi
    WINE_BIN="${WINE_DIR}/bin"
    WINE_LIB="${WINE_DIR}/lib"
    WINESERVER_BIN="${WINE_BIN}/wineserver"
}

# Resolve the Wine prefix (respects an externally-set WINEPREFIX).
# Sets: DEFAULT_PREFIX, WINEPREFIX
vineport_resolve_prefix() {
    DEFAULT_PREFIX="${HOME}/Library/Application Support/Vineport"
    WINEPREFIX="${WINEPREFIX:-${DEFAULT_PREFIX}}"
}

# Export the base Wine environment shared by every launch path.
# Requires vineport_resolve_wine + vineport_resolve_prefix to have run first.
vineport_export_base_env() {
    export WINEPREFIX
    export WINEARCH=win64
    export WINEDATADIR="${WINE_DIR}/share/wine"
    export DYLD_LIBRARY_PATH="${WINE_LIB}"
    export PATH="${WINE_BIN}:${PATH}"
    export WINESERVER="${WINESERVER_BIN}"
    export WINEMSYNC="${WINEMSYNC:-1}"
    export WINEESYNC="${WINEESYNC:-1}"
    export WINEDEBUG="${WINEDEBUG:--all}"
}

# Verify the wine binary exists; exit with a clear message if not.
vineport_require_wine() {
    if [[ ! -x "${WINE_BIN}/wine" ]]; then
        echo "ERROR: wine not found at ${WINE_BIN}/wine" >&2
        echo "       Run setup first (open Vineport.app or ./setup.sh)." >&2
        exit 1
    fi
}

# Pick the most likely main game .exe under a directory.
# Usage: exe=$(vineport_main_exe "<game_dir>" [maxdepth])
# Skips known helper/installer/anti-cheat-bootstrap exes; prefers an exe whose
# name matches its folder (Game/Game.exe, .../Binaries/Win64/Game.exe), else the
# largest remaining exe. Prints the full path, or nothing if none found.
vineport_main_exe() {
    local root="$1" maxd="${2:-4}"
    local best="" best_size=0 name_match="" base stem parent rootname size
    rootname="$(basename "$root" | tr '[:upper:]' '[:lower:]')"
    while IFS= read -r exe; do
        [[ -n "$exe" ]] || continue
        base="$(basename "$exe" | tr '[:upper:]' '[:lower:]')"
        case "$base" in
            start_protected_game.exe|*easyanticheat*|*crashhandler*|*crashreport*|\
            *setup*|*unins*|*redist*|*touchup*|*notification*|*be_service*|*beservice*|\
            *epicgameslauncher*|*dxsetup*|*vcredist*|*helper*) continue ;;
        esac
        stem="${base%.exe}"
        parent="$(basename "$(dirname "$exe")" | tr '[:upper:]' '[:lower:]')"
        if [[ "$stem" == "$parent" || "$stem" == "$rootname" ]]; then
            name_match="$exe"
        fi
        size=$(stat -f%z "$exe" 2>/dev/null || echo 0)
        if (( size > best_size )); then best="$exe"; best_size=$size; fi
    done < <(find "$root" -maxdepth "$maxd" -iname "*.exe" 2>/dev/null)
    if [[ -n "$name_match" ]]; then echo "$name_match"; else echo "$best"; fi
}

# Kill any stale wineserver for the current prefix (no-op if none running).
vineport_kill_wineserver() {
    "${WINESERVER_BIN}" -k 2>/dev/null && sleep 1 || true
}

# Wait for all wine processes in the prefix to exit (no-op on error).
vineport_wait_wineserver() {
    "${WINESERVER_BIN}" -w 2>/dev/null || true
}
