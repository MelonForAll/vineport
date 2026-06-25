#!/bin/bash
# launch-steam.sh — Open-source Wine launcher for Windows Steam on Apple Silicon.
# Runs Steam under a custom Wine build via Rosetta 2 on macOS.
# The launcher scripts are MIT-licensed. Steam is proprietary software by Valve.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

vineport_resolve_prefix
vineport_resolve_wine "${SCRIPT_DIR}"

STEAM_EXE="C:/Program Files (x86)/Steam/steam.exe"
STEAMAPPS="${WINEPREFIX}/drive_c/Program Files (x86)/Steam/steamapps"

# ── Sanity checks ─────────────────────────────────────────────────────
vineport_require_wine

# ── First-run: create prefix and install Steam ────────────────────────
if [[ ! -d "${WINEPREFIX}/drive_c" ]]; then
    echo "First run — creating Wine prefix at ${WINEPREFIX}..."
    echo "This may take a minute."
    vineport_export_base_env

    # Initialize the 64-bit prefix
    WINEARCH=win64 "${WINE_BIN}/wineboot" --init 2>/dev/null || true

    # Download and run the Steam installer if no steam.exe exists yet
    STEAM_PATH="${WINEPREFIX}/drive_c/Program Files (x86)/Steam/steam.exe"
    if [[ ! -f "${STEAM_PATH}" ]]; then
        echo "Downloading Steam installer..."
        if [[ -f "$HOME/Downloads/SteamSetup.exe" ]]; then
            INSTALLER="$HOME/Downloads/SteamSetup.exe"
        else
            INSTALLER="$(mktemp /tmp/SteamSetup.XXXXXX.exe)"
            # Remove the temp installer whenever the script exits.
            trap 'rm -f "${INSTALLER}" 2>/dev/null || true' EXIT
            if ! curl -fL -o "${INSTALLER}" \
                 "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe"; then
                echo "ERROR: Failed to download Steam installer. Check your connection and retry." >&2
                exit 1
            fi
        fi
        if [[ ! -s "${INSTALLER}" ]]; then
            echo "ERROR: Steam installer is empty (download failed)." >&2
            exit 1
        fi
        echo "Installing Steam (this takes a few minutes)..."
        "${WINE_BIN}/wine" "${INSTALLER}" /S 2>/dev/null || true
        if [[ ! -f "${STEAM_PATH}" ]]; then
            echo "ERROR: Steam did not install correctly (steam.exe not found)." >&2
            exit 1
        fi
        echo "Steam installed."
    fi

    # Install the webhelper wrapper (forces software rendering for CEF under Wine)
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

# ── Re-install webhelper wrapper if Steam overwrote it during an update ──
WRAPPER_SRC="${SCRIPT_DIR}/steamwebhelper_wrapper.exe"
CEF_DIR="${WINEPREFIX}/drive_c/Program Files (x86)/Steam/bin/cef/cef.win64"
WRAPPER_DST="${CEF_DIR}/steamwebhelper.exe"
REAL_DST="${CEF_DIR}/steamwebhelper_real.exe"
if [[ -f "${WRAPPER_SRC}" ]] && [[ -f "${WRAPPER_DST}" ]]; then
    INSTALLED_SIZE=$(stat -f%z "${WRAPPER_DST}")
    # The real Steam binary is always >1MB; our wrapper is <1MB.
    if [[ "${INSTALLED_SIZE}" -gt 1048576 ]]; then
        echo "Steam update overwrote webhelper wrapper — re-installing..."
        cp "${WRAPPER_DST}" "${REAL_DST}"
        cp "${WRAPPER_SRC}" "${WRAPPER_DST}"
    fi
fi

# ── Wine environment ──────────────────────────────────────────────────
vineport_export_base_env

# ── Performance / .NET ─────────────────────────────────────────────────
export DOTNET_EnableWriteXorExecute=0

# ── Steam CEF rendering fix ───────────────────────────────────────────
# Wine's DXGI/ANGLE doesn't report properly, causing CEF to black-screen.
# Force CEF to use software rendering (SwiftShader). Only affects Steam's UI.
export STEAM_DISABLE_GPU_PROCESS=1
export GALLIUM_DRIVER=llvmpipe
export STEAM_CEF_COMMAND_LINE="--no-sandbox --in-process-gpu --disable-gpu --disable-gpu-compositing --use-gl=swiftshader --disable-software-rasterizer"

# ── DLL overrides ─────────────────────────────────────────────────────
# DXVK (d3d11) + vkd3d-proton (d3d12) for Vulkan→MoltenVK→Metal rendering.
export WINEDLLOVERRIDES="d3d11,d3d10core,d3d12,d3d12core=n,b;${WINEDLLOVERRIDES:-}"

# EOS SDK: use the null anti-cheat client so games that bundle EOS don't crash
# when their anti-cheat can't initialize under Wine. This only enables offline /
# singleplayer play — it does not enable online/multiplayer anti-cheat.
export EOS_USE_ANTICHEATCLIENTNULL=1

# ── Kill stale wineserver (prevents "won't start" after unclean shutdown) ─
vineport_kill_wineserver

# ── Launch ─────────────────────────────────────────────────────────────
echo "=== Vineport (Open Source) ==="
echo "  Wine     : $(${WINE_BIN}/wine --version 2>/dev/null || echo 'unknown')"
echo "  Prefix   : ${WINEPREFIX}"
echo "  WINEMSYNC: ${WINEMSYNC}"
echo "  WINEDEBUG: ${WINEDEBUG}"
echo ""

# Auto-dismiss error dialogs if the helper exists
DISMISS_PID=""
if [[ -x "${SCRIPT_DIR}/dismiss-dialogs.sh" ]]; then
    "${SCRIPT_DIR}/dismiss-dialogs.sh" &
    DISMISS_PID=$!
fi

# Clean up on signals (user quit / system shutdown)
cleanup() {
    [[ -n "$DISMISS_PID" ]] && kill "$DISMISS_PID" 2>/dev/null || true
    vineport_kill_wineserver
}
trap cleanup INT TERM HUP

# Launch Steam and wait for it to exit.
# CEF flags force software rendering (fixes black screen on non-CrossOver Wine).
"${WINE_BIN}/wine" "${STEAM_EXE}" \
    -cef-disable-gpu \
    -cef-disable-gpu-compositing \
    -cef-in-process-gpu \
    -cef-disable-sandbox \
    -no-cef-sandbox \
    -noverifyfiles -norepairfiles "$@" || true

# Wait for all Wine processes to finish (Steam is the foreground process here).
vineport_wait_wineserver

[[ -n "$DISMISS_PID" ]] && kill "$DISMISS_PID" 2>/dev/null || true
exit 0
