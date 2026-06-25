#!/bin/bash
# launch-steam-game.sh — Launch a Steam game's executable directly via Wine for
# OFFLINE / singleplayer play, without running its anti-cheat.
#
# This does not bypass or defeat anti-cheat for online play. It simply runs the
# real game executable with the EOS anti-cheat client nulled, which only works
# offline; online/multiplayer that requires anti-cheat will not connect.
#
# Usage: ./launch-steam-game.sh <appid> [--no-eac] [-- extra args...]
#   --no-eac    Launch the game executable directly (offline, no anti-cheat)
#   (default)   Launch normally via Steam's -applaunch

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

vineport_resolve_prefix
vineport_resolve_wine "${SCRIPT_DIR}"
STEAMAPPS="${WINEPREFIX}/drive_c/Program Files (x86)/Steam/steamapps"

APPID="${1:?Usage: $0 <appid> [--no-eac] [-- extra args...]}"
shift

# Parse flags
NO_EAC=0
EXTRA_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-eac)     NO_EAC=1; shift ;;
        --)           shift; EXTRA_ARGS=("$@"); break ;;
        *)            EXTRA_ARGS+=("$1"); shift ;;
    esac
done

# ── D3D12 → use Game Porting Toolkit (D3DMetal) for offline launches ──
# D3D12 games (e.g. Elden Ring) crash through the bundled vkd3d-proton → MoltenVK
# path on macOS. Apple's GPTK (D3DMetal) runs them reliably. Hand off to the GPTK
# launcher BEFORE setting any bundled-Wine env (WINEDLLOVERRIDES/DYLD_LIBRARY_PATH)
# so GPTK starts in a clean environment and actually uses D3DMetal, not vkd3d.
# Set VINEPORT_NO_GPTK=1 to force the bundled-Wine path instead.
if [[ $NO_EAC -eq 1 ]]; then
    GPTK_WINE="/Applications/Game Porting Toolkit.app/Contents/Resources/wine/bin/wine64"
    if [[ -x "$GPTK_WINE" && "${VINEPORT_NO_GPTK:-0}" != "1" ]]; then
        echo "Game Porting Toolkit detected — launching offline via D3DMetal."
        exec "${SCRIPT_DIR}/launch-steam-gptk.sh" "$APPID" "${EXTRA_ARGS[@]}"
    fi
fi

# ── Find the game directory from appmanifest ─────────────────────────
MANIFEST="${STEAMAPPS}/appmanifest_${APPID}.acf"
if [[ ! -f "$MANIFEST" ]]; then
    echo "ERROR: No appmanifest found for AppID ${APPID}" >&2
    echo "       Expected: ${MANIFEST}" >&2
    exit 1
fi

INSTALL_DIR=$(sed -n 's/.*"installdir"[[:space:]]*"\([^"]*\)".*/\1/p' "$MANIFEST")
GAME_NAME=$(sed -n 's/.*"name"[[:space:]]*"\([^"]*\)".*/\1/p' "$MANIFEST")
GAME_DIR="${STEAMAPPS}/common/${INSTALL_DIR}"

if [[ ! -d "$GAME_DIR" ]]; then
    echo "ERROR: Game directory not found: ${GAME_DIR}" >&2
    exit 1
fi

# ── Find the game executable ─────────────────────────────────────────
# Prefer EAC Settings.json (authoritative for EAC games); otherwise pick the main
# game exe heuristically (handles Unity top-level exes, Unreal nested exes, and
# EAC games that lack a Settings.json). utf-8-sig strips the BOM EAC ships with.
SETTINGS_JSON=$(find "${GAME_DIR}" -maxdepth 5 -ipath "*/EasyAntiCheat/settings.json" -print -quit 2>/dev/null || true)
GAME_EXE=""
WORK_DIR="${GAME_DIR}"
if [[ -f "$SETTINGS_JSON" ]]; then
    GAME_EXE=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1], encoding='utf-8-sig'))['executable'])" "$SETTINGS_JSON" 2>/dev/null || echo "")
    WORK_DIR="$(dirname "$(dirname "$SETTINGS_JSON")")"
fi
if [[ -z "$GAME_EXE" ]]; then
    MAIN_EXE=$(vineport_main_exe "${GAME_DIR}")
    if [[ -n "$MAIN_EXE" ]]; then
        WORK_DIR="$(dirname "$MAIN_EXE")"
        GAME_EXE="$(basename "$MAIN_EXE")"
    fi
fi

# ── Wine environment ─────────────────────────────────────────────────
vineport_export_base_env
# DXVK/vkd3d-proton: native DLLs for Vulkan→MoltenVK→Metal rendering
export WINEDLLOVERRIDES="d3d11,d3d10core,d3d12,d3d12core=n,b;${WINEDLLOVERRIDES:-}"
# EOS SDK: null anti-cheat client (offline/singleplayer only).
export EOS_USE_ANTICHEATCLIENTNULL=1

# ── Launch ───────────────────────────────────────────────────────────

if [[ $NO_EAC -eq 1 ]]; then
    echo "=== Launching ${GAME_NAME} (Offline / No Anti-Cheat) ==="
    echo "  AppID     : ${APPID}"
    echo "  Executable: ${GAME_EXE}"
    echo "  Work dir  : ${WORK_DIR}"
    echo ""

    if [[ -z "$GAME_EXE" ]]; then
        echo "ERROR: Could not determine game executable." >&2
        echo "       No EAC Settings.json found and no obvious exe in game dir." >&2
        exit 1
    fi

    # Some Deck-verified games check these to select a Wine-friendly code path.
    export SteamAppId="${APPID}"
    export SteamGameId="${APPID}"

    # steam_appid.txt lets steam_api64.dll find the running Steam client.
    echo "${APPID}" > "${WORK_DIR}/steam_appid.txt"

    DISMISS_PID=""
    STEAM_BG_PID=""
    cleanup() {
        [[ -n "$DISMISS_PID" ]] && kill "$DISMISS_PID" 2>/dev/null || true
        [[ -n "$STEAM_BG_PID" ]] && kill "$STEAM_BG_PID" 2>/dev/null || true
        rm -f "${WORK_DIR}/steam_appid.txt" 2>/dev/null || true
        vineport_kill_wineserver
    }
    # EXIT included so steam_appid.txt and the background Steam are always cleaned up.
    trap cleanup INT TERM HUP EXIT

    # Kill stale wineserver, then start Steam in the background (for steam_api).
    vineport_kill_wineserver
    STEAM_EXE="${WINEPREFIX}/drive_c/Program Files (x86)/Steam/steam.exe"
    echo "Starting Steam in background..."
    "${WINE_BIN}/wine" "${STEAM_EXE}" -silent -no-browser &
    STEAM_BG_PID=$!
    sleep 8

    # Auto-dismiss error dialogs
    if [[ -x "${SCRIPT_DIR}/dismiss-dialogs.sh" ]]; then
        "${SCRIPT_DIR}/dismiss-dialogs.sh" &
        DISMISS_PID=$!
    fi

    cd "${WORK_DIR}"
    echo "Launching ${GAME_EXE} directly (offline)..."
    echo ""
    "${WINE_BIN}/wine" "./${GAME_EXE}" "${EXTRA_ARGS[@]}" || true

    # Game exited: kill the background Steam we started so the prefix can shut
    # down (otherwise wineserver would stay alive forever waiting on it).
    [[ -n "$STEAM_BG_PID" ]] && kill "$STEAM_BG_PID" 2>/dev/null || true
    exit 0   # EXIT trap runs cleanup()

else
    # Normal launch: delegate to launch-steam.sh with -applaunch
    echo "=== Launching ${GAME_NAME} (Normal, via Steam) ==="
    exec "${SCRIPT_DIR}/launch-steam.sh" -applaunch "${APPID}" "${EXTRA_ARGS[@]}"
fi
