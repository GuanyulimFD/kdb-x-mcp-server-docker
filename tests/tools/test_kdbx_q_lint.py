"""
Unit tests for kdbx_q_lint helpers and tool.
No live KDB-X connection required — all pykx calls are mocked.
"""
import json
import pytest
from unittest.mock import MagicMock, patch, call


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
