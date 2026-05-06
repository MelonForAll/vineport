#!/bin/bash
# launch-steam.sh — Open-source Wine launcher for Windows Steam on Apple Silicon
# Uses Wine Staging (LGPL), running under Rosetta 2 on macOS.
# The launcher scripts are MIT-licensed. Steam is proprietary software by Valve.

# ── Paths ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WINE_DIR="${SCRIPT_DIR}/wine"
WINE_BIN="${WINE_DIR}/bin"
WINE_LIB="${WINE_DIR}/lib"

DEFAULT_PREFIX="$HOME/Library/Application Support/WineSteam"
WINEPREFIX="${WINEPREFIX:-${DEFAULT_PREFIX}}"

STEAM_EXE="C:/Program Files (x86)/Steam/steam.exe"

# ── Sanity checks ─────────────────────────────────────────────────────
if [[ ! -x "${WINE_BIN}/wine" ]]; then
    echo "ERROR: wine not found at ${WINE_BIN}/wine" >&2
    echo "       Run the setup script first." >&2
    exit 1
fi

# ── First-run: create prefix and install Steam ────────────────────────
if [[ ! -d "${WINEPREFIX}/drive_c" ]]; then
    echo "First run — creating Wine prefix at ${WINEPREFIX}..."
    echo "This may take a minute."
    export WINEPREFIX
    export WINEDEBUG="-all"
    export WINEDATADIR="${WINE_DIR}/share/wine"
    export DYLD_LIBRARY_PATH="${WINE_LIB}"
    export PATH="${WINE_BIN}:${PATH}"

    # Initialize the 64-bit prefix
    WINEARCH=win64 "${WINE_BIN}/wineboot" --init 2>/dev/null

    # Download and run Steam installer if no Steam.exe exists
    STEAM_PATH="${WINEPREFIX}/drive_c/Program Files (x86)/Steam/steam.exe"
    if [[ ! -f "${STEAM_PATH}" ]]; then
        echo "Downloading Steam installer..."
        if [[ -f "$HOME/Downloads/SteamSetup.exe" ]]; then
            INSTALLER="$HOME/Downloads/SteamSetup.exe"
        else
            INSTALLER="$(mktemp /tmp/SteamSetup.XXXXXX.exe)"
            curl -L -o "${INSTALLER}" "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe" 2>/dev/null
        fi
        echo "Installing Steam (this takes a few minutes)..."
        "${WINE_BIN}/wine" "${INSTALLER}" /S 2>/dev/null
        echo "Steam installed."
    fi

    # Install the webhelper wrapper (injects --no-sandbox --in-process-gpu for Wine compat)
    CEF_DIR="${WINEPREFIX}/drive_c/Program Files (x86)/Steam/bin/cef/cef.win64"
    if [[ -f "${SCRIPT_DIR}/steamwebhelper_wrapper.exe" ]] && [[ -f "${CEF_DIR}/steamwebhelper.exe" ]]; then
        if [[ ! -f "${CEF_DIR}/steamwebhelper_real.exe" ]]; then
            cp "${CEF_DIR}/steamwebhelper.exe" "${CEF_DIR}/steamwebhelper_real.exe"
        fi
        cp "${SCRIPT_DIR}/steamwebhelper_wrapper.exe" "${CEF_DIR}/steamwebhelper.exe"
        echo "Webhelper wrapper installed."
    fi

    echo "Setup complete."
    echo ""
fi

# ── Re-install webhelper wrapper if Steam overwrote it during update ──
WRAPPER_SRC="${SCRIPT_DIR}/steamwebhelper_wrapper.exe"
CEF_DIR="${WINEPREFIX}/drive_c/Program Files (x86)/Steam/bin/cef/cef.win64"
WRAPPER_DST="${CEF_DIR}/steamwebhelper.exe"
REAL_DST="${CEF_DIR}/steamwebhelper_real.exe"
if [[ -f "${WRAPPER_SRC}" ]] && [[ -f "${WRAPPER_DST}" ]]; then
    WRAPPER_SIZE=$(stat -f%z "${WRAPPER_SRC}")
    INSTALLED_SIZE=$(stat -f%z "${WRAPPER_DST}")
    if [[ "${INSTALLED_SIZE}" -ne "${WRAPPER_SIZE}" ]]; then
        echo "Steam update overwrote webhelper wrapper — re-installing..."
        cp "${WRAPPER_DST}" "${REAL_DST}"
        cp "${WRAPPER_SRC}" "${WRAPPER_DST}"
    fi
fi

# ── Wine environment ──────────────────────────────────────────────────
export WINEPREFIX
export WINESERVER="${WINE_BIN}/wineserver"
export WINEARCH=win64
export WINEDATADIR="${WINE_DIR}/share/wine"
export DYLD_LIBRARY_PATH="${WINE_LIB}"
export PATH="${WINE_BIN}:${PATH}"

# ── Performance ────────────────────────────────────────────────────────
export WINEMSYNC="${WINEMSYNC:-1}"
export WINEESYNC="${WINEESYNC:-1}"
export DOTNET_EnableWriteXorExecute=0

# ── Steam CEF rendering fix ───────────────────────────────────────────
# Wine's DXGI/ANGLE doesn't report properly, causing CEF to black-screen.
# Force CEF to use software rendering (SwiftShader) via these overrides.
# This only affects Steam's UI — games use their own rendering path.
export STEAM_DISABLE_GPU_PROCESS=1
export GALLIUM_DRIVER=llvmpipe

# Force CEF to use software rendering with no sandbox.
# These are passed to steamwebhelper child processes via environment.
export STEAM_CEF_COMMAND_LINE="--no-sandbox --in-process-gpu --disable-gpu --disable-gpu-compositing --use-gl=swiftshader --disable-software-rasterizer"

# ── Debug ──────────────────────────────────────────────────────────────
export WINEDEBUG="${WINEDEBUG:--all}"

# ── Kill stale wineserver (prevents "won't start" after unclean shutdown) ─
"${WINESERVER}" -k 2>/dev/null && sleep 1 || true

# ── Launch ─────────────────────────────────────────────────────────────
echo "=== WineSteam (Open Source) ==="
echo "  Wine     : $(${WINE_BIN}/wine --version 2>/dev/null || echo 'unknown')"
echo "  Prefix   : ${WINEPREFIX}"
echo "  WINEMSYNC: ${WINEMSYNC}"
echo "  WINEDEBUG: ${WINEDEBUG}"
echo ""

# Auto-dismiss error dialogs if the script exists
DISMISS_PID=""
if [[ -x "${SCRIPT_DIR}/dismiss-dialogs.sh" ]]; then
    "${SCRIPT_DIR}/dismiss-dialogs.sh" &
    DISMISS_PID=$!
fi

# Clean up on signals (user quit / system shutdown)
cleanup() {
    [[ -n "$DISMISS_PID" ]] && kill $DISMISS_PID 2>/dev/null
    "${WINESERVER}" -k 2>/dev/null
}
trap cleanup INT TERM HUP

# Launch Steam and wait for it to exit
# CEF flags: force software rendering (fixes black screen on non-CrossOver Wine)
"${WINE_BIN}/wine" "${STEAM_EXE}" \
    -cef-disable-gpu \
    -cef-disable-gpu-compositing \
    -cef-in-process-gpu \
    -cef-disable-sandbox \
    -no-cef-sandbox \
    -noverifyfiles -norepairfiles "$@" || true

# Wait for all Wine processes to finish (wineserver stays alive while they run)
"${WINESERVER}" -w || true

# Clean up dismiss-dialogs
[[ -n "$DISMISS_PID" ]] && kill $DISMISS_PID 2>/dev/null
exit 0
