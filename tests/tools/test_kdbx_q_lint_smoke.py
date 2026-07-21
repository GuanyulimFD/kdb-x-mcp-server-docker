"""
Live smoke tests for kdbx_q_lint — require a running KDB-X server with qlint.q_ accessible.

Run:
    uv run pytest tests/tools/test_kdbx_q_lint_smoke.py -v -m live_kdb

Skip automatically when KDB-X is unavailable (uses the session-scoped kdb_conn fixture
which calls pytest.skip on connection failure).

Requires:
    KDBX_DB_QLINT_PATH=/path/to/developer-<ver>-<os>/analyst/ws/qlint.q_
    (or qlint.q_ discoverable via the standard search order)
"""
import pytest

from mcp_server.tools.kdbx_q_analytics import q_lint_impl

pytestmark = pytest.mark.live_kdb

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# Inline call — no unused variables, genuinely clean
CLEAN_CODE = "{[x;y] x+y}[1;2]"

# UNUSED_PARAM: y declared but never referenced
BAD_CODE = "add:{[x;y] x+x}"


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class TestQLintSmoke:

    @pytest.mark.asyncio
    async def test_clean_code_returns_no_violations(self, kdb_conn):
        result = await q_lint_impl("item", CLEAN_CODE)

        assert result["status"] == "ok", f"unexpected error: {result.get('message')}"
        assert result["clean"] is True
        assert result["violation_count"] == 0
        assert result["violations"] == []

    @pytest.mark.asyncio
    async def test_bad_code_returns_violations(self, kdb_conn):
        result = await q_lint_impl("item", BAD_CODE)

        assert result["status"] == "ok", f"unexpected error: {result.get('message')}"
        assert result["clean"] is False
        assert result["violation_count"] > 0

        v = result["violations"][0]
        assert v["errorClass"] != ""
        # All 9 fields must be present
        expected_fields = {
            "label", "errorClass", "description", "problemText",
            "errorMessage", "startLine", "startCol", "endLine", "endCol",
        }
        assert expected_fields.issubset(v.keys()), f"missing fields: {expected_fields - v.keys()}"

    @pytest.mark.asyncio
    async def test_all_nine_fields_populated(self, kdb_conn):
        """Every violation object must carry all 9 spec-required fields."""
        result = await q_lint_impl("item", BAD_CODE)

        assert result["status"] == "ok"
        for v in result["violations"]:
            for field in ("label", "errorClass", "description", "problemText",
                          "errorMessage", "startLine", "startCol", "endLine", "endCol"):
                assert field in v, f"field {field!r} missing from violation {v}"
