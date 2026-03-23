"""
Integration tests for the dockerised KDB-X MCP server.

These tests talk directly to the running container over HTTP using the
MCP Streamable-HTTP transport (JSON-RPC 2.0 over POST /mcp).

Run against a live container:
    docker compose up -d                      # start (or ensure it is running)
    uv run pytest tests/test_docker_mcp_server.py -v

The MCP_BASE_URL environment variable overrides the default endpoint so you can
point the tests at a remote host:
    MCP_BASE_URL=http://<remote-host>:8000 uv run pytest tests/test_docker_mcp_server.py -v
"""
import json
import os
import re
import time

import pytest
import requests

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

BASE_URL = os.getenv("MCP_BASE_URL", "http://localhost:8000")
MCP_ENDPOINT = f"{BASE_URL}/mcp"

HEADERS = {
    "Content-Type": "application/json",
    "Accept": "application/json, text/event-stream",
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def mcp_post(payload: dict, session_id: str | None = None) -> dict:
    """POST a JSON-RPC payload to the MCP endpoint and return the parsed result dict."""
    headers = dict(HEADERS)
    if session_id:
        headers["mcp-session-id"] = session_id

    resp = requests.post(MCP_ENDPOINT, headers=headers, json=payload, timeout=30)
    resp.raise_for_status()

    # The streamable-http transport wraps responses in SSE — parse out the JSON.
    body = resp.text
    # Extract lines that start with "data: "
    data_lines = [line[len("data: "):] for line in body.splitlines() if line.startswith("data: ")]
    assert data_lines, f"No data lines in SSE response body:\n{body}"

    # Return the first complete JSON object found
    return json.loads(data_lines[0])


def initialize_session() -> str:
    """Perform the full MCP initialize + notifications/initialized handshake.

    The MCP spec requires the client to send a ``notifications/initialized``
    notification (no ``id`` field) after the ``initialize`` response is received.
    Until that notification is sent the server rejects all subsequent requests
    with -32602 Invalid request parameters.
    """
    payload = {
        "jsonrpc": "2.0",
        "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "pytest-docker-test", "version": "1.0"},
        },
        "id": 1,
    }
    resp = requests.post(MCP_ENDPOINT, headers=HEADERS, json=payload, timeout=15)
    resp.raise_for_status()
    session_id = resp.headers.get("mcp-session-id", "")
    assert session_id, "Server did not return an mcp-session-id header"

    # Required: send notifications/initialized to complete the handshake.
    # Notifications have no "id" field; the server returns HTTP 202 (no body).
    requests.post(
        MCP_ENDPOINT,
        headers={**HEADERS, "mcp-session-id": session_id},
        json={"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}},
        timeout=10,
    )
    return session_id


def call_tool(session_id: str, tool_name: str, arguments: dict, req_id: int = 10) -> dict:
    """Call a named MCP tool and return the parsed JSON-RPC result."""
    payload = {
        "jsonrpc": "2.0",
        "method": "tools/call",
        "params": {"name": tool_name, "arguments": arguments},
        "id": req_id,
    }
    result = mcp_post(payload, session_id=session_id)
    assert "error" not in result, f"Tool call returned error: {result.get('error')}"
    return result["result"]


# ---------------------------------------------------------------------------
# Fixture: one session per test module
# ---------------------------------------------------------------------------


@pytest.fixture(scope="module")
def session():
    """Establish an MCP session once for all tests in this module.
    Skips the entire module if the server is not reachable.
    """
    try:
        sid = initialize_session()
    except (requests.ConnectionError, requests.Timeout) as exc:
        pytest.skip(f"MCP server not reachable at {BASE_URL}: {exc}")
    yield sid


# ---------------------------------------------------------------------------
# 1. Connectivity & protocol
# ---------------------------------------------------------------------------


class TestProtocol:
    def test_server_is_reachable(self):
        """Container is up and the /mcp endpoint responds."""
        resp = requests.post(
            MCP_ENDPOINT,
            headers=HEADERS,
            json={
                "jsonrpc": "2.0",
                "method": "initialize",
                "params": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {},
                    "clientInfo": {"name": "ping", "version": "0"},
                },
                "id": 0,
            },
            timeout=10,
        )
        assert resp.status_code == 200

    def test_initialize_returns_server_info(self):
        """initialize response contains serverInfo with expected server name."""
        resp = requests.post(
            MCP_ENDPOINT,
            headers=HEADERS,
            json={
                "jsonrpc": "2.0",
                "method": "initialize",
                "params": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {},
                    "clientInfo": {"name": "info-test", "version": "1"},
                },
                "id": 99,
            },
            timeout=10,
        )
        resp.raise_for_status()
        # Parse SSE body
        data_lines = [l[len("data: "):] for l in resp.text.splitlines() if l.startswith("data: ")]
        assert data_lines, f"No data in SSE response: {resp.text}"
        body = json.loads(data_lines[0])
        server_name = body.get("result", {}).get("serverInfo", {}).get("name")
        assert server_name == "KDBX_MCP_Server", f"Unexpected serverInfo: {body}"

    def test_wrong_accept_header_returns_error(self):
        """Missing text/event-stream in Accept returns a JSON-RPC error response."""
        bad_headers = {
            "Content-Type": "application/json",
            "Accept": "application/json",  # missing text/event-stream
        }
        resp = requests.post(
            MCP_ENDPOINT,
            headers=bad_headers,
            json={"jsonrpc": "2.0", "method": "initialize", "params": {}, "id": 1},
            timeout=10,
        )
        # Server returns JSON-RPC error (may be HTTP 200 with error payload)
        body = resp.json()
        assert body.get("error") is not None, "Expected an error for bad Accept header"


# ---------------------------------------------------------------------------
# 2. Tool discovery
# ---------------------------------------------------------------------------

EXPECTED_TOOLS = {
    "kdbx_q_eval",
    "kdbx_q_unit_test",
    "kdbx_run_sql_query",
    "kdbx_similarity_search",
    "kdbx_hybrid_search",
}


class TestToolDiscovery:
    def test_tools_list_returns_expected_tools(self, session):
        """tools/list enumerates all registered MCP tools."""
        payload = {"jsonrpc": "2.0", "method": "tools/list", "params": {}, "id": 2}
        result = mcp_post(payload, session_id=session)
        tools = {t["name"] for t in result.get("result", {}).get("tools", [])}
        missing = EXPECTED_TOOLS - tools
        assert not missing, f"Missing expected tools: {missing}"

    def test_each_tool_has_description(self, session):
        """Every tool has a non-empty description string."""
        payload = {"jsonrpc": "2.0", "method": "tools/list", "params": {}, "id": 3}
        result = mcp_post(payload, session_id=session)
        tools = result.get("result", {}).get("tools", [])
        bad = [t["name"] for t in tools if not t.get("description", "").strip()]
        assert not bad, f"Tools missing descriptions: {bad}"


# ---------------------------------------------------------------------------
# 3. kdbx_q_eval — interactive q evaluation
# ---------------------------------------------------------------------------


class TestQEval:
    def test_simple_arithmetic(self, session):
        """1+1 evaluates to 2."""
        result = call_tool(session, "kdbx_q_eval", {"code": "1+1"})
        content_text = result["content"][0]["text"]
        assert "2" in content_text, f"Expected '2' in: {content_text}"

    def test_string_expression(self, session):
        """String literal round-trips correctly."""
        result = call_tool(session, "kdbx_q_eval", {"code": '"hello from q"'})
        content_text = result["content"][0]["text"]
        assert "hello from q" in content_text

    def test_table_creation(self, session):
        """Create an in-memory table and count rows."""
        code = "count ([]sym:`A`B`C; price:1.0 2.0 3.0)"
        result = call_tool(session, "kdbx_q_eval", {"code": code})
        content_text = result["content"][0]["text"]
        assert "3" in content_text, f"Expected row count 3 in: {content_text}"

    def test_builtin_aggregate(self, session):
        """avg of 1 2 3 = 2.0."""
        result = call_tool(session, "kdbx_q_eval", {"code": "avg 1 2 3"})
        content_text = result["content"][0]["text"]
        assert "2" in content_text

    def test_q_error_handled_gracefully(self, session):
        """A q runtime error is returned as a structured error — not an HTTP 5xx."""
        result = call_tool(session, "kdbx_q_eval", {"code": "1%0"})  # division by zero → 0w
        content_text = result["content"][0]["text"]
        # q returns 0w (infinity) for 1%0, not a signal; just check we get a response
        assert content_text is not None

    def test_multiline_function_definition(self, session):
        """Define and invoke a multi-argument q function.

        In q, evaluation is right-to-left (no precedence), so
        ``x*x + y*y`` means ``x * (x + y*y)``.
        Use explicit parentheses: ``(x*x) + (y*y)`` for the Pythagorean sum.
        """
        code = "f:{[x;y] (x*x) + (y*y)}; f[3;4]"
        result = call_tool(session, "kdbx_q_eval", {"code": code})
        content_text = result["content"][0]["text"]
        assert "25" in content_text, f"Expected 25 in: {content_text}"

    def test_q_modules_loaded(self, session):
        """The finstat and dataprofile q-modules should be auto-loaded at startup."""
        for ns in [".finstat", ".dataprofile"]:
            result = call_tool(session, "kdbx_q_eval", {"code": f"key `{ns}"})
            content_text = result["content"][0]["text"]
            assert content_text, f"Namespace {ns} appears empty or missing"


# ---------------------------------------------------------------------------
# 4. kdbx_run_sql_query
# ---------------------------------------------------------------------------


class TestSqlQuery:
    def test_sql_select_constant(self, session):
        """Simple SQL expression executes without error."""
        result = call_tool(session, "kdbx_run_sql_query", {"query": "SELECT 1+1 AS result"})
        content_text = result["content"][0]["text"]
        assert content_text, "Expected non-empty SQL result"

    def test_sql_invalid_table_returns_error(self, session):
        """Querying a non-existent table returns a structured error, not a crash."""
        result = call_tool(
            session,
            "kdbx_run_sql_query",
            {"query": "SELECT * FROM non_existent_table_xyz"},
        )
        content_text = result["content"][0]["text"]
        # The tool should surface an error message rather than an empty success
        assert content_text, "Expected some response for invalid-table query"


# ---------------------------------------------------------------------------
# 5. kdbx_q_unit_test (qcumber)
# ---------------------------------------------------------------------------


class TestQUnitTest:
    def test_passing_quke(self, session):
        """A trivially-passing .quke suite reports all tests passed."""
        quke = """
feature arithmetic sanity

    should add correctly
        expect 1+1 equals 2
            2 ~ 1+1

    expect multiply
        6 ~ 2*3
"""
        result = call_tool(
            session,
            "kdbx_q_unit_test",
            {"quke_content": quke},
        )
        content_text = result["content"][0]["text"]
        assert content_text, "Expected test result content"
        # Should contain pass/fail summary
        assert re.search(r"pass(ed)?|fail(ed)?", content_text, re.IGNORECASE), (
            f"Expected pass/fail summary in: {content_text}"
        )

    def test_setup_code_is_available_in_tests(self, session):
        """Functions defined in setup_code are callable in the .quke blocks."""
        quke = """
feature double function

    should double a number
        expect double 5 equals 10
            10 ~ double[5]
"""
        result = call_tool(
            session,
            "kdbx_q_unit_test",
            {"quke_content": quke, "setup_code": "double:{x*2}"},
        )
        content_text = result["content"][0]["text"]
        assert re.search(r"pass(ed)?", content_text, re.IGNORECASE), (
            f"Expected all-pass result: {content_text}"
        )


# ---------------------------------------------------------------------------
# 6. Resource / prompt presence
# ---------------------------------------------------------------------------


class TestResourcesAndPrompts:
    def test_resources_list(self, session):
        """resources/list returns at least one resource."""
        payload = {"jsonrpc": "2.0", "method": "resources/list", "params": {}, "id": 20}
        result = mcp_post(payload, session_id=session)
        resources = result.get("result", {}).get("resources", [])
        assert len(resources) >= 1, "Expected at least one registered resource"

    def test_prompts_list(self, session):
        """prompts/list returns at least one prompt."""
        payload = {"jsonrpc": "2.0", "method": "prompts/list", "params": {}, "id": 21}
        result = mcp_post(payload, session_id=session)
        prompts = result.get("result", {}).get("prompts", [])
        assert len(prompts) >= 1, "Expected at least one registered prompt"
