"""
Unit tests for kdbx_q_lint helpers and tool.
No live KDB-X connection required — subprocess.run is mocked.
"""
import json
import subprocess
import pytest
from unittest.mock import MagicMock, patch


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
# q_lint_impl
# ---------------------------------------------------------------------------

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


def _ok_proc(violations=None):
    """Fake completed subprocess with JSON stdout."""
    proc = MagicMock()
    proc.returncode = 0
    proc.stdout = json.dumps(violations or [])
    proc.stderr = ""
    return proc


class TestQLintImpl:

    @pytest.fixture(autouse=True)
    def _patch_paths(self):
        """Provide fake q binary and qlint path so subprocess.run is the only variable."""
        with patch("mcp_server.tools.kdbx_q_analytics._find_q_binary", return_value="/fake/q"), \
             patch("mcp_server.tools.kdbx_q_analytics._find_qlint",
                   return_value="/fake/analyst/ws/qlint.q_"):
            yield

    async def test_item_clean_returns_clean_true(self):
        from mcp_server.tools.kdbx_q_analytics import q_lint_impl
        with patch("subprocess.run", return_value=_ok_proc([])):
            result = await q_lint_impl("item", "1+1")
        assert result["status"] == "ok"
        assert result["clean"] is True
        assert result["violation_count"] == 0
        assert result["violations"] == []

    async def test_item_with_violation_returns_clean_false(self):
        from mcp_server.tools.kdbx_q_analytics import q_lint_impl
        with patch("subprocess.run", return_value=_ok_proc([SAMPLE_VIOLATION])):
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
        with patch("subprocess.run", return_value=_ok_proc([SAMPLE_VIOLATION])):
            result = await q_lint_impl("item", "myFunc:{[x;y] y*2}")
        v = result["violations"][0]
        for field in ("label", "errorClass", "description", "problemText",
                      "errorMessage", "startLine", "startCol", "endLine", "endCol"):
            assert field in v, f"Missing field: {field}"

    async def test_file_mode_uses_lintFile_in_runner(self):
        from mcp_server.tools.kdbx_q_analytics import q_lint_impl
        captured = {}

        def capture_run(cmd, **kwargs):
            runner_path = cmd[-2]  # arch_prefix + [q_bin, runner_file, "-q"]
            with open(runner_path) as f:
                captured["script"] = f.read()
            return _ok_proc([])

        with patch("subprocess.run", side_effect=capture_run):
            result = await q_lint_impl("file", "/q-modules/finstat/finstat.q")
        assert result["status"] == "ok"
        assert "lintFile" in captured["script"]

    async def test_folder_mode_uses_lintFolder_in_runner(self):
        from mcp_server.tools.kdbx_q_analytics import q_lint_impl
        captured = {}

        def capture_run(cmd, **kwargs):
            runner_path = cmd[-2]
            with open(runner_path) as f:
                captured["script"] = f.read()
            return _ok_proc([])

        with patch("subprocess.run", side_effect=capture_run):
            result = await q_lint_impl("folder", "/q-modules/finstat")
        assert result["status"] == "ok"
        assert "lintFolder" in captured["script"]

    async def test_invalid_mode_returns_error(self):
        from mcp_server.tools.kdbx_q_analytics import q_lint_impl
        with patch("subprocess.run", return_value=_ok_proc()):
            result = await q_lint_impl("bad_mode", "1+1")
        assert result["status"] == "error"
        assert "mode" in result["message"].lower()

    async def test_qlint_not_found_returns_error(self):
        from mcp_server.tools.kdbx_q_analytics import q_lint_impl, _QLINT_NOT_FOUND_MSG
        with patch("mcp_server.tools.kdbx_q_analytics._find_qlint", return_value=""):
            result = await q_lint_impl("item", "1+1")
        assert result["status"] == "error"
        assert "qlint.q_ not found" in result["message"]

    async def test_subprocess_nonzero_exit_returns_error(self):
        from mcp_server.tools.kdbx_q_analytics import q_lint_impl
        proc = MagicMock()
        proc.returncode = 1
        proc.stdout = ""
        proc.stderr = "error loading lib"
        with patch("subprocess.run", return_value=proc):
            result = await q_lint_impl("item", "1+1")
        assert result["status"] == "error"
        assert "error loading lib" in result["message"]

    async def test_timeout_returns_error(self):
        from mcp_server.tools.kdbx_q_analytics import q_lint_impl
        with patch("subprocess.run",
                   side_effect=subprocess.TimeoutExpired(cmd="q", timeout=1)):
            result = await q_lint_impl("item", "1+1", timeout=1)
        assert result["status"] == "error"
        assert "qlint timed out after 1s" in result["message"]
