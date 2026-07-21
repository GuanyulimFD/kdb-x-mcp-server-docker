"""
Unit tests for kdbx_q_lint helpers and tool.
No live KDB-X connection required — all pykx calls are mocked.
"""
import asyncio
import json
import pytest
from unittest.mock import MagicMock, AsyncMock, patch, call


# ---------------------------------------------------------------------------
# _find_qlint
# ---------------------------------------------------------------------------

class TestFindQlint:

    def test_returns_explicit_setting_when_file_exists(self, tmp_path):
        fake = tmp_path / "qlint.q_"
        fake.write_text("")
        with patch("mcp_server.tools.kdbx_q_analytics.app_settings") as mock_settings:
            mock_settings.db.qlint_path = str(fake)
            from mcp_server.tools.kdbx_q_analytics import _find_qlint
            assert _find_qlint() == str(fake)

    def test_returns_empty_string_when_not_found(self):
        with patch("mcp_server.tools.kdbx_q_analytics.app_settings") as mock_settings:
            mock_settings.db.qlint_path = ""
            with patch("glob.glob", return_value=[]):
                with patch("os.path.isfile", return_value=False):
                    from mcp_server.tools.kdbx_q_analytics import _find_qlint
                    assert _find_qlint() == ""

    def test_returns_glob_match_when_no_explicit_setting(self, tmp_path):
        fake = tmp_path / "qlint.q_"
        fake.write_text("")
        with patch("mcp_server.tools.kdbx_q_analytics.app_settings") as mock_settings:
            mock_settings.db.qlint_path = ""
            with patch("os.path.isfile", return_value=False):
                with patch("glob.glob", return_value=[str(fake)]):
                    from mcp_server.tools.kdbx_q_analytics import _find_qlint
                    assert _find_qlint() == str(fake)


# ---------------------------------------------------------------------------
# _ensure_qlint_loaded
# ---------------------------------------------------------------------------

class TestEnsureQlintLoaded:

    def _loaded_conn(self):
        """Conn mock where .qlint namespace is already present."""
        conn = MagicMock()
        already = MagicMock()
        already.py.return_value = True
        conn.return_value = already
        return conn

    def _unloaded_conn(self):
        """Conn mock where .qlint is absent; subsequent calls succeed."""
        conn = MagicMock()
        not_loaded = MagicMock()
        not_loaded.py.return_value = False
        ok = MagicMock()
        conn.side_effect = [not_loaded, ok, ok]  # check, \cd, \l
        return conn

    def test_skips_load_when_already_in_session(self, tmp_path):
        fake = tmp_path / "qlint.q_"
        fake.write_text("")
        conn = self._loaded_conn()
        with patch("mcp_server.tools.kdbx_q_analytics._find_qlint", return_value=str(fake)):
            from mcp_server.tools.kdbx_q_analytics import _ensure_qlint_loaded
            _ensure_qlint_loaded(conn)
        # Only 1 call — the namespace check; no \cd or \l
        assert conn.call_count == 1

    def test_loads_when_not_in_session(self, tmp_path):
        fake = tmp_path / "ws" / "qlint.q_"
        fake.parent.mkdir()
        fake.write_text("")
        conn = self._unloaded_conn()
        with patch("mcp_server.tools.kdbx_q_analytics._find_qlint", return_value=str(fake)):
            from mcp_server.tools.kdbx_q_analytics import _ensure_qlint_loaded
            _ensure_qlint_loaded(conn)
        # 3 calls: check, \cd, \l
        assert conn.call_count == 3
        cd_call = conn.call_args_list[1][0][0]
        assert "cd" in cd_call
        assert str(fake.parent) in cd_call
        load_call = conn.call_args_list[2][0][0]
        assert "qlint.q_" in load_call

    def test_raises_when_qlint_not_found(self):
        conn = MagicMock()
        not_loaded = MagicMock()
        not_loaded.py.return_value = False
        conn.return_value = not_loaded
        with patch("mcp_server.tools.kdbx_q_analytics._find_qlint", return_value=""):
            from mcp_server.tools.kdbx_q_analytics import _ensure_qlint_loaded
            with pytest.raises(RuntimeError, match="qlint.q_ not found"):
                _ensure_qlint_loaded(conn)


# ---------------------------------------------------------------------------
# q_lint_impl
# ---------------------------------------------------------------------------

def _mock_lint_conn(violations=None):
    """Conn mock that returns JSON-encoded violation list."""
    violations = violations or []
    raw = MagicMock()
    raw.py.return_value = json.dumps(violations).encode()
    conn = MagicMock(return_value=raw)
    return conn


SAMPLE_VIOLATION = {
    "label": "myFunc",
    "errorClass": "UNUSED_PARAM",
    "description": "Parameter x is never used",
    "problemText": "myFunc:{[x;y] y*2}",
    "errorMessage": "x declared but not referenced",
    "startLine": 3,
    "startCol": 0,
    "endLine": 3,
    "endCol": 18,
}


class TestQLintImpl:

    @pytest.fixture(autouse=True)
    def _patch_ensure(self):
        with patch("mcp_server.tools.kdbx_q_analytics._ensure_qlint_loaded"):
            yield

    async def test_item_clean_returns_clean_true(self):
        from mcp_server.tools.kdbx_q_analytics import q_lint_impl
        conn = _mock_lint_conn(violations=[])
        with patch("mcp_server.tools.kdbx_q_analytics.get_kdb_connection", return_value=conn):
            result = await q_lint_impl("item", "1+1")
        assert result["status"] == "ok"
        assert result["clean"] is True
        assert result["violation_count"] == 0
        assert result["violations"] == []

    async def test_item_with_violation_returns_clean_false(self):
        from mcp_server.tools.kdbx_q_analytics import q_lint_impl
        conn = _mock_lint_conn(violations=[SAMPLE_VIOLATION])
        with patch("mcp_server.tools.kdbx_q_analytics.get_kdb_connection", return_value=conn):
            result = await q_lint_impl("item", "myFunc:{[x;y] y*2}")
        assert result["status"] == "ok"
        assert result["clean"] is False
        assert result["violation_count"] == 1
        v = result["violations"][0]
        assert v["errorClass"] == "UNUSED_PARAM"
        assert v["label"] == "myFunc"
        assert v["startLine"] == 3
        assert v["endCol"] == 18

    async def test_item_preserves_all_nine_fields(self):
        from mcp_server.tools.kdbx_q_analytics import q_lint_impl
        conn = _mock_lint_conn(violations=[SAMPLE_VIOLATION])
        with patch("mcp_server.tools.kdbx_q_analytics.get_kdb_connection", return_value=conn):
            result = await q_lint_impl("item", "myFunc:{[x;y] y*2}")
        v = result["violations"][0]
        for field in ("label", "errorClass", "description", "problemText",
                      "errorMessage", "startLine", "startCol", "endLine", "endCol"):
            assert field in v, f"Missing field: {field}"

    async def test_file_mode_dispatches_lintFile(self):
        from mcp_server.tools.kdbx_q_analytics import q_lint_impl
        conn = _mock_lint_conn(violations=[])
        with patch("mcp_server.tools.kdbx_q_analytics.get_kdb_connection", return_value=conn):
            result = await q_lint_impl("file", "/q-modules/finstat/finstat.q")
        assert result["status"] == "ok"
        call_expr = conn.call_args_list[0][0][0]
        assert "lintFile" in call_expr

    async def test_folder_mode_dispatches_lintFolder(self):
        from mcp_server.tools.kdbx_q_analytics import q_lint_impl
        conn = _mock_lint_conn(violations=[])
        with patch("mcp_server.tools.kdbx_q_analytics.get_kdb_connection", return_value=conn):
            result = await q_lint_impl("folder", "/q-modules/finstat")
        assert result["status"] == "ok"
        call_expr = conn.call_args_list[0][0][0]
        assert "lintFolder" in call_expr

    async def test_invalid_mode_returns_error(self):
        from mcp_server.tools.kdbx_q_analytics import q_lint_impl
        conn = _mock_lint_conn()
        with patch("mcp_server.tools.kdbx_q_analytics.get_kdb_connection", return_value=conn):
            result = await q_lint_impl("bad_mode", "1+1")
        assert result["status"] == "error"
        assert "mode" in result["message"].lower()

    async def test_qlint_not_found_returns_error(self):
        from mcp_server.tools.kdbx_q_analytics import q_lint_impl, _QLINT_NOT_FOUND_MSG
        with patch("mcp_server.tools.kdbx_q_analytics._ensure_qlint_loaded",
                   side_effect=RuntimeError(_QLINT_NOT_FOUND_MSG)):
            conn = MagicMock()
            with patch("mcp_server.tools.kdbx_q_analytics.get_kdb_connection", return_value=conn):
                result = await q_lint_impl("item", "1+1")
        assert result["status"] == "error"
        assert "qlint.q_ not found" in result["message"]

    async def test_pykx_exception_returns_error(self):
        from mcp_server.tools.kdbx_q_analytics import q_lint_impl
        conn = MagicMock(side_effect=Exception("q error: type"))
        with patch("mcp_server.tools.kdbx_q_analytics.get_kdb_connection", return_value=conn):
            result = await q_lint_impl("item", "1+1")
        assert result["status"] == "error"
        assert "type" in result["message"]

    async def test_ensure_qlint_loaded_called_on_every_invocation(self):
        from mcp_server.tools.kdbx_q_analytics import q_lint_impl
        conn = _mock_lint_conn()
        with patch("mcp_server.tools.kdbx_q_analytics.get_kdb_connection", return_value=conn):
            with patch("mcp_server.tools.kdbx_q_analytics._ensure_qlint_loaded") as mock_ensure:
                await q_lint_impl("item", "1+1")
                await q_lint_impl("item", "1+2")
        assert mock_ensure.call_count == 2

    async def test_timeout_returns_error(self):
        """Timeout must return status=error with the exact spec message."""
        from mcp_server.tools.kdbx_q_analytics import q_lint_impl
        conn = _mock_lint_conn()
        with patch("mcp_server.tools.kdbx_q_analytics.get_kdb_connection", return_value=conn):
            with patch("mcp_server.tools.kdbx_q_analytics._ensure_qlint_loaded"):
                with patch("mcp_server.tools.kdbx_q_analytics.asyncio.wait_for",
                           new=AsyncMock(side_effect=asyncio.TimeoutError)):
                    result = await q_lint_impl("item", "f:{x}", timeout=1)
        assert result["status"] == "error"
        assert "qlint timed out after 1s" in result["message"]
