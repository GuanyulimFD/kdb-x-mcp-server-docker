#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# docker/entrypoint.sh
#
# Starts KDB-X and the Python MCP server inside the container.
# Both processes share a single unified log file written to /app/logs/ so
# you can observe everything with one `docker compose logs -f` or by tailing
# the mounted host directory.
#
# Environment variables (all optional, sensible defaults set in Dockerfile):
#   KDBX_DB_PORT          KDB-X q process port            (default: 5001)
#   KDBX_MCP_PORT         MCP HTTP server port            (default: 8000)
#   KDBX_MCP_TRANSPORT    stdio | streamable-http         (default: streamable-http)
#   KDBX_MCP_HOST         MCP bind address                (default: 0.0.0.0)
#   KDBX_MCP_LOG_LEVEL    DEBUG|INFO|WARNING|ERROR        (default: INFO)
#   KDBX_DB_QCUMBER_PATH  path to qcumber.q_ (baked in)
#   KDBX_SKIP_Q_MODULES   set 1 to skip q-modules autoload
# ---------------------------------------------------------------------------

set -euo pipefail

KDB_PORT="${KDBX_DB_PORT:-5001}"
MCP_PORT="${KDBX_MCP_PORT:-8000}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# In the Docker image the entrypoint lives at /entrypoint.sh so the parent
# calculation above resolves to /, but all app files are under /app.
# Detect and correct this so scripts/ and q-modules/ are found correctly.
if [ ! -f "$REPO_ROOT/scripts/start_kdbx.sh" ] && [ -f /app/scripts/start_kdbx.sh ]; then
    REPO_ROOT=/app
fi
LOG_DIR="$REPO_ROOT/logs"
mkdir -p "$LOG_DIR"

# One unified log file for both the q process and the MCP server.
# Naming matches the pattern used by start_all.sh so tooling is consistent.
LOG_TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
UNIFIED_LOG="$LOG_DIR/kdbx_mcp_${LOG_TIMESTAMP}.log"

# Print the log path to docker stdout so it is immediately visible in
# `docker compose logs` even before the log file accumulates content.
echo "============================================================="
echo "  KDB-X MCP Server - Docker startup"
echo "  KDB-X port   : $KDB_PORT"
echo "  MCP port     : $MCP_PORT"
echo "  Transport    : ${KDBX_MCP_TRANSPORT:-streamable-http}"
echo "  q binary     : $(command -v q 2>/dev/null || echo 'not found')"
echo "  qcumber      : ${KDBX_DB_QCUMBER_PATH:-not set}"
echo "  Unified log  : $UNIFIED_LOG"
echo "  (also tailable from host at the mounted logs/ directory)"
echo "============================================================="

# Write the banner to the log file too so the file starts with context
{
    echo "================================================================================="
    echo "[entrypoint] Container started at $(date '+%Y-%m-%d %H:%M:%S')"
    echo "[entrypoint] KDB-X port: $KDB_PORT  |  MCP port: $MCP_PORT  |  log: $UNIFIED_LOG"
    echo "================================================================================="
} >> "$UNIFIED_LOG"

# ---------------------------------------------------------------------------
# 1. Start KDB-X
#    Pass the unified log as the second argument so q output lands in the
#    same file (see start_kdbx.sh -- it honours this arg over KDBX_LOG_FILE).
# ---------------------------------------------------------------------------
echo ""
echo "Starting KDB-X on port $KDB_PORT ..."
export KDBX_LOG_FILE="$UNIFIED_LOG"
bash "$REPO_ROOT/scripts/start_kdbx.sh" "$KDB_PORT" "$UNIFIED_LOG"

# Give q time to fully initialise before pykx tries to connect
sleep 2

# ---------------------------------------------------------------------------
# 2. Start the MCP server (foreground - PID 1 after exec)
#    --mcp.log-file directs Python logging to the same unified log file,
#    giving a single, interleaved, time-ordered view of the whole system.
# ---------------------------------------------------------------------------
echo ""
echo "Starting MCP server on port $MCP_PORT ..."
echo "[entrypoint] Starting MCP server at $(date '+%Y-%m-%d %H:%M:%S')" >> "$UNIFIED_LOG"

exec /app/.venv/bin/mcp-server \
    --db.port     "$KDB_PORT" \
    --db.host     "127.0.0.1" \
    --mcp.host    "${KDBX_MCP_HOST:-0.0.0.0}" \
    --mcp.port    "$MCP_PORT" \
    --mcp.transport "${KDBX_MCP_TRANSPORT:-streamable-http}" \
    --mcp.log-file  "$UNIFIED_LOG"
