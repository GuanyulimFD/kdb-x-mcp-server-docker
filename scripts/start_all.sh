#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# start_all.sh  -  Start KDB-X and the MCP server into a single unified log
#
# Both the KDB-X q process and the Python MCP server write to the same
# timestamped log file so you can monitor everything in one stream without
# interleaving confusion between separate files.
#
# Usage:
#   ./scripts/start_all.sh [kdb_port] [mcp_port]
#
# Defaults:
#   kdb_port  5001
#   mcp_port  8000
#
# Tail the unified log:
#   tail -f logs/kdbx_mcp_<timestamp>.log
#
# Stop everything:
#   ./scripts/stop_kdbx.sh <kdb_port>
#   kill $(lsof -ti TCP:<mcp_port>)
# ---------------------------------------------------------------------------

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$REPO_ROOT/logs"
KDB_PORT="${1:-5001}"
MCP_PORT="${2:-8000}"
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"

# One shared log file for both processes
LOG_FILE="$LOG_DIR/kdbx_mcp_${TIMESTAMP}.log"
mkdir -p "$LOG_DIR"

# Export so that sub-scripts and the MCP server can discover the path
export KDBX_LOG_FILE="$LOG_FILE"

echo ""
echo "============================================================="
echo "  KDB-X MCP Server — unified startup"
echo "  KDB-X port : $KDB_PORT"
echo "  MCP port   : $MCP_PORT"
echo "  Unified log: $LOG_FILE"
echo "============================================================="
echo ""

# ---------------------------------------------------------------------------
# 1. Start KDB-X — appends to the shared log file via the 2nd argument
# ---------------------------------------------------------------------------
"$REPO_ROOT/scripts/start_kdbx.sh" "$KDB_PORT" "$LOG_FILE"

# Brief pause to let q initialise before the MCP server tries to connect
sleep 2

# ---------------------------------------------------------------------------
# 2. Start the MCP server — KDBX_MCP_LOG_FILE points it at the same file
# ---------------------------------------------------------------------------
echo ""
echo "Starting MCP server (port $MCP_PORT) ..."
echo ""

# Write a separator into the shared log so the MCP section is identifiable
{
    echo ""
    echo "================================================================================="
    echo "[mcp] MCP server process starting — $(date '+%Y-%m-%d %H:%M:%S') — port $MCP_PORT"
    echo "================================================================================="
} >> "$LOG_FILE"

export QLIC="${QLIC:-$HOME/.kx}"
export KDBX_MCP_LOG_FILE="$LOG_FILE"

# Run in foreground so Ctrl-C stops everything cleanly.
# stderr goes to the terminal AND the log file via tee so startup errors are
# visible immediately without needing to open a second terminal.
uv --directory "$REPO_ROOT" run mcp-server \
    --db.port "$KDB_PORT" \
    --mcp.port "$MCP_PORT" \
    2>&1 | tee -a "$LOG_FILE"
