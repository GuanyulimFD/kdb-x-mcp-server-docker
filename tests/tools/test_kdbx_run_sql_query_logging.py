"""
Tests for logging emitted by kdbx_run_sql_query tool.

All tests are pure unit tests – no live KDB-X connection is required.
The KDB connection is fully mocked.
"""
import json
from unittest.mock import MagicMock, patch

import pytest


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_sql_result(row_count: int, rows: list):
    """Build a mock pykx result for the SQL query wrapper."""
    encoded = json.dumps(rows).encode("utf-8")

    data_mock = MagicMock()
    data_mock.py.return_value = encoded

    mock = MagicMock()
    mock.__getitem__.side_effect = lambda k: {
        "rowCount": row_count,
        "data": data_mock,
    }[k]
    return mock


# ---------------------------------------------------------------------------
# run_query_impl — unit tests
# ---------------------------------------------------------------------------

class TestSqlQueryLogging:
    """kdbx_run_sql_query must log: entry (query preview), exit (row count + timing)."""

    async def test_success_logs_entry_and_exit(self, caplog):
        """INFO log on entry (query text) and completion (row count)."""
        import logging
        from mcp_server.tools.kdbx_run_sql_query import run_query_impl

        query = "SELECT * FROM trade"
        with patch("mcp_server.tools.kdbx_run_sql_query.get_kdb_connection") as mock_conn:
            mock_conn.return_value.return_value = _make_sql_result(2, [{"sym": "AAPL"}, {"sym": "GOOG"}])
            with caplog.at_level(logging.INFO, logger="mcp_server.tools.kdbx_run_sql_query"):
                result = await run_query_impl(query)

        assert result["status"] == "success"
        messages = [r.message for r in caplog.records]

        entry_msgs = [m for m in messages if "kdbx_run_sql_query: executing" in m]
        assert entry_msgs, "Expected an entry INFO log for kdbx_run_sql_query"
        assert "SELECT * FROM trade" in entry_msgs[0]

        exit_msgs = [m for m in messages if "kdbx_run_sql_query: completed" in m]
        assert exit_msgs, "Expected a completion log for kdbx_run_sql_query"
        assert "rows=2" in exit_msgs[0]

    async def test_no_rows_logs_rows_zero(self, caplog):
        """Completion log must show rows=0 when result is empty."""
        import logging
        from mcp_server.tools.kdbx_run_sql_query import run_query_impl

        with patch("mcp_server.tools.kdbx_run_sql_query.get_kdb_connection") as mock_conn:
            mock_conn.return_value.return_value = _make_sql_result(0, [])
            with caplog.at_level(logging.INFO, logger="mcp_server.tools.kdbx_run_sql_query"):
                result = await run_query_impl("SELECT * FROM empty_tbl")

        assert result["status"] == "success"
        assert result["data"] == []

        exit_msgs = [r.message for r in caplog.records if "kdbx_run_sql_query: completed" in r.message]
        assert exit_msgs, "Expected a completion log even for zero rows"
        assert "rows=0" in exit_msgs[0]

    async def test_truncation_logs_total_and_limit(self, caplog):
        """When result is truncated, log must show rows_total and rows_returned."""
        import logging
        from mcp_server.tools.kdbx_run_sql_query import run_query_impl

        total = 5000
        rows = [{"sym": "X"}] * 1000  # MAX_ROWS_RETURNED = 1000

        with patch("mcp_server.tools.kdbx_run_sql_query.get_kdb_connection") as mock_conn:
            mock_conn.return_value.return_value = _make_sql_result(total, rows)
            with caplog.at_level(logging.INFO, logger="mcp_server.tools.kdbx_run_sql_query"):
                result = await run_query_impl("SELECT * FROM big_table")

        assert result["status"] == "success"
        assert "Showing first" in result.get("message", "")

        trunc_msgs = [r.message for r in caplog.records if "rows_total=5000" in r.message]
        assert trunc_msgs, "Expected truncation log mentioning rows_total"
        assert "rows_returned=1000" in trunc_msgs[0]
        assert "truncated" in trunc_msgs[0]

    async def test_logs_query_preview_truncated(self, caplog):
        """Entry log must truncate queries longer than 300 chars."""
        import logging
        from mcp_server.tools.kdbx_run_sql_query import run_query_impl

        long_query = "SELECT " + ", ".join([f"col{i}" for i in range(100)]) + " FROM trade"
        with patch("mcp_server.tools.kdbx_run_sql_query.get_kdb_connection") as mock_conn:
            mock_conn.return_value.return_value = _make_sql_result(1, [{"col0": 1}])
            with caplog.at_level(logging.INFO, logger="mcp_server.tools.kdbx_run_sql_query"):
                await run_query_impl(long_query)

        entry_msgs = [r.message for r in caplog.records if "kdbx_run_sql_query: executing" in r.message]
        assert entry_msgs
        if len(long_query) > 300:
            assert "..." in entry_msgs[0], "Long queries must be truncated with '...'"

    async def test_exception_logs_error_with_query(self, caplog):
        """ERROR log must be emitted on unexpected exception, including the query."""
        import logging
        from mcp_server.tools.kdbx_run_sql_query import run_query_impl

        query = "SELECT * FROM trade"
        with patch("mcp_server.tools.kdbx_run_sql_query.get_kdb_connection") as mock_conn:
            mock_conn.side_effect = RuntimeError("network error")
            with caplog.at_level(logging.ERROR, logger="mcp_server.tools.kdbx_run_sql_query"):
                result = await run_query_impl(query)

        assert result["status"] == "error"

        error_msgs = [r for r in caplog.records if r.levelno == 40]  # logging.ERROR
        assert error_msgs, "Expected ERROR log on exception"
        assert "network error" in error_msgs[0].message
        assert "SELECT * FROM trade" in error_msgs[0].message

    async def test_sql_interface_not_loaded_logs_error(self, caplog):
        """Structured error + ERROR log when .s.e is not loaded."""
        import logging
        from mcp_server.tools.kdbx_run_sql_query import run_query_impl

        with patch("mcp_server.tools.kdbx_run_sql_query.get_kdb_connection") as mock_conn:
            mock_conn.side_effect = Exception("'.s.e' — not found")
            with caplog.at_level(logging.ERROR, logger="mcp_server.tools.kdbx_run_sql_query"):
                result = await run_query_impl("SELECT 1")

        assert result["status"] == "error"
        assert result["error_type"] == "sql_interface_not_loaded"

        sql_err_msgs = [r for r in caplog.records if "sql_interface_not_loaded" in r.message.lower()
                        or "s.init" in r.message.lower()]
        assert sql_err_msgs, "Expected specific ERROR log mentioning .s.init[]"

    async def test_dangerous_keyword_raises_before_logging_execution(self, caplog):
        """Dangerous keyword check raises ValueError before any query is sent."""
        import logging
        from mcp_server.tools.kdbx_run_sql_query import run_query_impl

        with patch("mcp_server.tools.kdbx_run_sql_query.get_kdb_connection") as mock_conn:
            with caplog.at_level(logging.DEBUG, logger="mcp_server.tools.kdbx_run_sql_query"):
                result = await run_query_impl("DROP TABLE trade")

        assert result["status"] == "error"
        # get_kdb_connection should never be called for a dangerous query
        mock_conn.assert_not_called()


# ---------------------------------------------------------------------------
# Live integration tests
# ---------------------------------------------------------------------------

@pytest.mark.live_kdb
class TestSqlQueryLoggingLive:

    async def test_live_sql_query_logs(self, kdb_conn, caplog):
        """Live SQL query should produce INFO logs with query text and row count."""
        import logging
        from mcp_server.tools.kdbx_run_sql_query import run_query_impl

        with caplog.at_level(logging.INFO, logger="mcp_server.tools.kdbx_run_sql_query"):
            result = await run_query_impl("SELECT * FROM trade limit 1")

        # Either success or a handled error — but logging must have fired
        assert any(
            "kdbx_run_sql_query" in r.message for r in caplog.records
        ), "Expected at least one log record from kdbx_run_sql_query"
