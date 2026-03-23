#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/import_and_run.sh
#
# Run this on the TARGET host to load and start the KDB-X MCP server from
# the exported tarball produced by export_image.sh.
#
# Prerequisites on target host:
#   - Docker Engine (any recent version with compose support)
#   - kdbx-mcp-server.tar.gz  (exported by export_image.sh)
#   - kdbx-mcp-server.env     (exported alongside the tarball)
#
# Usage:
#   # Basic — image tarball and env file in current directory
#   bash import_and_run.sh
#
#   # Explicit paths
#   bash import_and_run.sh /path/to/kdbx-mcp-server.tar.gz /path/to/kdbx-mcp-server.env
#
#   # Run on a non-default port
#   MCP_HOST_PORT=9000 bash import_and_run.sh
# ---------------------------------------------------------------------------

set -euo pipefail

TARBALL="${1:-kdbx-mcp-server.tar.gz}"
ENV_FILE="${2:-kdbx-mcp-server.env}"
IMAGE_NAME="kdbx-mcp-server:latest"
CONTAINER_NAME="kdbx-mcp"
MCP_HOST_PORT="${MCP_HOST_PORT:-8000}"
KDBX_DB_PORT="${KDBX_DB_PORT:-5001}"
LOG_DIR="${LOG_DIR_HOST:-./logs}"

echo "============================================================="
echo "  KDB-X MCP Server — import and run"
echo "  Tarball   : $TARBALL"
echo "  Env file  : $ENV_FILE"
echo "  MCP port  : $MCP_HOST_PORT"
echo "============================================================="

# ---------------------------------------------------------------------------
# 1. Verify prerequisites
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker is not installed or not in PATH." >&2
    exit 1
fi

if [ ! -f "$TARBALL" ]; then
    echo "ERROR: Tarball not found: $TARBALL" >&2
    echo "       Copy kdbx-mcp-server.tar.gz to this directory first." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Load image (skip if already loaded with same digest)
# ---------------------------------------------------------------------------
echo ""
echo "[1/3] Loading Docker image from $TARBALL ..."
echo "      (may take ~60s depending on disk speed)"

docker load < "$TARBALL"

echo "      Image loaded: $(docker image inspect $IMAGE_NAME --format '{{.Id}}' | cut -c8-19)"

# ---------------------------------------------------------------------------
# 3. Stop any running instance
# ---------------------------------------------------------------------------
echo ""
echo "[2/3] Stopping any existing container named '$CONTAINER_NAME' ..."
if docker ps -q --filter "name=^${CONTAINER_NAME}$" | grep -q .; then
    docker stop "$CONTAINER_NAME"
    docker rm   "$CONTAINER_NAME"
    echo "      Stopped and removed existing container."
elif docker ps -aq --filter "name=^${CONTAINER_NAME}$" | grep -q .; then
    docker rm "$CONTAINER_NAME"
    echo "      Removed stopped container."
else
    echo "      No existing container found — continuing."
fi

# ---------------------------------------------------------------------------
# 4. Launch the container
# ---------------------------------------------------------------------------
echo ""
echo "[3/3] Starting container '$CONTAINER_NAME' ..."

mkdir -p "$LOG_DIR"

if [ -f "$ENV_FILE" ]; then
    ENV_ARG="--env-file $ENV_FILE"
else
    echo "      WARNING: $ENV_FILE not found — using defaults." >&2
    ENV_ARG=""
fi

# shellcheck disable=SC2086
docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    -p "${MCP_HOST_PORT}:8000" \
    -v "$(pwd)/${LOG_DIR}:/app/logs" \
    --health-cmd "bash -c 'lsof -iTCP:8000 -sTCP:LISTEN -t >/dev/null 2>&1 && lsof -iTCP:5001 -sTCP:LISTEN -t >/dev/null 2>&1'" \
    --health-interval 15s \
    --health-timeout  5s \
    --health-start-period 30s \
    --health-retries 3 \
    $ENV_ARG \
    "$IMAGE_NAME"

echo "      Container started (id: $(docker ps -q --filter name=^${CONTAINER_NAME}$))"
echo "      Waiting up to 45s for healthcheck to report healthy ..."

# Wait loop
WAIT=0
while [ $WAIT -lt 45 ]; do
    STATUS=$(docker inspect --format '{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "starting")
    if [ "$STATUS" = "healthy" ]; then
        break
    fi
    sleep 3
    WAIT=$((WAIT + 3))
done

STATUS=$(docker inspect --format '{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")

if [ "$STATUS" = "healthy" ]; then
    echo ""
    echo "============================================================="
    echo "  Container is HEALTHY"
    echo "  MCP endpoint: http://$(hostname -f 2>/dev/null || hostname):${MCP_HOST_PORT}/mcp"
    echo ""
    echo "  Quick connectivity check:"
    echo "    curl -s http://localhost:${MCP_HOST_PORT}/mcp \\"
    echo "         -H 'Content-Type: application/json' \\"
    echo "         -H 'Accept: application/json, text/event-stream' \\"
    echo "         -d '{\"jsonrpc\":\"2.0\",\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"check\",\"version\":\"1\"}},\"id\":1}'"
    echo ""
    echo "  Tail logs:"
    echo "    docker logs -f $CONTAINER_NAME"
    echo "    tail -f $LOG_DIR/kdbx_mcp_*.log"
    echo "============================================================="
else
    echo ""
    echo "WARNING: Container health status is '$STATUS' after 45s." >&2
    echo "         Check logs for startup errors:" >&2
    echo "           docker logs $CONTAINER_NAME" >&2
    echo "           tail -f $LOG_DIR/kdbx_mcp_*.log" >&2
    exit 1
fi
