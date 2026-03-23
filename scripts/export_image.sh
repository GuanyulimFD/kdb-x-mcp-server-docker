#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/export_image.sh
#
# Exports the kdbx-mcp-server Docker image to a compressed tarball that can
# be transferred to another machine and loaded with import_and_run.sh.
#
# The image is self-contained: KDB-X binary, license, ax-libraries (qcumber),
# and the Python MCP server are all baked in.  No KX credentials are needed
# at runtime on the target host.
#
# Usage:
#   ./scripts/export_image.sh [output_dir]
#
#   output_dir  - where to write the .tar.gz (default: current directory)
#
# Output files:
#   kdbx-mcp-server.tar.gz   - the Docker image tarball
#   kdbx-mcp-server.env      - minimal runtime .env for docker compose / docker run
#
# Transfer to target host (examples):
#   scp kdbx-mcp-server.tar.gz kdbx-mcp-server.env user@host:~/
#   rsync -avz kdbx-mcp-server.tar.gz kdbx-mcp-server.env user@host:~/kdbx/
# ---------------------------------------------------------------------------

set -euo pipefail

IMAGE_NAME="kdbx-mcp-server:latest"
OUT_DIR="${1:-.}"
TARBALL="$OUT_DIR/kdbx-mcp-server.tar.gz"
ENV_FILE="$OUT_DIR/kdbx-mcp-server.env"

# ---------------------------------------------------------------------------
# 1. Verify the image exists (or offer to build it)
# ---------------------------------------------------------------------------
if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    echo "ERROR: Image '$IMAGE_NAME' not found locally." >&2
    echo "       Build it first with: docker compose build" >&2
    exit 1
fi

IMAGE_SIZE=$(docker image inspect "$IMAGE_NAME" --format '{{.Size}}' | \
    awk '{printf "%.0f MB", $1/1024/1024}')
IMAGE_ID=$(docker image inspect "$IMAGE_NAME" --format '{{.Id}}' | cut -c8-19)
IMAGE_CREATED=$(docker image inspect "$IMAGE_NAME" --format '{{.Created}}' | cut -c1-19)

echo "============================================================="
echo "  KDB-X MCP Server — image export"
echo "  Image   : $IMAGE_NAME  (id: $IMAGE_ID)"
echo "  Created : $IMAGE_CREATED"
echo "  Size    : $IMAGE_SIZE"
echo "  Output  : $TARBALL"
echo "============================================================="

mkdir -p "$OUT_DIR"

# ---------------------------------------------------------------------------
# 2. Save image to tarball
# ---------------------------------------------------------------------------
echo ""
echo "[1/2] Saving image to $TARBALL ..."
echo "      (this may take a minute for a ~1 GB image)"

docker save "$IMAGE_NAME" | gzip -9 > "$TARBALL"

FINAL_SIZE=$(du -h "$TARBALL" | awk '{print $1}')
echo "      Done — compressed size: $FINAL_SIZE"

# ---------------------------------------------------------------------------
# 3. Write a minimal runtime .env for the target host
#    Build-time secrets (KX_BEARER_TOKEN, KX_B64LIC) are NOT needed at runtime.
# ---------------------------------------------------------------------------
echo ""
echo "[2/2] Writing runtime env file to $ENV_FILE ..."

cat > "$ENV_FILE" <<'ENV_EOF'
# ---------------------------------------------------------------------------
# kdbx-mcp-server.env
#
# Runtime environment for the kdbx-mcp-server Docker image.
# Copy this alongside the .tar.gz to the target host and adjust as needed.
#
# Usage (docker compose):
#   cp kdbx-mcp-server.env .env
#   docker compose up -d
#
# Usage (docker run):
#   docker run -d --env-file kdbx-mcp-server.env \
#     -p 8000:8000 -v "$(pwd)/logs:/app/logs" \
#     --name kdbx-mcp kdbx-mcp-server:latest
#
# Build-time secrets (KX_BEARER_TOKEN, KX_B64LIC, KX_ARCH) are baked in —
# they are NOT required on the target host.
# ---------------------------------------------------------------------------

# ── MCP server port exposed on the host ────────────────────────────────────
MCP_HOST_PORT=8000

# ── Internal KDB-X q process port (container-internal) ─────────────────────
KDBX_DB_PORT=5001

# ── Log directory on the HOST that is bind-mounted into /app/logs ───────────
# Tail from host: tail -f ./logs/kdbx_mcp_*.log
LOG_DIR_HOST=./logs

# ── Log verbosity (DEBUG | INFO | WARNING | ERROR) ─────────────────────────
# KDBX_MCP_LOG_LEVEL=INFO
ENV_EOF

echo "      Done."

# ---------------------------------------------------------------------------
# 4. Print transfer & load instructions
# ---------------------------------------------------------------------------
echo ""
echo "============================================================="
echo "  Transfer to target host:"
echo ""
echo "    scp $TARBALL $ENV_FILE user@target-host:~/"
echo ""
echo "  On the target host:"
echo ""
echo "    # Load the image (one-time)"
echo "    docker load < kdbx-mcp-server.tar.gz"
echo ""
echo "    # Option A — docker compose (recommended)"
echo "    cp kdbx-mcp-server.env .env"
echo "    curl -sSL https://raw.githubusercontent.com/your-org/kdb-x-mcp-server/main/docker-compose.yml > docker-compose.yml"
echo "    docker compose up -d"
echo ""
echo "    # Option B — plain docker run"
echo "    docker run -d --env-file kdbx-mcp-server.env \\"
echo "      -p 8000:8000 -v \"\$(pwd)/logs:/app/logs\" \\"
echo "      --name kdbx-mcp kdbx-mcp-server:latest"
echo ""
echo "    # Verify it is up"
echo "    docker ps --filter name=kdbx-mcp"
echo "    curl -s http://target-host:8000/mcp -H 'Content-Type: application/json' \\"
echo "         -H 'Accept: application/json, text/event-stream' \\"
echo "         -d '{\"jsonrpc\":\"2.0\",\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"check\",\"version\":\"1\"}},\"id\":1}'"
echo "============================================================="
