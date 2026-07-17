#!/bin/bash
# Build a clean Wine from source for Vineport.
# Targets x86_64 on macOS (Apple Silicon via Rosetta 2, or native Intel).
# NOTE: the anti-cheat circumvention patches are intentionally not applied here.
#
# Usage: ./build-wine.sh [options]
#   --clean           Clean build artifacts and start fresh
#   --no-staging      Build plain Wine without wine-staging patches
#   --jobs N          Number of parallel build jobs (default: CPU count)
#   --wine-version V  Wine version/tag to build (default: wine-11.7)
#   --output DIR      Output directory (default: ./wine-custom/)
#   --skip-deps       Skip dependency installation
#
# Prerequisites:
#   - Xcode command line tools
#   - Rosetta 2 (Apple Silicon only)
#   - x86_64 Homebrew at /usr/local (install guide below)
#
# To install x86_64 Homebrew (one-time setup):
#   arch -x86_64 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WINE_VERSION="wine-11.7"
WINE_SRC_DIR="${SCRIPT_DIR}/wine-src"
STAGING_SRC_DIR="${SCRIPT_DIR}/wine-staging-src"
BUILD_DIR="${SCRIPT_DIR}/wine-build"
OUTPUT_DIR="${SCRIPT_DIR}/wine-custom"
PATCHES_DIR="${SCRIPT_DIR}/patches"
USE_STAGING=1
CLEAN=0
SKIP_DEPS=0
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

# x86_64 Homebrew prefix (for cross-compilation dependencies on Apple Silicon)
BREW_X86="/usr/local"
BREW_X86_BIN="${BREW_X86}/bin/brew"

# ── Parse arguments ──────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean)        CLEAN=1; shift ;;
        --no-staging)   USE_STAGING=0; shift ;;
        --jobs)         [[ $# -ge 2 ]] || { echo "ERROR: --jobs requires a value" >&2; exit 1; }; JOBS="$2"; shift 2 ;;
        --wine-version) [[ $# -ge 2 ]] || { echo "ERROR: --wine-version requires a value" >&2; exit 1; }; WINE_VERSION="$2"; shift 2 ;;
        --output)       [[ $# -ge 2 ]] || { echo "ERROR: --output requires a value" >&2; exit 1; }; OUTPUT_DIR="$2"; shift 2 ;;
        --skip-deps)    SKIP_DEPS=1; shift ;;
        -h|--help)
            head -18 "$0" | tail -14
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Helpers ──────────────────────────────────────────────────────────────

info()  { echo "==> $*"; }
warn()  { echo "WARNING: $*" >&2; }
die()   { echo "ERROR: $*" >&2; exit 1; }

check_arch() {
    if [[ "$(uname -m)" == "arm64" ]]; then
        # Functional check — pgrep oahd has a false-negative window (oahd is
        # launch-on-demand and only runs after the first x86_64 exec since boot).
        if ! arch -x86_64 /usr/bin/true 2>/dev/null; then
            info "Installing Rosetta 2..."
            softwareupdate --install-rosetta --agree-to-license
        fi
        IS_ARM=1
    else
        IS_ARM=0
    fi
}

# ── Step 1: Check/install dependencies ───────────────────────────────────

install_deps() {
    if [[ $SKIP_DEPS -eq 1 ]]; then
        info "Skipping dependency installation (--skip-deps)"
        return
    fi

    if [[ $IS_ARM -eq 1 ]]; then
        # Need x86_64 Homebrew for cross-compilation
        if [[ ! -x "${BREW_X86_BIN}" ]]; then
            die "x86_64 Homebrew not found at ${BREW_X86_BIN}.
Install it with:
  arch -x86_64 /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        fi
        BREW_CMD="arch -x86_64 ${BREW_X86_BIN}"
    else
        BREW_CMD="brew"
    fi

    info "Installing build dependencies via Homebrew (x86_64)..."
    local deps=(
        mingw-w64
        freetype
        gnutls
        sdl2
        gstreamer
        molten-vk
        bison
        flex
        gettext
        pkg-config
        xz
    )

    # Install missing deps only
    local missing=()
    for dep in "${deps[@]}"; do
        if ! eval "${BREW_CMD} list --formula ${dep}" &>/dev/null; then
            missing+=("${dep}")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        info "Installing: ${missing[*]}"
        eval "${BREW_CMD} install ${missing[*]}"
    else
        info "All dependencies already installed."
    fi
}

# ── Step 2: Clone Wine source ────────────────────────────────────────────

clone_wine() {
    if [[ -d "${WINE_SRC_DIR}/.git" ]]; then
        info "Wine source already cloned at ${WINE_SRC_DIR}"
        cd "${WINE_SRC_DIR}"
        git fetch --tags
        git checkout "${WINE_VERSION}" 2>/dev/null || git checkout "tags/${WINE_VERSION}" 2>/dev/null \
            || die "Could not check out ${WINE_VERSION}. Building the wrong Wine version would silently break compatibility."
        cd "${SCRIPT_DIR}"
    else
        info "Cloning Wine source (tag: ${WINE_VERSION})..."
        # An aborted clone leaves a partial tree without .git that wedges every
        # retry with "destination path already exists" — clear it first.
        if [[ -d "${WINE_SRC_DIR}" ]]; then rm -rf "${WINE_SRC_DIR}"; fi
        git clone --depth=1 --branch "${WINE_VERSION}" \
            https://gitlab.winehq.org/wine/wine.git "${WINE_SRC_DIR}" \
            || {
                # Fallback full clone lands on the default branch — pin it to the tag.
                rm -rf "${WINE_SRC_DIR}"
                git clone https://gitlab.winehq.org/wine/wine.git "${WINE_SRC_DIR}" \
                    || die "Could not clone Wine source. Check your network and retry."
                git -C "${WINE_SRC_DIR}" checkout "${WINE_VERSION}" 2>/dev/null \
                    || git -C "${WINE_SRC_DIR}" checkout "tags/${WINE_VERSION}" 2>/dev/null \
                    || die "Could not check out ${WINE_VERSION}. Building the wrong Wine version would silently break compatibility."
            }
    fi

    if [[ $USE_STAGING -eq 1 ]]; then
        # wine-staging patchsets are version-specific: wine tag "wine-X.Y" pairs
        # with staging tag "vX.Y". A mismatched patchset fails to apply.
        local staging_tag="v${WINE_VERSION#wine-}"
        if [[ -d "${STAGING_SRC_DIR}/.git" ]]; then
            info "Wine-staging source already cloned."
            git -C "${STAGING_SRC_DIR}" fetch --depth=1 origin tag "${staging_tag}" 2>/dev/null || true
            git -C "${STAGING_SRC_DIR}" checkout "${staging_tag}" 2>/dev/null \
                || die "Could not check out wine-staging ${staging_tag} to match ${WINE_VERSION}. Use --no-staging to build without staging patches."
        else
            info "Cloning wine-staging (tag: ${staging_tag})..."
            git clone --depth=1 --branch "${staging_tag}" \
                https://gitlab.winehq.org/wine/wine-staging.git "${STAGING_SRC_DIR}" \
                || git clone --depth=1 --branch "${staging_tag}" \
                    https://github.com/wine-staging/wine-staging.git "${STAGING_SRC_DIR}" \
                || die "Could not clone wine-staging ${staging_tag} to match ${WINE_VERSION}. Use --no-staging to build without staging patches."
        fi
    fi
}

# ── Step 3: Apply patches ────────────────────────────────────────────────

apply_patches() {
    cd "${WINE_SRC_DIR}"

    # Apply wine-staging patchset first
    if [[ $USE_STAGING -eq 1 && -d "${STAGING_SRC_DIR}" ]]; then
        info "Applying wine-staging patches..."
        if [[ -x "${STAGING_SRC_DIR}/staging/patchinstall.py" ]]; then
            python3 "${STAGING_SRC_DIR}/staging/patchinstall.py" DESTDIR="${WINE_SRC_DIR}" --all \
                2>&1 | tail -5
        elif [[ -x "${STAGING_SRC_DIR}/patches/patchinstall.sh" ]]; then
            "${STAGING_SRC_DIR}/patches/patchinstall.sh" DESTDIR="${WINE_SRC_DIR}" --all \
                2>&1 | tail -5
        else
            warn "Could not find wine-staging patchinstall script. Skipping staging patches."
        fi
    fi

    # Apply any custom .patch files (git format).
    # NOTE: the anti-cheat circumvention modifications (patches/apply-anticheat-mods.sh)
    # are intentionally NOT applied. This builds a clean Wine; offline/singleplayer
    # launching without anti-cheat is handled by the launch scripts, not by patching Wine.
    if [[ -d "${PATCHES_DIR}" ]]; then
        local patch_count=0
        for patch in "${PATCHES_DIR}"/*.patch; do
            [[ -f "$patch" ]] || continue
            info "Applying patch: $(basename "$patch")"
            git apply --check "$patch" 2>/dev/null && git apply "$patch" || {
                warn "Patch failed to apply cleanly: $(basename "$patch")"
                warn "Attempting with 3-way merge..."
                git apply --3way "$patch" || {
                    warn "FAILED: $(basename "$patch") — skipping"
                    continue
                }
            }
            patch_count=$((patch_count + 1))
        done

        info "Applied ${patch_count} custom patch(es)."
    fi

    cd "${SCRIPT_DIR}"
}

# ── Step 4: Configure ────────────────────────────────────────────────────

configure_wine() {
    mkdir -p "${BUILD_DIR}"
    cd "${BUILD_DIR}"

    # Set up x86_64 build environment
    if [[ $IS_ARM -eq 1 ]]; then
        export PKG_CONFIG_PATH="${BREW_X86}/lib/pkgconfig:${BREW_X86}/share/pkgconfig"
        export CFLAGS="-arch x86_64 -O2"
        export LDFLAGS="-arch x86_64 -L${BREW_X86}/lib"
        export CPPFLAGS="-I${BREW_X86}/include"
        export PATH="${BREW_X86}/opt/bison/bin:${BREW_X86}/opt/flex/bin:${BREW_X86}/bin:${PATH}"
        CONFIGURE_CMD="arch -x86_64"
    else
        CONFIGURE_CMD=""
    fi

    info "Configuring Wine (x86_64)..."
    ${CONFIGURE_CMD} "${WINE_SRC_DIR}/configure" \
        --prefix="${OUTPUT_DIR}" \
        --enable-archs=x86_64 \
        --with-vulkan \
        --with-freetype \
        --with-gnutls \
        --without-capi \
        --without-oss \
        --without-v4l2 \
        --disable-tests \
        2>&1 | tail -20

    cd "${SCRIPT_DIR}"
}

# ── Step 5: Build ────────────────────────────────────────────────────────

build_wine() {
    cd "${BUILD_DIR}"

    info "Building Wine with ${JOBS} jobs..."
    if [[ $IS_ARM -eq 1 ]]; then
        arch -x86_64 make -j"${JOBS}" 2>&1 | tail -5
    else
        make -j"${JOBS}" 2>&1 | tail -5
    fi

    info "Installing to ${OUTPUT_DIR}..."
    if [[ $IS_ARM -eq 1 ]]; then
        arch -x86_64 make install 2>&1 | tail -3
    else
        make install 2>&1 | tail -3
    fi

    cd "${SCRIPT_DIR}"
}

# ── Step 6: Package output ───────────────────────────────────────────────

package_output() {
    info "Packaging Wine build..."

    # Copy MoltenVK if available (from x86_64 Homebrew)
    local mvk="${BREW_X86}/lib/libMoltenVK.dylib"
    if [[ -f "$mvk" ]]; then
        cp "$mvk" "${OUTPUT_DIR}/lib/"
        info "Bundled MoltenVK."
    else
        warn "MoltenVK not found at ${mvk} — Vulkan support may be limited."
    fi

    info ""
    info "Wine build complete at: ${OUTPUT_DIR}/"
    info ""
    info "To use this build instead of the pre-built one:"
    info "  rm -rf wine/"
    info "  ln -s wine-custom wine"
    info "  ./launch-steam.sh"
    info ""
    info "Or keep both and switch:"
    info "  WINE_DIR=./wine-custom ./launch-steam.sh"
}

# ── Clean ────────────────────────────────────────────────────────────────

do_clean() {
    info "Cleaning build artifacts..."
    # Guard against an empty or root path (e.g. a stray --output / before --clean).
    [[ -n "${BUILD_DIR}"  && "${BUILD_DIR}"  != "/" ]] && rm -rf "${BUILD_DIR}"  || true
    [[ -n "${OUTPUT_DIR}" && "${OUTPUT_DIR}" != "/" ]] && rm -rf "${OUTPUT_DIR}" || true
    # Don't remove wine-src or wine-staging-src — they're cached
    info "Clean. Source trees preserved at wine-src/ and wine-staging-src/."
}

# ── Main ─────────────────────────────────────────────────────────────────

main() {
    echo "╔══════════════════════════════════════════════╗"
    echo "║  Vineport — Build Wine from Source          ║"
    echo "║  Target: x86_64 macOS (clean build)         ║"
    echo "╚══════════════════════════════════════════════╝"
    echo ""

    check_arch

    if [[ $CLEAN -eq 1 ]]; then
        do_clean
        exit 0
    fi

    install_deps
    clone_wine
    apply_patches
    configure_wine
    build_wine
    package_output
}

main "$@"
