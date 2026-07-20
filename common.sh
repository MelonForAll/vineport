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
        # Fall back to the GUI's Application Support install (older GUI builds
        # put Wine there even for a git clone).
        if [[ ! -x "${WINE_DIR}/bin/wine" \
              && -x "${HOME}/Library/Application Support/Vineport/wine/bin/wine" ]]; then
            WINE_DIR="${HOME}/Library/Application Support/Vineport/wine"
        fi
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

# Watch the game process and clean up if it deadlocks on exit. Some games
# (e.g. Elden Ring) wedge instead of exiting when quit under Wine, leaving a
# captured black fullscreen window behind until someone kills the session.
# A deadlocked process schedules no CPU, so its %cpu decays to 0.0 and stays
# there; live game states (menus, pause, loading, background) always keep
# above zero. Six consecutive 0.0 samples, 10s apart, trigger a wineserver
# shutdown. Set VINEPORT_NO_WATCHDOG=1 to disable. Runs in the background,
# survives exec, and exits by itself once the game is gone.
# Args: $1 = game exe name (pgrep -f pattern). Uses ${WINESERVER}.
vineport_exit_watchdog() {
    [[ "${VINEPORT_NO_WATCHDOG:-0}" != "1" ]] || return 0
    [[ -n "${1:-}" ]] || return 0
    local pattern="$1" server="${WINESERVER}"
    (
        zeros=0
        seen=0
        while sleep 10; do
            pids=$(pgrep -f "$pattern" || true)
            if [[ -z "$pids" ]]; then
                [[ $seen -eq 1 ]] && break   # game ran and exited — done
                continue                      # not started yet
            fi
            seen=1
            cpu=$(ps -o %cpu= -p $pids 2>/dev/null | sort -rn | head -1 | tr -d ' ')
            if [[ "$cpu" == "0.0" ]]; then
                zeros=$((zeros + 1))
            else
                zeros=0
            fi
            if [[ $zeros -ge 6 ]]; then
                echo "Game appears wedged after exit (no CPU for 60s) — cleaning up..."
                "$server" -k 2>/dev/null || true
                break
            fi
        done
    ) &
}

# Optional windowed virtual desktop: set VINEPORT_DESKTOP=1 (auto-size to the
# main display) or VINEPORT_DESKTOP=WxH. The game then renders inside a Wine
# desktop window instead of capturing the display, so other monitors stay
# usable. Sets the DESKTOP_CMD array (empty when disabled) for use as:
#   "${WINE}" ${DESKTOP_CMD[@]+"${DESKTOP_CMD[@]}"} game.exe ...
vineport_desktop_cmd() {
    DESKTOP_CMD=()
    [[ -n "${VINEPORT_DESKTOP:-}" && "${VINEPORT_DESKTOP}" != "0" ]] || return 0
    local res="${VINEPORT_DESKTOP}"
    if [[ ! "$res" =~ ^[0-9]+x[0-9]+$ ]]; then
        res="$(osascript -e 'tell application "Finder" to get bounds of window of desktop' 2>/dev/null \
            | awk -F', ' '{print $3"x"$4}')"
        [[ "$res" =~ ^[0-9]+x[0-9]+$ ]] || res="1920x1080"
    fi
    DESKTOP_CMD=(explorer "/desktop=Vineport,${res}")
    echo "Windowed desktop mode: ${res} (other displays stay usable)."
}

# Kill any stale wineserver for the current prefix (no-op if none running).
vineport_kill_wineserver() {
    "${WINESERVER_BIN}" -k 2>/dev/null && sleep 1 || true
}

# Wait for all wine processes in the prefix to exit (no-op on error).
vineport_wait_wineserver() {
    "${WINESERVER_BIN}" -w 2>/dev/null || true
}

# Set up (once) and select a dedicated GPTK/D3DMetal Wine prefix in GPTK_PREFIX.
# GPTK ships Wine 7.7; giving it its own prefix means it never reconfigures the
# bundled Wine 11.7 prefix (no version churn) and the bundled prefix's DXVK
# overrides can't leak in. The Steam + Epic game libraries are symlinked in so
# games are shared (no re-download) and keep the same C:\ paths.
# Args: $1 = bundled/shared WINEPREFIX, $2 = GPTK wine64 binary. Sets GPTK_PREFIX.
vineport_gptk_prefix() {
    local shared="$1" gptk_wine="$2" gptk_bin
    gptk_bin="$(dirname "$gptk_wine")"
    GPTK_PREFIX="${shared}-gptk"

    if [[ ! -e "${GPTK_PREFIX}/system.reg" ]]; then
        echo "Setting up dedicated GPTK prefix (one-time): ${GPTK_PREFIX}"
        mkdir -p "${GPTK_PREFIX}"
        WINEPREFIX="${GPTK_PREFIX}" WINEDEBUG=-all "${gptk_wine}" wineboot --init >/dev/null 2>&1 || true
        WINEPREFIX="${GPTK_PREFIX}" "${gptk_bin}/wineserver" -w 2>/dev/null || true
        # Share the user profile (saves/AppData) with the bundled prefix so games
        # keep their data whichever Wine launches them. First init only: an
        # existing GPTK prefix may already hold its own user data.
        if [[ -d "${shared}/drive_c/users" && -d "${GPTK_PREFIX}/drive_c" ]]; then
            rm -rf "${GPTK_PREFIX}/drive_c/users"
            ln -sfn "${shared}/drive_c/users" "${GPTK_PREFIX}/drive_c/users"
        fi
    fi

    # Symlink the game libraries from the bundled prefix so games appear on the
    # same Windows paths and aren't duplicated.
    local dc="${GPTK_PREFIX}/drive_c"
    if [[ -d "${shared}/drive_c/Program Files (x86)/Steam" ]]; then
        mkdir -p "${dc}/Program Files (x86)"
        [[ -e "${dc}/Program Files (x86)/Steam" ]] || \
            ln -sfn "${shared}/drive_c/Program Files (x86)/Steam" "${dc}/Program Files (x86)/Steam"
    fi
    if [[ -d "${shared}/drive_c/Epic Games" ]]; then
        [[ -e "${dc}/Epic Games" ]] || \
            ln -sfn "${shared}/drive_c/Epic Games" "${dc}/Epic Games"
    fi
}
