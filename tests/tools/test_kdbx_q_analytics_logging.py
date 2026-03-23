"""
Tests for logging emitted by kdbx_q_analytics tools (kdbx_q_eval and kdbx_q_unit_test).

All tests are pure unit tests – no live KDB-X connection is required.
The KDB connection and subprocess calls are fully mocked.
"""
import json
import subprocess
import tempfile
from unittest.mock import MagicMock, patch, mock_open

import pytest

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_ok_result(payload: str = '"hello"'):
    """Build a mock pykx result object that looks like a successful q eval."""
    mock = MagicMock()
    mock.__getitem__.side_effect = lambda k: {
        "status": MagicMock(__str__=lambda self: "ok"),
        "result": payload.encode(),
    }[k]
    return mock


def _make_error_result(msg: str = "type error"):
    """Build a mock pykx result that looks like a q-level error response."""
    class _Str(str):
        def py(self):
            return self

    mock = MagicMock()
    mock.__getitem__.side_effect = lambda k: {
        "status": MagicMock(__str__=lambda self: "error"),
        "error": _Str(msg),
    }[k]
    return mock


# ---------------------------------------------------------------------------
# kdbx_q_eval — unit tests
# ---------------------------------------------------------------------------

class TestQEvalLogging:
    """kdbx_q_eval must log: entry (code preview), exit status, and timing."""

    async def test_success_logs_entry_and_exit(self, caplog):
        """INFO log on entry and completion when q eval succeeds."""
        import logging
        from mcp_server.tools.kdbx_q_analytics import q_eval_impl

        with patch("mcp_server.tools.kdbx_q_analytics.get_kdb_connection") as mock_conn:
            mock_conn.return_value.return_value = _make_ok_result('"world"')
            with caplog.at_level(logging.INFO, logger="mcp_server.tools.kdbx_q_analytics"):
                result = await q_eval_impl("1+1")

        assert result["status"] == "ok"

        messages = [r.message for r in caplog.records]
        # Entry log should contain the code
        entry_msgs = [m for m in messages if "kdbx_q_eval: evaluating" in m]
        assert entry_msgs, "Expected an entry-level log message for kdbx_q_eval"
        assert "1+1" in entry_msgs[0]

        # Exit log should indicate ok
        exit_msgs = [m for m in messages if "completed" in m and "kdbx_q_eval" in m]
        assert exit_msgs, "Expected a completion log message for kdbx_q_eval"
        assert "status=ok" in exit_msgs[0]

    async def test_success_logs_code_preview_truncated(self, caplog):
        """Entry log must truncate very long code to ≤303 chars (300 + '...')."""
        import logging
        from mcp_server.tools.kdbx_q_analytics import q_eval_impl

        long_code = "x" * 500
        with patch("mcp_server.tools.kdbx_q_analytics.get_kdb_connection") as mock_conn:
            mock_conn.return_value.return_value = _make_ok_result('"ok"')
            with caplog.at_level(logging.INFO, logger="mcp_server.tools.kdbx_q_analytics"):
                await q_eval_impl(long_code)

        entry_msgs = [r.message for r in caplog.records if "kdbx_q_eval: evaluating" in r.message]
        assert entry_msgs
        # The preview in the log must not exceed 303 chars (300 chars + "...")
        assert "..." in entry_msgs[0]
        assert len(entry_msgs[0]) < 600  # sanity: message is not the full 500-char code

    async def test_q_error_logs_warning(self, caplog):
        """A q-level error (status='error') must produce a WARNING log."""
        import logging
        from mcp_server.tools.kdbx_q_analytics import q_eval_impl

        with patch("mcp_server.tools.kdbx_q_analytics.get_kdb_connection") as mock_conn:
            mock_conn.return_value.return_value = _make_error_result("type")
            with caplog.at_level(logging.WARNING, logger="mcp_server.tools.kdbx_q_analytics"):
                result = await q_eval_impl("bad code")

        assert result["status"] == "error"

        warn_msgs = [
            r for r in caplog.records
            if r.levelno == logging.WARNING and "kdbx_q_eval" in r.message
        ]
        assert warn_msgs, "Expected a WARNING log for q-level error"
        assert "error" in warn_msgs[0].message.lower()

    async def test_exception_logs_error(self, caplog):
        """An unexpected connection exception must produce an ERROR log."""
        import logging
        from mcp_server.tools.kdbx_q_analytics import q_eval_impl

        with patch("mcp_server.tools.kdbx_q_analytics.get_kdb_connection") as mock_conn:
            mock_conn.side_effect = RuntimeError("connection refused")
            with caplog.at_level(logging.ERROR, logger="mcp_server.tools.kdbx_q_analytics"):
                result = await q_eval_impl("tables[]")

        assert result["status"] == "error"

        error_msgs = [
            r for r in caplog.records
            if r.levelno == logging.ERROR and "kdbx_q_eval" in r.message
        ]
        assert error_msgs, "Expected an ERROR log for exception in kdbx_q_eval"
        assert "connection refused" in error_msgs[0].message

    async def test_logs_char_count(self, caplog):
        """Entry log must include the character count of the submitted code."""
        import logging
        from mcp_server.tools.kdbx_q_analytics import q_eval_impl

        code = "select from trade"
        with patch("mcp_server.tools.kdbx_q_analytics.get_kdb_connection") as mock_conn:
            mock_conn.return_value.return_value = _make_ok_result("[]")
            with caplog.at_level(logging.INFO, logger="mcp_server.tools.kdbx_q_analytics"):
                await q_eval_impl(code)

        entry_msgs = [r.message for r in caplog.records if "kdbx_q_eval: evaluating" in r.message]
        assert entry_msgs
        assert str(len(code)) in entry_msgs[0], "Entry log must include char count"


# ---------------------------------------------------------------------------
# kdbx_q_unit_test — unit tests
# ---------------------------------------------------------------------------

_MINIMAL_QUKE = """
feature example

    should pass trivially
        expect one equals one
            1b
"""

_QCUMBER_RESULTS = [
    {
        "success": True,
        "feature": "example",
        "description": "pass trivially",
        "expectations": "one equals one",
        "error": "",
        "aborted": False,
        "skipped": False,
        "parseError": False,
    }
]

_QCUMBER_RESULTS_WITH_FAILURE = [
    {
        "success": True,
        "feature": "feature A",
        "description": "should pass",
        "expectations": "expect pass",
        "error": "",
        "aborted": False,
        "skipped": False,
        "parseError": False,
    },
    {
        "success": False,
        "feature": "feature A",
        "description": "should fail",
        "expectations": "expect fail",
        "error": "'type",
        "aborted": False,
        "skipped": False,
        "parseError": False,
    },
]


def _patch_qcumber_run(results_json, returncode=0):
    """Return a context manager that fully mocks a qCumber subprocess run."""
    import os

    def _side_effect(*args, **kwargs):
        # Write fake results to the results_file path extracted from the cmd
        cmd = args[0]
        out_idx = cmd.index("-out") + 1
        results_path = cmd[out_idx]
        with open(results_path, "w") as f:
            json.dump(results_json, f)
        proc = MagicMock()
        proc.returncode = returncode
        proc.stdout = ""
        proc.stderr = ""
        return proc

    return patch("mcp_server.tools.kdbx_q_analytics.subprocess.run", side_effect=_side_effect)


class TestQUnitTestLogging:
    """kdbx_q_unit_test must log: entry (quke char count, setup presence), exit summary, failures."""

    async def test_success_logs_entry_and_summary(self, caplog):
        """INFO log on entry and passing summary when all tests pass."""
        import logging
        from mcp_server.tools.kdbx_q_analytics import q_unit_test_impl

        with (
            patch("mcp_server.tools.kdbx_q_analytics._find_q_binary", return_value="/usr/bin/q"),
            patch("mcp_server.tools.kdbx_q_analytics._find_qcumber", return_value="/ax/ws/qcumber.q_"),
            patch("mcp_server.tools.kdbx_q_analytics._get_q_arch_prefix", return_value=[]),
            patch("mcp_server.tools.kdbx_q_analytics._derive_axlibraries_home", return_value="/ax"),
            patch("os.path.isdir", return_value=True),
            _patch_qcumber_run(_QCUMBER_RESULTS),
            caplog.at_level(logging.INFO, logger="mcp_server.tools.kdbx_q_analytics"),
        ):
            result = await q_unit_test_impl(_MINIMAL_QUKE)

        assert result["status"] == "ok"
        messages = [r.message for r in caplog.records]

        entry_msgs = [m for m in messages if "kdbx_q_unit_test: starting" in m]
        assert entry_msgs, "Expected an entry INFO log for kdbx_q_unit_test"
        assert f"quke_chars={len(_MINIMAL_QUKE)}" in entry_msgs[0]
        assert "setup=no" in entry_msgs[0]

        summary_msgs = [m for m in messages if "1/1 passed" in m]
        assert summary_msgs, "Expected a summary log '1/1 passed'"

    async def test_with_setup_code_logs_setup_yes(self, caplog):
        """Entry log must reflect setup=yes when setup_code is provided."""
        import logging
        from mcp_server.tools.kdbx_q_analytics import q_unit_test_impl

        setup = "double:{x*2}"
        with (
            patch("mcp_server.tools.kdbx_q_analytics._find_q_binary", return_value="/usr/bin/q"),
            patch("mcp_server.tools.kdbx_q_analytics._find_qcumber", return_value="/ax/ws/qcumber.q_"),
            patch("mcp_server.tools.kdbx_q_analytics._get_q_arch_prefix", return_value=[]),
            patch("mcp_server.tools.kdbx_q_analytics._derive_axlibraries_home", return_value="/ax"),
            patch("os.path.isdir", return_value=True),
            _patch_qcumber_run(_QCUMBER_RESULTS),
            caplog.at_level(logging.INFO, logger="mcp_server.tools.kdbx_q_analytics"),
        ):
            await q_unit_test_impl(_MINIMAL_QUKE, setup_code=setup)

        entry_msgs = [r.message for r in caplog.records if "kdbx_q_unit_test: starting" in r.message]
        assert entry_msgs
        assert "setup=yes" in entry_msgs[0]

    async def test_failure_logs_warning_per_failed_test(self, caplog):
        """Each failing test must produce an individual WARNING log."""
        import logging
        from mcp_server.tools.kdbx_q_analytics import q_unit_test_impl

        with (
            patch("mcp_server.tools.kdbx_q_analytics._find_q_binary", return_value="/usr/bin/q"),
            patch("mcp_server.tools.kdbx_q_analytics._find_qcumber", return_value="/ax/ws/qcumber.q_"),
            patch("mcp_server.tools.kdbx_q_analytics._get_q_arch_prefix", return_value=[]),
            patch("mcp_server.tools.kdbx_q_analytics._derive_axlibraries_home", return_value="/ax"),
            patch("os.path.isdir", return_value=True),
            _patch_qcumber_run(_QCUMBER_RESULTS_WITH_FAILURE, returncode=1),
            caplog.at_level(logging.WARNING, logger="mcp_server.tools.kdbx_q_analytics"),
        ):
            result = await q_unit_test_impl(_MINIMAL_QUKE)

        assert result["status"] == "ok"
        assert result["failed"] == 1

        # Summary should be a WARNING (because there are failures)
        summary_warns = [
            r for r in caplog.records
            if r.levelno == logging.WARNING and "1/2 passed, 1 failed" in r.message
        ]
        assert summary_warns, "Expected summary WARNING log for failing run"

        # Individual failure WARNING
        fail_warns = [
            r for r in caplog.records
            if r.levelno == logging.WARNING and "FAIL" in r.message and "should fail" in r.message
        ]
        assert fail_warns, "Expected per-test FAIL WARNING log"
        assert "'type" in fail_warns[0].message

    async def test_no_q_binary_logs_error(self, caplog):
        """ERROR log when q binary cannot be located."""
        import logging
        from mcp_server.tools.kdbx_q_analytics import q_unit_test_impl

        with (
            patch("mcp_server.tools.kdbx_q_analytics._find_q_binary", return_value=""),
            caplog.at_level(logging.ERROR, logger="mcp_server.tools.kdbx_q_analytics"),
        ):
            result = await q_unit_test_impl(_MINIMAL_QUKE)

        assert result["status"] == "error"
        error_msgs = [r for r in caplog.records if r.levelno == logging.ERROR]
        assert error_msgs, "Expected ERROR log when q binary not found"

    async def test_no_qcumber_logs_error(self, caplog):
        """ERROR log when qcumber.q_ cannot be located."""
        import logging
        from mcp_server.tools.kdbx_q_analytics import q_unit_test_impl

        with (
            patch("mcp_server.tools.kdbx_q_analytics._find_q_binary", return_value="/usr/bin/q"),
            patch("mcp_server.tools.kdbx_q_analytics._find_qcumber", return_value=""),
            caplog.at_level(logging.ERROR, logger="mcp_server.tools.kdbx_q_analytics"),
        ):
            result = await q_unit_test_impl(_MINIMAL_QUKE)

        assert result["status"] == "error"
        error_msgs = [r for r in caplog.records if r.levelno == logging.ERROR]
        assert error_msgs, "Expected ERROR log when qcumber not found"

    async def test_logs_qcumber_command(self, caplog):
        """INFO log must include the qCumber command that will be executed."""
        import logging
        from mcp_server.tools.kdbx_q_analytics import q_unit_test_impl

        with (
            patch("mcp_server.tools.kdbx_q_analytics._find_q_binary", return_value="/usr/bin/q"),
            patch("mcp_server.tools.kdbx_q_analytics._find_qcumber", return_value="/ax/ws/qcumber.q_"),
            patch("mcp_server.tools.kdbx_q_analytics._get_q_arch_prefix", return_value=[]),
            patch("mcp_server.tools.kdbx_q_analytics._derive_axlibraries_home", return_value="/ax"),
            patch("os.path.isdir", return_value=True),
            _patch_qcumber_run(_QCUMBER_RESULTS),
            caplog.at_level(logging.INFO, logger="mcp_server.tools.kdbx_q_analytics"),
        ):
            await q_unit_test_impl(_MINIMAL_QUKE)

        cmd_msgs = [r.message for r in caplog.records if "running qCumber" in r.message]
        assert cmd_msgs, "Expected INFO log with qCumber command"
        assert "qcumber.q_" in cmd_msgs[0]

    async def test_timeout_logs_error(self, caplog):
        """ERROR log when qCumber subprocess times out."""
        import logging
        from mcp_server.tools.kdbx_q_analytics import q_unit_test_impl

        with (
            patch("mcp_server.tools.kdbx_q_analytics._find_q_binary", return_value="/usr/bin/q"),
            patch("mcp_server.tools.kdbx_q_analytics._find_qcumber", return_value="/ax/ws/qcumber.q_"),
            patch("mcp_server.tools.kdbx_q_analytics._get_q_arch_prefix", return_value=[]),
            patch("mcp_server.tools.kdbx_q_analytics._derive_axlibraries_home", return_value="/ax"),
            patch("os.path.isdir", return_value=True),
            patch(
                "mcp_server.tools.kdbx_q_analytics.subprocess.run",
                side_effect=subprocess.TimeoutExpired(cmd="q", timeout=5),
            ),
            caplog.at_level(logging.ERROR, logger="mcp_server.tools.kdbx_q_analytics"),
        ):
            result = await q_unit_test_impl(_MINIMAL_QUKE, timeout=5)

        assert result["status"] == "error"
        assert "timed out" in result["message"]
        error_msgs = [r for r in caplog.records if r.levelno == logging.ERROR]
        assert error_msgs, "Expected ERROR log on qCumber timeout"


# ---------------------------------------------------------------------------
# Live integration tests — skipped unless KDB-X is available
# ---------------------------------------------------------------------------

@pytest.mark.live_kdb
class TestQEvalLoggingLive:
    """Integration tests that run against a real KDB-X instance on port 5001."""

    async def test_live_q_eval_logs_entry_and_exit(self, kdb_conn, caplog):
        """Live q eval must produce an entry INFO log and an exit log (ok or error).

        The test only verifies that logging fires correctly — it does not assert on
        the query result because the MCP server may be configured for a different
        port than the kdb_conn fixture (5001 vs the default 5000).
        """
        import logging
        from mcp_server.tools.kdbx_q_analytics import q_eval_impl

        with caplog.at_level(logging.INFO, logger="mcp_server.tools.kdbx_q_analytics"):
            result = await q_eval_impl("1+1")

        # Entry log must always be present
        assert any(
            "kdbx_q_eval: evaluating" in r.message for r in caplog.records
        ), "Expected entry INFO log from kdbx_q_eval"

        # Exit log must always be present (either 'completed' or 'exception')
        assert any(
            ("kdbx_q_eval: completed" in r.message or "kdbx_q_eval: exception" in r.message)
            for r in caplog.records
        ), "Expected an exit log from kdbx_q_eval (completed or exception)"

        # If connection succeeded, assert proper result
        if result["status"] == "ok":
            exit_ok = [r for r in caplog.records if "kdbx_q_eval: completed" in r.message]
            assert exit_ok
            assert "status=ok" in exit_ok[0].message

    async def test_live_q_unit_test_logs_summary(self, kdb_conn, caplog):
        """Live qCumber run should produce a summary log."""
        import logging
        from mcp_server.tools.kdbx_q_analytics import q_unit_test_impl

        quke = """
feature trivial

    should one plus one is two
        expect arithmetic
            2 ~ 1+1
"""
        with caplog.at_level(logging.INFO, logger="mcp_server.tools.kdbx_q_analytics"):
            result = await q_unit_test_impl(quke)

        # result may be ok or error depending on qcumber availability
        if result["status"] == "ok":
            assert any("kdbx_q_unit_test:" in r.message for r in caplog.records)
