#!/usr/bin/env bash
# Quick smoke-test for the KDB-X MCP server
# Usage: ./scripts/test_mcp_query.sh [session_id] [port]
#
# If no session_id is given, a new MCP session is opened automatically.

set -euo pipefail

MCP_URL="http://localhost:${2:-8000}/mcp"

# -----------------------------------------------------------------------
# 1. Initialize – get a fresh session
# ---------------------------------------------------------------------------
echo "--- Initialising MCP session ---"
INIT_RESPONSE=$(curl -s -X POST "$MCP_URL" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke-test","version":"1.0"}}}')

echo "$INIT_RESPONSE"
echo ""

# Extract session id from the Mcp-Session-Id response header via a verbose call
SESSION_ID=$(curl -s -D - -X POST "$MCP_URL" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke-test","version":"1.0"}}}' \
  | grep -i "mcp-session-id" | awk '{print $2}' | tr -d '\r')

if [[ -z "$SESSION_ID" ]]; then
  echo "ERROR: Could not retrieve Mcp-Session-Id from server." >&2
  exit 1
fi

echo "Session ID: $SESSION_ID"
echo ""

# ---------------------------------------------------------------------------
# 2. Send initialised notification
# ---------------------------------------------------------------------------
curl -s -X POST "$MCP_URL" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' > /dev/null

# ---------------------------------------------------------------------------
# 3. List available tools
# ---------------------------------------------------------------------------
echo "--- Available tools ---"
curl -s -X POST "$MCP_URL" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}}'
echo ""

# ---------------------------------------------------------------------------
# 4. Run a simple SQL query
# ---------------------------------------------------------------------------
echo "--- Running SQL query: SELECT .z.d as today  ---"
curl -s -X POST "$MCP_URL" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"kdbx_run_sql_query","arguments":{"query":"SELECT current_timestamp as today"}}}'
echo ""
