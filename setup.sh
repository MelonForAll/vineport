#!/bin/bash
# WineSteam Setup — Downloads and configures Wine Staging for running Windows Steam on macOS
# Supports Apple Silicon (M1/M2/M3/M4) via Rosetta 2

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WINE_DIR="${SCRIPT_DIR}/wine"
WINE_VERSION="11.7"
WINE_URL="https://github.com/Gcenx/macOS_Wine_builds/releases/download/wine-staging-${WINE_VERSION}/wine-staging-${WINE_VERSION}-osx64.tar.xz"

echo "=== WineSteam Setup ==="
echo ""

# Check architecture
if [[ "$(uname -m)" == "arm64" ]]; then
    # Check Rosetta 2
    if ! /usr/bin/pgrep -q oahd; then
        echo "Installing Rosetta 2 (required for x86_64 Wine)..."
        softwareupdate --install-rosetta --agree-to-license
    fi
    echo "  Platform: Apple Silicon ($(sysctl -n machdep.cpu.brand_string))"
    echo "  Rosetta 2: installed"
else
    echo "  Platform: Intel Mac"
fi
echo ""

# Download Wine if not present
if [[ -d "${WINE_DIR}/bin" ]]; then
    echo "  Wine: already installed at ${WINE_DIR}"
else
    echo "Downloading Wine Staging ${WINE_VERSION}..."

    TARBALL="/tmp/wine-staging-${WINE_VERSION}-osx64.tar.xz"
    if [[ -f "$HOME/Downloads/wine-staging-${WINE_VERSION}-osx64.tar.xz" ]]; then
        TARBALL="$HOME/Downloads/wine-staging-${WINE_VERSION}-osx64.tar.xz"
        echo "  (Using existing download from ~/Downloads)"
    else
        curl -L -o "${TARBALL}" "${WINE_URL}"
    fi

    echo "Extracting..."
    TMPDIR=$(mktemp -d)
    tar xf "${TARBALL}" -C "${TMPDIR}"

    # Find the Wine app bundle inside the extracted archive
    WINE_APP=$(find "${TMPDIR}" -name "Wine Staging.app" -o -name "Wine Devel.app" | head -1)
    if [[ -z "${WINE_APP}" ]]; then
        echo "ERROR: Could not find Wine app in archive" >&2
        exit 1
    fi

    WINE_RESOURCES="${WINE_APP}/Contents/Resources/wine"

    mkdir -p "${WINE_DIR}"
    cp -R "${WINE_RESOURCES}/bin" "${WINE_DIR}/bin"
    cp -R "${WINE_RESOURCES}/lib" "${WINE_DIR}/lib"
    cp -R "${WINE_RESOURCES}/share" "${WINE_DIR}/share"

    rm -rf "${TMPDIR}"

    # Create convenience symlinks
    ln -sf wine/bin "${SCRIPT_DIR}/bin"
    ln -sf wine/lib "${SCRIPT_DIR}/lib"
    ln -sf wine/share "${SCRIPT_DIR}/share"

    echo "  Wine Staging ${WINE_VERSION} installed."
fi

echo ""
echo "Setup complete! Launch Steam with:"
echo "  ./launch-steam.sh"
echo ""
echo "Or double-click WineSteam.app"
echo ""
