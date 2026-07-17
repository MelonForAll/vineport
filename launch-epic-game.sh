#!/bin/bash
# launch-epic-game.sh — Launch an Epic game through Wine.
#
#   --no-eac    Launch the game executable directly for OFFLINE / singleplayer
#               play, without running its anti-cheat. Does not enable online play.
#   (default)   Launch normally via the game's bootstrapper.
#
# Rendering uses Apple's Game Porting Toolkit (D3DMetal) when installed — reliable
# for D3D11 and D3D12 — and falls back to the bundled Wine (DXVK) otherwise.
# Set VINEPORT_NO_GPTK=1 to force the bundled Wine.
#
# Usage: ./launch-epic-game.sh <game-dir> [--no-eac] [-- extra args...]

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

vineport_resolve_prefix
vineport_resolve_wine "${SCRIPT_DIR}"

GAME_DIR="${1:?Usage: $0 <game-dir> [--no-eac] [-- extra args...]}"
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

# ── Find the game executable ─────────────────────────────────────────
# EAC Settings.json is authoritative; otherwise fall back to the heuristic
# main-exe finder (handles Unity/Unreal layouts and games without a Settings.json).
SETTINGS_JSON=$(find "${GAME_DIR}" -maxdepth 5 -ipath "*/EasyAntiCheat/settings.json" -print -quit 2>/dev/null || true)
GAME_EXE=""
WORK_DIR="${GAME_DIR}"
GAME_TITLE="Game"
if [[ -f "$SETTINGS_JSON" ]]; then
    WORK_DIR="$(dirname "$(dirname "$SETTINGS_JSON")")"
    GAME_EXE=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1], encoding='utf-8-sig'))['executable'])" "$SETTINGS_JSON" 2>/dev/null || echo "")
    GAME_TITLE=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1], encoding='utf-8-sig')).get('title','Game'))" "$SETTINGS_JSON" 2>/dev/null || echo "Game")
fi
if [[ -z "$GAME_EXE" ]]; then
    MAIN_EXE=$(vineport_main_exe "${GAME_DIR}")
    if [[ -n "$MAIN_EXE" ]]; then
        WORK_DIR="$(dirname "$MAIN_EXE")"
        GAME_EXE="$(basename "$MAIN_EXE")"
    fi
fi

# Find the EAC launcher (used by the normal/default launch path)
EAC_EXE=$(find "${WORK_DIR}" -maxdepth 1 -name "*_EAC.exe" -print -quit 2>/dev/null || true)

# ── Wine selection + environment ─────────────────────────────────────
vineport_export_base_env
# Resolve legendary from the current PATH before the GPTK branch replaces it.
LEG_PATH="$(command -v legendary 2>/dev/null || true)"
GPTK_WINE="/Applications/Game Porting Toolkit.app/Contents/Resources/wine/bin/wine64"
if [[ -x "$GPTK_WINE" && "${VINEPORT_NO_GPTK:-0}" != "1" ]]; then
    # Render via GPTK/D3DMetal: force builtin DirectX DLLs and drop the bundled
    # Wine dylib/datadir paths so GPTK uses its own — not the prefix's DXVK.
    WINE_GAME="$GPTK_WINE"
    export WINEDLLOVERRIDES="d3d9,d3d10,d3d10core,d3d11,d3d12,d3d12core,dxgi=b"
    unset DYLD_LIBRARY_PATH
    unset WINEDATADIR
    export PATH="$(dirname "$GPTK_WINE"):/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"
    echo "Rendering via Game Porting Toolkit (D3DMetal)."
else
    WINE_GAME="${WINE_BIN}/wine"
    export WINEDLLOVERRIDES="d3d11,d3d10core=n,b;${WINEDLLOVERRIDES:-}"
fi

# ── Launch mode selection ────────────────────────────────────────────

if [[ $NO_EAC -eq 1 ]]; then
    # ── Direct launch for offline / singleplayer (no anti-cheat) ─────
    echo "=== Launching ${GAME_TITLE} (Offline / No Anti-Cheat) ==="
    echo "  Executable : ${GAME_EXE}"
    echo "  Working dir: ${WORK_DIR}"
    echo ""

    if [[ -z "$GAME_EXE" ]]; then
        echo "ERROR: Could not determine game executable." >&2
        exit 1
    fi

    # EOS SDK: null anti-cheat client (offline only).
    export EOS_USE_ANTICHEATCLIENTNULL=1

    # Locate legendary to fetch Epic auth tokens (some games need them offline).
    LEG_CMD=""
    for _leg in ${LEG_PATH:+"$LEG_PATH"} legendary "$HOME/.local/bin/legendary" \
                /Library/Frameworks/Python.framework/Versions/*/bin/legendary \
                "$HOME"/Library/Python/*/bin/legendary; do
        if command -v "$_leg" >/dev/null 2>&1 || [[ -x "$_leg" ]]; then
            LEG_CMD="$_leg"
            break
        fi
    done

    AUTH_ARGS=()
    if [[ -n "$LEG_CMD" ]]; then
        GAME_FOLDER="$(basename "$(dirname "$(dirname "$WORK_DIR")")")"
        LEG_APP=$($LEG_CMD list-installed 2>/dev/null | grep -i "$GAME_FOLDER" | awk '{print $1}' | head -1 || true)
        if [[ -n "$LEG_APP" ]]; then
            echo "Getting Epic auth token (app: ${LEG_APP})..."
            LAUNCH_CMD=$($LEG_CMD launch "$LEG_APP" \
                --wine "${WINE_GAME}" \
                --wine-prefix "${WINEPREFIX}" \
                --dry-run 2>&1 | grep "Launch parameters:" | sed 's/.*Launch parameters: //' || true)
            if [[ -n "$LAUNCH_CMD" ]]; then
                while IFS= read -r tok; do
                    [[ -n "$tok" ]] && AUTH_ARGS+=("$tok")
                done < <(printf '%s\n' "$LAUNCH_CMD" | grep -oE '\-(AUTH_[^ ]+|epic[^ ]+|EpicPortal)')
                echo "Auth tokens acquired."
            fi
        fi
    fi
    [[ ${#AUTH_ARGS[@]} -eq 0 ]] && echo "Note: no Epic auth tokens (online services may be unavailable)."

    cd "${WORK_DIR}"
    echo "Launching ${GAME_EXE} (offline)..."
    echo ""
    exec "${WINE_GAME}" "./${GAME_EXE}" ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} "${EXTRA_ARGS[@]}"

else
    # ── Normal launch (default) ──────────────────────────────────────
    echo "=== Launching ${GAME_TITLE} ==="

    if [[ -n "$EAC_EXE" ]]; then
        cd "${WORK_DIR}"
        exec "${WINE_GAME}" "$(basename "${EAC_EXE}")" "${EXTRA_ARGS[@]}"
    elif [[ -n "$GAME_EXE" ]]; then
        cd "${WORK_DIR}"
        exec "${WINE_GAME}" "./${GAME_EXE}" "${EXTRA_ARGS[@]}"
    else
        echo "ERROR: No executable found in ${WORK_DIR}" >&2
        exit 1
    fi
fi
