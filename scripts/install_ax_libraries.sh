#!/usr/bin/env bash
# =============================================================================
#  install_ax_libraries.sh
#
#  Installs the KX ax-libraries (qcumber, qlint, profiler, etc.) so that
#  qcumber-based unit tests work without a manual ~/developer-* install.
#
#  Official installation reference:
#    https://code.kx.com/developer/libraries/#installation
#
#  Default destination: ~/.kx/ax-libraries/
#   - Sits alongside ~/.kx/bin/q — the standard KX tooling home.
#   - No AXLIBRARIES_HOME env var needed; the MCP server auto-detects it.
#   - Works for every project on the machine (install once, use everywhere).
#
#  Override destination:
#    --dest <path>    Install to an explicit directory.
#    --project        Shorthand for --dest <project_root>/vendor/ax-libraries
#                     (pins ax-libraries to this repo — useful for CI or
#                      fully self-contained deployments).
#
#  Steps performed:
#    1. Locate the source ax-libraries directory (positional arg, env var, or
#       the common ~/developer-*-<os>/ax-libraries glob).
#    2. Copy it to DEST.
#    3. Detect the host OS/arch and copy OS-specific shared libs from
#       ws/lib/<platform>/ → ws/lib/   (the official step 3).
#    4. On macOS: ad-hoc codesign every .so and .dylib so Gatekeeper allows
#       dlopen without quarantine errors.
#    5. Print a summary.  ~/.kx installs need no env var; other paths are
#       written to .env automatically.
#
#  Usage:
#    ./scripts/install_ax_libraries.sh [OPTIONS] [SOURCE]
#
#  Examples:
#    # Recommended: install to ~/.kx/ax-libraries (auto-discovered by MCP server)
#    ./scripts/install_ax_libraries.sh
#
#    # Explicit source (skip auto-discover)
#    ./scripts/install_ax_libraries.sh ~/developer-1.5.4-osx/ax-libraries
#
#    # From a KX Developer .zip
#    ./scripts/install_ax_libraries.sh ~/Downloads/developer-1.5.4-osx.zip
#
#    # Pin to this project's vendor/ directory (CI / Docker)
#    ./scripts/install_ax_libraries.sh --project
#
#    # Custom destination
#    ./scripts/install_ax_libraries.sh --dest /opt/kx/ax-libraries
#
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------
DEST="${HOME}/.kx/ax-libraries"   # default: standard KX tooling home
SOURCE_ARG=""

while [[ $# -gt 0 ]]; do
    case "${1}" in
        --project)
            DEST="${PROJECT_ROOT}/vendor/ax-libraries"
            shift
            ;;
        --dest)
            DEST="${2}"
            shift 2
            ;;
        --dest=*)
            DEST="${1#--dest=}"
            shift
            ;;
        -*)
            echo "❌ Unknown option: ${1}" >&2
            echo "   Usage: $0 [--project | --dest PATH] [SOURCE]" >&2
            exit 1
            ;;
        *)
            SOURCE_ARG="${1}"
            shift
            ;;
    esac
done

# ---------------------------------------------------------------------------
# 1. Resolve source ax-libraries directory
# ---------------------------------------------------------------------------
resolve_source() {
    local arg="${1:-}"

    # --- Explicit argument ---
    if [[ -n "${arg}" ]]; then
        if [[ "${arg}" == *.zip ]]; then
            echo "▶ Extracting zip: ${arg}" >&2
            local tmp_extract
            tmp_extract="$(mktemp -d)"
            unzip -q "${arg}" -d "${tmp_extract}"
            # Handle: zip contains a developer-*/ folder → find ax-libraries inside
            local found
            found="$(find "${tmp_extract}" -maxdepth 3 -type d -name "ax-libraries" | head -1)"
            if [[ -z "${found}" ]]; then
                # Maybe ax-libraries.zip is nested
                local nested_zip
                nested_zip="$(find "${tmp_extract}" -maxdepth 3 -name "ax-libraries.zip" | head -1)"
                if [[ -n "${nested_zip}" ]]; then
                    local tmp2
                    tmp2="$(mktemp -d)"
                    unzip -q "${nested_zip}" -d "${tmp2}"
                    found="${tmp2}/ax-libraries"
                fi
            fi
            if [[ -z "${found}" || ! -d "${found}" ]]; then
                echo "❌ Could not locate ax-libraries directory inside ${arg}" >&2
                exit 1
            fi
            echo "${found}"
            return
        fi

        if [[ -d "${arg}" ]]; then
            # Could be the ax-libraries dir itself or the developer-* root
            if [[ "$(basename "${arg}")" == "ax-libraries" ]]; then
                echo "${arg}"
            elif [[ -d "${arg}/ax-libraries" ]]; then
                echo "${arg}/ax-libraries"
            else
                echo "❌ '${arg}' is not an ax-libraries directory and has no ax-libraries subdirectory." >&2
                exit 1
            fi
            return
        fi

        echo "❌ Source not found: ${arg}" >&2
        exit 1
    fi

    # --- AXLIBRARIES_HOME env var ---
    if [[ -n "${AXLIBRARIES_HOME:-}" && -d "${AXLIBRARIES_HOME}" ]]; then
        echo "${AXLIBRARIES_HOME}"
        return
    fi

    # --- Glob: ~/developer-*-osx/ax-libraries  ~/developer-*-linux/ax-libraries ---
    local pattern
    for pattern in \
        "${HOME}/developer-"*"-osx/ax-libraries" \
        "${HOME}/developer-"*"-linux/ax-libraries" \
        "${HOME}/developer-"*/ax-libraries \
        "${HOME}/.kx/developer-"*/ax-libraries; do
        # Expand the glob manually (set -e means we must not fail on no match)
        local match
        for match in ${pattern}; do
            [[ -d "${match}" ]] && echo "${match}" && return
        done
    done

    echo "❌ Could not auto-discover ax-libraries." >&2
    echo "   Pass the path explicitly:" >&2
    echo "   ./scripts/install_ax_libraries.sh /path/to/developer-1.5.4-osx/ax-libraries" >&2
    echo "   Or set AXLIBRARIES_HOME before running this script." >&2
    exit 1
}

SOURCE="$(resolve_source "${SOURCE_ARG}")"
echo "✔ Source ax-libraries: ${SOURCE}"
echo "✔ Destination        : ${DEST}"

# ---------------------------------------------------------------------------
# 2. Copy to DEST
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "${DEST}")"

if [[ -d "${DEST}" ]]; then
    echo "⚠ ${DEST} already exists — replacing."
    rm -rf "${DEST}"
fi

echo "▶ Copying to ${DEST} ..."
cp -R "${SOURCE}" "${DEST}"
echo "✔ Copied."

# ---------------------------------------------------------------------------
# 3. Detect OS/arch and copy platform-specific shared libs to ws/lib/
#    Official step: copy ws/lib/<platform>/* → ws/lib/
# ---------------------------------------------------------------------------
detect_platform_dir() {
    local os arch
    os="$(uname -s)"
    arch="$(uname -m)"

    case "${os}" in
        Darwin)
            # ax-libraries ships osx_x64 (Intel/Rosetta) only for macOS
            echo "osx_x64"
            ;;
        Linux)
            # Try to pick the closest match shipped in the package
            local distro_id="" arch
            arch="$(uname -m)"
            if [[ -f /etc/os-release ]]; then
                distro_id="$(. /etc/os-release && echo "${ID:-}")"
            fi

            # ARM64 (aarch64): only ubuntu16_arm64 is bundled in ax-libraries.
            # Covers: Apple Silicon Docker (aarch64), AWS Graviton, Raspberry Pi 4.
            # ubuntu16_arm64 glibc symbols are old enough to run on any modern
            # ARM64 Linux (Debian 11/12, Ubuntu 20/22, RHEL 8+ aarch64).
            if [[ "${arch}" == "aarch64" || "${arch}" == "arm64" ]]; then
                echo "ubuntu16_arm64"
                return
            fi

            # x86_64 — pick by distro
            case "${distro_id}" in
                rhel|centos|rocky|almalinux)
                    local ver
                    ver="$(. /etc/os-release && echo "${VERSION_ID:-8}" | cut -d. -f1)"
                    echo "rhel${ver}_x64"
                    ;;
                ubuntu)
                    local ver
                    ver="$(. /etc/os-release && echo "${VERSION_ID:-20.04}" | cut -d. -f1)"
                    # Map to closest bundled version (ubuntu16, ubuntu18, ubuntu20)
                    if   [[ "${ver}" -ge 20 ]]; then echo "ubuntu20_x64"
                    elif [[ "${ver}" -ge 18 ]]; then echo "ubuntu18_x64"
                    else                             echo "ubuntu16_x64"
                    fi
                    ;;
                *)
                    # Default: ubuntu20_x64 — works on most modern x86_64 Linuxes
                    echo "ubuntu20_x64"
                    ;;
            esac
            ;;
        *)
            echo "ubuntu20_x64"
            ;;
    esac
}

LIB_DIR="${DEST}/ws/lib"
PLATFORM_DIR="$(detect_platform_dir)"
PLATFORM_SRC="${LIB_DIR}/${PLATFORM_DIR}"

echo "▶ Platform directory: ${PLATFORM_DIR}"

if [[ -d "${PLATFORM_SRC}" ]]; then
    echo "▶ Copying platform-specific libs from ${PLATFORM_SRC} → ${LIB_DIR} ..."
    # Copy all files (overwrite), keep directory structure intact.
    # Use rsync if available (handles identical-inode files gracefully); fall
    # back to a cp loop that skips files which are already identical hard-links.
    if command -v rsync &>/dev/null; then
        rsync -a --no-times --checksum "${PLATFORM_SRC}/" "${LIB_DIR}/" && echo "   rsync complete."
    else
        find "${PLATFORM_SRC}" -maxdepth 1 -type f | while read -r f; do
            dest_file="${LIB_DIR}/$(basename "${f}")"
            # Skip when source and destination are the same inode (macOS identical error)
            if [[ -f "${dest_file}" ]] && [[ "$(stat -f '%i' "${f}" 2>/dev/null || stat -c '%i' "${f}" 2>/dev/null)" == "$(stat -f '%i' "${dest_file}" 2>/dev/null || stat -c '%i' "${dest_file}" 2>/dev/null)" ]]; then
                echo "   skipped (same inode): $(basename "${f}")"
                continue
            fi
            cp -f "${f}" "${dest_file}" && echo "   copied: $(basename "${f}")" || echo "   ⚠ failed: $(basename "${f}")"
        done
    fi
    echo "✔ Platform libs installed."
else
    echo "⚠ Platform directory '${PLATFORM_DIR}' not found in ${LIB_DIR}."
    echo "  Available: $(ls "${LIB_DIR}" | tr '\n' ' ')"
    echo "  Skipping platform-lib copy step — native libs may not load correctly."
fi

# ---------------------------------------------------------------------------
# 4. Linux only: copy .so files to $QHOME/<arch>/ so q's 2: operator can
#    find them without needing LD_LIBRARY_PATH.
#    q resolves `2: (`libname; ...) as $QHOME/<arch>/libname.so.
#    $QHOME defaults to the parent of the q binary directory (~/.kx when the
#    binary lives at ~/.kx/bin/q).
# ---------------------------------------------------------------------------
if [[ "$(uname -s)" == "Linux" ]]; then
    # Derive QHOME: parent of the directory containing the q binary.
    Q_BIN="$(command -v q 2>/dev/null || echo "${HOME}/.kx/bin/q")"
    if [[ -x "${Q_BIN}" ]]; then
        QHOME_DIR="$(cd "$(dirname "${Q_BIN}")/.." && pwd)"
        QARCH="$(uname -m)"
        # Map machine name to q arch dir name
        case "${QARCH}" in
            aarch64|arm64) QARCH_DIR="l64arm" ;;
            x86_64)        QARCH_DIR="l64"    ;;
            *)             QARCH_DIR="l64"    ;;
        esac
        Q_LIB_DIR="${QHOME_DIR}/${QARCH_DIR}"
        PLATFORM_SRC_ABS="${DEST}/ws/lib/${PLATFORM_DIR}"
        if [[ -d "${PLATFORM_SRC_ABS}" ]]; then
            echo "▶ Copying .so files to q arch dir ${Q_LIB_DIR} ..."
            mkdir -p "${Q_LIB_DIR}"
            find "${PLATFORM_SRC_ABS}" -maxdepth 1 -name "*.so*" -type f | while read -r f; do
                dest_file="${Q_LIB_DIR}/$(basename "${f}")"
                if [[ -f "${dest_file}" ]] && \
                   [[ "$(stat -c '%i' "${f}" 2>/dev/null)" == "$(stat -c '%i' "${dest_file}" 2>/dev/null)" ]]; then
                    echo "   skipped (same inode): $(basename "${f}")"
                    continue
                fi
                cp -f "${f}" "${dest_file}" && echo "   copied: $(basename "${f}")" || \
                    echo "   ⚠ failed: $(basename "${f}")"
            done
            echo "✔ q arch dir populated: ${Q_LIB_DIR}"
        else
            echo "⚠ Platform source ${PLATFORM_SRC_ABS} not found — skipping q arch dir copy."
        fi
    else
        echo "⚠ q binary not found at ${Q_BIN} — skipping q arch dir copy."
    fi
fi

# ---------------------------------------------------------------------------
# 5. macOS: ad-hoc codesign all .so and .dylib files
#    Required so macOS Gatekeeper allows dlopen without quarantine errors.
#    (Linux codesigning not needed and codesign is macOS-only)
# ---------------------------------------------------------------------------
if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "▶ codesigning shared libraries (macOS Gatekeeper requirement) ..."
    signed=0; failed=0
    while IFS= read -r lib; do
        if codesign -s - --force "${lib}" 2>/dev/null; then
            (( signed++ )) || true
        else
            echo "   ⚠ codesign failed for ${lib}" >&2
            (( failed++ )) || true
        fi
    done < <(find "${LIB_DIR}" -maxdepth 2 \( -name "*.so" -o -name "*.dylib" \))
    echo "✔ Signed ${signed} file(s)${failed:+, ${failed} failed}."
fi

# ---------------------------------------------------------------------------
# 6. Summary
# ---------------------------------------------------------------------------
QCUMBER="${DEST}/ws/qcumber.q_"
if [[ -f "${QCUMBER}" ]]; then
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║  ax-libraries installed successfully                            ║"
    echo "╠══════════════════════════════════════════════════════════════════╣"
    printf "║  Location : %-51s ║\n" "${DEST}"
    printf "║  qcumber  : %s/ws/qcumber.q_\n" "${DEST}"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""

    KX_HOME="${HOME}/.kx/ax-libraries"
    if [[ "${DEST}" == "${KX_HOME}" ]]; then
        # Standard ~/.kx location — auto-discovered by the MCP server.
        # No env var or .env entry needed.
        echo "✔ Installed to the standard KX tooling home (~/.kx/ax-libraries)."
        echo "  The MCP server will find qcumber automatically on next start."
        echo "  No AXLIBRARIES_HOME env var is required."
    else
        # Non-standard location — write AXLIBRARIES_HOME to .env so the server
        # can find it without manual configuration.
        ENV_FILE="${PROJECT_ROOT}/.env"
        if [[ -f "${ENV_FILE}" ]]; then
            if grep -q "AXLIBRARIES_HOME" "${ENV_FILE}"; then
                # Update existing entry
                sed -i.bak "s|^AXLIBRARIES_HOME=.*|AXLIBRARIES_HOME=${DEST}|" "${ENV_FILE}" && rm -f "${ENV_FILE}.bak"
                echo "✔ Updated AXLIBRARIES_HOME in .env → ${DEST}"
            else
                echo "AXLIBRARIES_HOME=${DEST}" >> "${ENV_FILE}"
                echo "✔ Added AXLIBRARIES_HOME to .env"
            fi
        else
            echo "AXLIBRARIES_HOME=${DEST}" > "${ENV_FILE}"
            echo "✔ Created .env with AXLIBRARIES_HOME=${DEST}"
        fi
    fi
else
    echo "⚠ Installation completed but qcumber.q_ not found at expected path."
    echo "  Expected: ${QCUMBER}"
fi
