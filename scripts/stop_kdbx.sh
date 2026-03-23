#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# stop_kdbx.sh  –  Stop the KDB-X service started by start_kdbx.sh
#
# Usage:
#   ./scripts/stop_kdbx.sh [port]
#
# Options:
#   port   (optional) also verify/kill any process still holding the port
# ---------------------------------------------------------------------------

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$REPO_ROOT/logs"
PID_FILE="$LOG_DIR/kdbx.pid"
PORT="${1:-5000}"

stopped=0

# ---------------------------------------------------------------------------
# 1. Kill via PID file
# ---------------------------------------------------------------------------
if [[ -f "$PID_FILE" ]]; then
    KDB_PID="$(cat "$PID_FILE")"
    if [[ -n "$KDB_PID" ]] && kill -0 "$KDB_PID" 2>/dev/null; then
        echo "Stopping KDB-X service (PID $KDB_PID)..."
        kill "$KDB_PID"
        # Wait up to 5 seconds for the process to exit
        for i in {1..10}; do
            if ! kill -0 "$KDB_PID" 2>/dev/null; then
                break
            fi
            sleep 0.5
        done
        if kill -0 "$KDB_PID" 2>/dev/null; then
            echo "Process did not exit cleanly; sending SIGKILL..."
            kill -9 "$KDB_PID" 2>/dev/null || true
        fi
        echo "KDB-X service stopped."
        stopped=1
    else
        echo "PID $KDB_PID from $PID_FILE is not running."
    fi
    rm -f "$PID_FILE"
else
    echo "No PID file found at $PID_FILE."
fi

# ---------------------------------------------------------------------------
# 2. Safety net – kill anything still holding the port
# ---------------------------------------------------------------------------
PORT_PID="$(lsof -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null || true)"
if [[ -n "$PORT_PID" ]]; then
    echo "Process $PORT_PID is still listening on port $PORT – stopping it..."
    kill "$PORT_PID" 2>/dev/null || true
    sleep 1
    if kill -0 "$PORT_PID" 2>/dev/null; then
        kill -9 "$PORT_PID" 2>/dev/null || true
    fi
    echo "Process $PORT_PID on port $PORT stopped."
    stopped=1
fi

if [[ "$stopped" -eq 0 ]]; then
    echo "No KDB-X service found to stop."
fi
