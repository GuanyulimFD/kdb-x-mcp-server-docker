#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# start_kdbx.sh  -  Start a KDB-X service
#
# Usage:
#   ./scripts/start_kdbx.sh [port] [log_file]
#
# Options:
#   port       (optional) override the default port 5000
#   log_file   (optional) absolute/relative path to an existing log file to
#              APPEND to instead of creating a new kdbx_<timestamp>.log.
#              Pass this when you want the q process output to share the
#              same file as the Python MCP server (see scripts/start_all.sh).
#
# Environment variables (override auto-detection):
#   Q_BINARY   Absolute path to the q binary, e.g. /home/user/q/l64/q
#   QHOME      Standard KDB-X home directory
#   KDBX_LOG_FILE  Same as the log_file argument; argument takes precedence
# ---------------------------------------------------------------------------

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INIT_SCRIPT="$REPO_ROOT/scripts/kdbx_init.q"
LOG_DIR="$REPO_ROOT/logs"
PORT="${1:-5000}"
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"

# Resolve log file: explicit arg > KDBX_LOG_FILE env var > own timestamped file
if [[ -n "${2:-}" ]]; then
    LOG_FILE="${2}"
elif [[ -n "${KDBX_LOG_FILE:-}" ]]; then
    LOG_FILE="${KDBX_LOG_FILE}"
else
    LOG_FILE="$LOG_DIR/kdbx_${TIMESTAMP}.log"
fi

PID_FILE="$LOG_DIR/kdbx.pid"

# ---------------------------------------------------------------------------
# Ensure the KDB-X default installer path is always on PATH
# (~/.kx/bin is added to .zshrc by the official installer but may not be
# present when the script is run non-interactively, e.g. via cron/nohup)
# ---------------------------------------------------------------------------
export PATH="$HOME/.kx/bin:$PATH"

# ---------------------------------------------------------------------------
# Locate the q binary
# ---------------------------------------------------------------------------
find_q_binary() {
    # 1. Explicit override via environment variable
    if [[ -n "${Q_BINARY:-}" && -x "$Q_BINARY" ]]; then
        echo "$Q_BINARY"
        return
    fi

    # 2. KDB-X official installer default (macOS & Linux)
    if [[ -x "$HOME/.kx/bin/q" ]]; then
        echo "$HOME/.kx/bin/q"
        return
    fi

    # 3. Derive from QHOME (standard KDB-X layout: $QHOME/<arch>/q)
    if [[ -n "${QHOME:-}" ]]; then
        local arch
        case "$(uname -sm)" in
            "Darwin arm64")  arch="m64" ;;
            "Darwin x86_64") arch="m64" ;;
            "Linux x86_64")  arch="l64" ;;
            "Linux aarch64") arch="l64arm" ;;
            *)               arch="" ;;
        esac
        if [[ -n "$arch" && -x "$QHOME/$arch/q" ]]; then
            echo "$QHOME/$arch/q"
            return
        fi
    fi

    # 4. Fallback install locations
    local candidates=(
        "$HOME/q/m64/q"
        "$HOME/q/l64/q"
        "$HOME/q/l64arm/q"
        "$HOME/.local/q/m64/q"
        "$HOME/.local/q/l64/q"
        "/usr/local/q/m64/q"
        "/usr/local/q/l64/q"
        "/opt/kdb-x/bin/q"
    )
    for candidate in "${candidates[@]}"; do
        if [[ -x "$candidate" ]]; then
            echo "$candidate"
            return
        fi
    done

    # 5. Last resort – find q in PATH (skips shell aliases)
    local resolved
    resolved="$(command -v q 2>/dev/null)" || true
    if [[ -n "$resolved" && -x "$resolved" ]]; then
        echo "$resolved"
        return
    fi

    echo ""
}

Q_BIN="$(find_q_binary)"

if [[ -z "$Q_BIN" ]]; then
    echo "ERROR: Could not locate the q binary." >&2
    echo "" >&2
    echo "Fix options:" >&2
    echo "  1. Set Q_BINARY=/path/to/your/q before running this script" >&2
    echo "  2. Set QHOME=/path/to/your/q-home before running this script" >&2
    echo "  3. Ensure q is on your PATH" >&2
    echo "" >&2
    echo "  Install KDB-X from: https://developer.kx.com/products/kdb-x/install" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Check for an existing service on the same port
# ---------------------------------------------------------------------------
if lsof -iTCP:"$PORT" -sTCP:LISTEN -t &>/dev/null; then
    echo "WARNING: A process is already listening on port $PORT." >&2
    echo "         Stop it before starting a new KDB-X service, or pass a" >&2
    echo "         different port: ./scripts/start_kdbx.sh <port>" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Prepare log directory
# ---------------------------------------------------------------------------
mkdir -p "$LOG_DIR"

# ---------------------------------------------------------------------------
# Launch KDB-X as a background service
# ---------------------------------------------------------------------------
echo "Starting KDB-X service..."
echo "  Binary   : $Q_BIN"
echo "  Init     : $INIT_SCRIPT"
echo "  Port     : $PORT"
echo "  Log      : $LOG_FILE"
echo ""

# Write a separator so the KDB-X section is clearly identifiable in a shared log
mkdir -p "$(dirname "$LOG_FILE")"
{
    echo ""
    echo "================================================================================="
    echo "[kdbx] KDB-X process starting — $(date '+%Y-%m-%d %H:%M:%S') — port $PORT — PID $$"
    echo "================================================================================="
} >> "$LOG_FILE" 2>&1

nohup "$Q_BIN" "$INIT_SCRIPT" -p "$PORT" \
    >> "$LOG_FILE" 2>&1 &

KDB_PID=$!
echo "$KDB_PID" > "$PID_FILE"

# Give q a moment to start and confirm it is still running
sleep 1
if ! kill -0 "$KDB_PID" 2>/dev/null; then
    echo "ERROR: KDB-X process exited immediately. Check log for details:" >&2
    echo "       $LOG_FILE" >&2
    tail -20 "$LOG_FILE" >&2
    exit 1
fi

echo "KDB-X service started successfully (PID $KDB_PID)"
echo "Tail the log in real time with:"
echo "  tail -f $LOG_FILE"
echo ""
echo "To stop the service:"
echo "  kill \$(cat $PID_FILE)"
