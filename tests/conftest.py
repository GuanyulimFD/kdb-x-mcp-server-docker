"""
Shared pytest fixtures for the kdb-x-mcp-server test suite.
"""
import sys

# AppSettings uses pydantic-settings with cli_parse_args=True, which means it
# tries to parse sys.argv when imported. Pytest injects its own arguments into
# sys.argv which causes a SystemExit(2) when any mcp_server module is imported.
# Override sys.argv to a minimal valid value before any mcp_server import occurs.
sys.argv = ["mcp-server"]

import pytest
import pykx as kx


@pytest.fixture(scope="session")
def kdb_conn():
    """Live KDB-X connection — session-scoped fixture.
    Tests using this fixture are automatically skipped when the service
    is unavailable on port 5001.
    """
    try:
        conn = kx.SyncQConnection(host="127.0.0.1", port=5001, timeout=2)
        yield conn
        conn.close()
    except Exception:
        pytest.skip("KDB-X service not available on port 5001")
