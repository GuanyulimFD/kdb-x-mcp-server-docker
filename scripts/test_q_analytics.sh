#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_q_analytics.sh  –  Smoke-test kdbx_q_eval and kdbx_q_unit_test tools
# ---------------------------------------------------------------------------
set -euo pipefail

MCP_URL="http://localhost:8000/mcp"

# ---- Open session -------------------------------------------------------
SESSION_ID=$(curl -s -D - -X POST "$MCP_URL" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"q-analytics-test","version":"1.0"}}}' \
  | grep -i "mcp-session-id" | awk '{print $2}' | tr -d '\r')

echo "Session: $SESSION_ID"

# Send initialised notification
curl -s -X POST "$MCP_URL" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' > /dev/null

call_tool() {
  local id="$1" name="$2" args="$3"
  curl -s -X POST "$MCP_URL" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "Mcp-Session-Id: $SESSION_ID" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":$id,\"method\":\"tools/call\",\"params\":{\"name\":\"$name\",\"arguments\":$args}}"
}

# ---- Test 1: kdbx_q_eval – define a function ----------------------------
echo ""
echo "=== Test 1: kdbx_q_eval – define vwap function ==="
call_tool 10 "kdbx_q_eval" \
  '{"code":"vwap:{[t] select vwap:size wavg price by sym from t}"}'

# ---- Test 2: kdbx_q_eval – create sample trade table --------------------
echo ""
echo "=== Test 2: kdbx_q_eval – create sample trade data ==="
call_tool 11 "kdbx_q_eval" \
  '{"code":"trade::([]sym:`AAPL`GOOG`AAPL`GOOG`AAPL; price:100 200 105 195 110f; size:100 50 200 150 300)"}'

# ---- Test 3: kdbx_q_eval – call the vwap function -----------------------
echo ""
echo "=== Test 3: kdbx_q_eval – run vwap on trade ==="
call_tool 12 "kdbx_q_eval" \
  '{"code":"vwap[trade]"}'

# ---- Test 4: kdbx_q_unit_test (qCumber) – shows graceful no-binary msg --
echo ""
echo "=== Test 4: kdbx_q_unit_test – qCumber suite (expects graceful error if binary not yet set) ==="
call_tool 13 "kdbx_q_unit_test" '{
  "setup_code": "double:{x*2}; add:{x+y}",
  "quke_content": "feature double function\n\n    should multiply by two\n        expect double 5 equals 10\n            10 ~ double[5]\n\n        expect double zero stays zero\n            0 ~ double[0]\n\nfeature add function\n\n    should sum two numbers\n        expect add 3 and 4 equals 7\n            7 ~ add[3;4]\n\n        expect intentional failure\n            99 ~ double[5]\n"
}'
echo ""
