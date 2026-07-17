#!/bin/bash
# launch-steam-gptk.sh — Launch a Steam game using Apple's Game Porting Toolkit
# GPTK provides D3D12→Metal translation and better game compatibility than stock Wine.
# Usage: ./launch-steam-gptk.sh <appid>

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# Find GPTK Wine
GPTK_APP="/Applications/Game Porting Toolkit.app/Contents/Resources/wine"
if [[ ! -d "$GPTK_APP" ]]; then
    echo "ERROR: Game Porting Toolkit not found at /Applications/Game Porting Toolkit.app" >&2
    echo "       Install it: brew install --cask gcenx/wine/game-porting-toolkit" >&2
    exit 1
fi

WINE_BIN="${GPTK_APP}/bin/wine64"
WINESERVER="${GPTK_APP}/bin/wineserver"
SHARED_PREFIX="${WINEPREFIX:-$HOME/Library/Application Support/Vineport}"
# Drop any inherited bundled-Wine env BEFORE the first GPTK wine run (including
# the one-time prefix init below): Wine 11.7 dylibs/datadir must not leak into
# GPTK's Wine 7.7.
unset DYLD_LIBRARY_PATH WINEDATADIR
# Use a dedicated GPTK prefix so GPTK's Wine (7.7) never reconfigures the bundled
# Wine (11.7) prefix — no version churn. The Steam library is symlinked in, so the
# game's C:\ paths are unchanged.
vineport_gptk_prefix "${SHARED_PREFIX}" "${WINE_BIN}"
WINEPREFIX="${GPTK_PREFIX}"
STEAMAPPS="${WINEPREFIX}/drive_c/Program Files (x86)/Steam/steamapps"

APPID="${1:?Usage: $0 <appid>}"
shift

# ── Find the game directory from appmanifest ─────────────────────────
MANIFEST="${STEAMAPPS}/appmanifest_${APPID}.acf"
if [[ ! -f "$MANIFEST" ]]; then
    echo "ERROR: No appmanifest found for AppID ${APPID}" >&2
    exit 1
fi

INSTALL_DIR=$(sed -n 's/.*"installdir"[[:space:]]*"\([^"]*\)".*/\1/p' "$MANIFEST")
GAME_NAME=$(sed -n 's/.*"name"[[:space:]]*"\([^"]*\)".*/\1/p' "$MANIFEST")
GAME_DIR="${STEAMAPPS}/common/${INSTALL_DIR}"

if [[ ! -d "$GAME_DIR" ]]; then
    echo "ERROR: Game directory not found: ${GAME_DIR}" >&2
    exit 1
fi

# Find the game executable: EAC Settings.json (authoritative) then a heuristic
# main-exe scan (Unity top-level, Unreal nested, EAC without a Settings.json).
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

if [[ -z "$GAME_EXE" ]]; then
    echo "ERROR: Could not determine game executable" >&2
    exit 1
fi

# ── GPTK Wine environment ───────────────────────────────────────────
# GPTK translates DirectX → Metal natively via D3DMetal. Force the builtin
# (D3DMetal) DirectX DLLs and clear the bundled-Wine dylib path so that neither
# an inherited override nor the shared prefix's persistent "d3d11=native" (DXVK)
# registry setting can make Wine load DXVK / vkd3d-proton here — those need
# Vulkan, which GPTK's Wine doesn't provide, so they'd fail. "=b" means builtin.
export WINEDLLOVERRIDES="d3d9,d3d10,d3d10core,d3d11,d3d12,d3d12core,dxgi=b"
export WINEPREFIX
export WINEARCH=win64
export WINEDEBUG="${WINEDEBUG:--all}"
export WINEMSYNC=1
export WINEESYNC=1

# Steam API setup
export SteamAppId="${APPID}"
export SteamGameId="${APPID}"
echo "${APPID}" > "${WORK_DIR}/steam_appid.txt"

# EOS anti-cheat null client
export EOS_USE_ANTICHEATCLIENTNULL=1

# ── Kill stale wineserver ────────────────────────────────────────────
"${WINESERVER}" -k 2>/dev/null && sleep 1 || true

# ── Launch ───────────────────────────────────────────────────────────
echo "=== Launching ${GAME_NAME} via GPTK ==="
echo "  Wine    : $("${WINE_BIN}" --version 2>/dev/null || echo 'GPTK')"
echo "  AppID   : ${APPID}"
echo "  Exe     : ${GAME_EXE}"
echo "  Work dir: ${WORK_DIR}"
echo ""

# Auto-dismiss error dialogs
DISMISS_PID=""
if [[ -x "${SCRIPT_DIR}/dismiss-dialogs.sh" ]]; then
    "${SCRIPT_DIR}/dismiss-dialogs.sh" &
    DISMISS_PID=$!
fi

cleanup() {
    [[ -n "$DISMISS_PID" ]] && kill "$DISMISS_PID" 2>/dev/null || true
    rm -f "${WORK_DIR}/steam_appid.txt" 2>/dev/null || true
    "${WINESERVER}" -k 2>/dev/null || true
}
trap cleanup INT TERM HUP

cd "${WORK_DIR}"
"${WINE_BIN}" "./${GAME_EXE}" "$@" || true

"${WINESERVER}" -w || true
[[ -n "$DISMISS_PID" ]] && kill "$DISMISS_PID" 2>/dev/null || true
rm -f "${WORK_DIR}/steam_appid.txt" 2>/dev/null
exit 0
