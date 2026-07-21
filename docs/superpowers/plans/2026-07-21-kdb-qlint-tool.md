# kdb-qlint MCP Tool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `kdbx_q_lint` MCP tool that runs the KX Developer linter (`qlint.q_`) against inline q code, a file, or a folder via the existing pykx connection.

**Architecture:** A single new `async def q_lint_impl()` function and tool registration are added directly to `src/mcp_server/tools/kdbx_q_analytics.py` alongside the existing `q_eval_impl` and `q_unit_test_impl`. Two helpers — `_find_qlint()` and `_ensure_qlint_loaded()` — locate and lazily load `qlint.q_` into the connected q session. A new `qlint_path` field in `KDBConfig` lets users override the path via `KDBX_DB_QLINT_PATH`.

**Tech Stack:** Python 3.11, pykx ≥ 4.0.0b4, pydantic-settings, pytest-asyncio

## Global Constraints

- All tests must run without a live KDB-X connection — mock `get_kdb_connection`.
- No new files outside of `tests/tools/test_kdbx_q_lint.py` — all implementation goes into existing files.
- `kdbx_q_lint` registers via the existing `register_tools()` mechanism — just return its name from `register_tools` in `kdbx_q_analytics.py`.
- pykx parameterised calls only — no f-string interpolation of user-supplied `code_or_path` into q expressions.
- All 9 linter table fields preserved in output: `label`, `errorClass`, `description`, `problemText`, `errorMessage`, `startLine`, `startCol`, `endLine`, `endCol`.

---

### Task 1: Add `qlint_path` setting to `KDBConfig`

**Files:**
- Modify: `src/mcp_server/settings.py`

**Interfaces:**
- Produces: `app_settings.db.qlint_path: str` — read by `_find_qlint()` in Task 2.

- [ ] **Step 1: Add the `qlint_path` field to `KDBConfig`**

In `src/mcp_server/settings.py`, add after the `qcumber_path` field (line 68):

```python
    qlint_path: str = Field(
        default="",
        description=(
            "Absolute path to qlint.q_ from KX Developer analyst/ws/. "
            "If unset, the server globs ~/developer-*/analyst/ws/qlint.q_. "
            "Download KX Developer from https://code.kx.com/developer/getting-started/ "
            "[env: KDBX_DB_QLINT_PATH]"
        )
    )
```

- [ ] **Step 2: Verify settings import cleanly**

```bash
cd /path/to/kdb-x-mcp-server
KDBX_DB_QLINT_PATH=/tmp/qlint.q_ python -c "
from src.mcp_server.settings import KDBConfig
c = KDBConfig()
print(c.qlint_path)
"
```
Expected output: `/tmp/qlint.q_`

- [ ] **Step 3: Commit**

```bash
git add src/mcp_server/settings.py
git commit -m "feat(qlint): add qlint_path setting to KDBConfig"
```

---

### Task 2: Add `_find_qlint()`, `_QLINT_NOT_FOUND_MSG`, and `_ensure_qlint_loaded()`

**Files:**
- Modify: `src/mcp_server/tools/kdbx_q_analytics.py`
- Create: `tests/tools/test_kdbx_q_lint.py`

**Interfaces:**
- Consumes: `app_settings.db.qlint_path` from Task 1; `get_kdb_connection()` from `mcp_server.utils.kdbx`.
- Produces:
  - `_find_qlint() -> str` — returns absolute path to `qlint.q_` or `""`.
  - `_ensure_qlint_loaded(conn) -> None` — loads `qlint.q_` into `conn`'s q session exactly once per session; raises `RuntimeError(_QLINT_NOT_FOUND_MSG)` if not found.
  - `_QLINT_NOT_FOUND_MSG: str` — install hint string.

- [ ] **Step 1: Write the failing tests**

Create `tests/tools/test_kdbx_q_lint.py`:

```python
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
```

- [ ] **Step 2: Run to confirm tests fail**

```bash
pytest tests/tools/test_kdbx_q_lint.py::TestFindQlint tests/tools/test_kdbx_q_lint.py::TestEnsureQlintLoaded -v
```
Expected: `ImportError` or `AttributeError` — `_find_qlint` and `_ensure_qlint_loaded` don't exist yet.

- [ ] **Step 3: Add `_QLINT_NOT_FOUND_MSG`, `_find_qlint()`, and `_ensure_qlint_loaded()` to `kdbx_q_analytics.py`**

After the existing `_QCUMBER_DOWNLOAD_MSG` constant and `_find_qcumber()` function, insert:

```python
_QLINT_NOT_FOUND_MSG = (
    "qlint.q_ not found. It is bundled with KX Developer (KX Analyst).\n"
    "\n"
    "  Quickest fix — run the bundled install script to vendor ax-libraries:\n"
    "    ./scripts/install_ax_libraries.sh [/path/to/developer-<ver>-<os>]\n"
    "\n"
    "  Download KX Developer from: https://code.kx.com/developer/getting-started/\n"
    "\n"
    "  After downloading, you can also set:\n"
    "    • KDBX_DB_QLINT_PATH=/path/to/developer-<ver>-<os>/analyst/ws/qlint.q_\n"
    "  Or pass qlint_path directly in the tool call."
)


def _find_qlint() -> str:
    """Locate qlint.q_ from settings, env vars, or the KX Developer install glob.

    Search order:
      1. Explicit KDBX_DB_QLINT_PATH setting / env var
      2. vendor/ax-libraries/ws/qlint.q_   (project-local)
      3. ~/.kx/ax-libraries/ws/qlint.q_    (standard KX tooling home)
      4. AXLIBRARIES_HOME/ws/qlint.q_      (explicit env override)
      5. ~/developer-*/analyst/ws/qlint.q_ (KX Developer install glob)
    """
    # 1. Explicit setting
    configured = app_settings.db.qlint_path
    if configured and os.path.isfile(configured):
        return configured

    # 2. Project-local vendor
    _project_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__)
    ))))
    vendor_candidate = os.path.join(_project_root, "vendor", "ax-libraries", "ws", "qlint.q_")
    if os.path.isfile(vendor_candidate):
        return vendor_candidate

    # 3. Standard KX tooling home
    kx_candidate = os.path.join(os.path.expanduser("~"), ".kx", "ax-libraries", "ws", "qlint.q_")
    if os.path.isfile(kx_candidate):
        return kx_candidate

    # 4. AXLIBRARIES_HOME
    ax = os.environ.get("AXLIBRARIES_HOME", "")
    if ax:
        candidate = os.path.join(ax, "ws", "qlint.q_")
        if os.path.isfile(candidate):
            return candidate

    # 5. KX Developer install — qlint.q_ lives in analyst/ws/ only
    for pattern in [
        os.path.expanduser("~/developer-*/analyst/ws/qlint.q_"),
        os.path.expanduser("~/developer-*-osx/analyst/ws/qlint.q_"),
        os.path.expanduser("~/developer-*-linux/analyst/ws/qlint.q_"),
        os.path.expanduser("~/.kx/developer-*/analyst/ws/qlint.q_"),
        "/opt/developer/analyst/ws/qlint.q_",
        "/usr/local/developer/analyst/ws/qlint.q_",
    ]:
        matches = sorted(glob.glob(pattern), reverse=True)
        if matches:
            return matches[0]

    return ""


def _ensure_qlint_loaded(conn) -> None:
    """Load qlint.q_ into the q session if not already present.

    Checks for the .qlint namespace in the connected q session. If absent,
    changes q's working directory to analyst/ws/ (so relative deps resolve)
    and loads qlint.q_.

    Raises RuntimeError if qlint.q_ cannot be located.
    """
    already = conn("{@[{key .qlint; 1b}; (::); {0b}]}")
    if hasattr(already, "py"):
        already = already.py()
    if already:
        return

    qlint_path = _find_qlint()
    if not qlint_path:
        raise RuntimeError(_QLINT_NOT_FOUND_MSG)

    analyst_ws = os.path.dirname(qlint_path)
    conn(f"\\cd {analyst_ws}")
    conn("\\l qlint.q_")
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
pytest tests/tools/test_kdbx_q_lint.py::TestFindQlint tests/tools/test_kdbx_q_lint.py::TestEnsureQlintLoaded -v
```
Expected:
```
tests/tools/test_kdbx_q_lint.py::TestFindQlint::test_returns_explicit_setting_when_file_exists PASSED
tests/tools/test_kdbx_q_lint.py::TestFindQlint::test_returns_empty_string_when_not_found PASSED
tests/tools/test_kdbx_q_lint.py::TestFindQlint::test_returns_glob_match_when_no_explicit_setting PASSED
tests/tools/test_kdbx_q_lint.py::TestEnsureQlintLoaded::test_skips_load_when_already_in_session PASSED
tests/tools/test_kdbx_q_lint.py::TestEnsureQlintLoaded::test_loads_when_not_in_session PASSED
tests/tools/test_kdbx_q_lint.py::TestEnsureQlintLoaded::test_raises_when_qlint_not_found PASSED
6 passed
```

- [ ] **Step 5: Commit**

```bash
git add src/mcp_server/tools/kdbx_q_analytics.py tests/tools/test_kdbx_q_lint.py
git commit -m "feat(qlint): add _find_qlint and _ensure_qlint_loaded helpers"
```

---

### Task 3: Implement `q_lint_impl()` and register `kdbx_q_lint` tool

**Files:**
- Modify: `src/mcp_server/tools/kdbx_q_analytics.py`
- Modify: `tests/tools/test_kdbx_q_lint.py`

**Interfaces:**
- Consumes: `_ensure_qlint_loaded(conn)` from Task 2; `get_kdb_connection()` from utils.
- Produces: `q_lint_impl(mode, code_or_path, timeout) -> Dict[str, Any]` and registered MCP tool `kdbx_q_lint`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/tools/test_kdbx_q_lint.py`:

```python
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
```

- [ ] **Step 2: Run to confirm tests fail**

```bash
pytest tests/tools/test_kdbx_q_lint.py::TestQLintImpl -v
```
Expected: `ImportError` — `q_lint_impl` not defined yet.

- [ ] **Step 3: Implement `q_lint_impl()` in `kdbx_q_analytics.py`**

Add after `q_unit_test_impl`, before the `register_tools` function:

```python
async def q_lint_impl(
    mode: str,
    code_or_path: str,
    timeout: int = 30,
) -> Dict[str, Any]:
    """Lint q code or a file/folder via qlint.q_ loaded into the q session."""
    _preview = code_or_path[:200] + ("..." if len(code_or_path) > 200 else "")
    logger.info(f"kdbx_q_lint: mode={mode!r} | input={_preview!r}")
    t0 = time.perf_counter()

    if mode not in ("item", "file", "folder"):
        return {
            "status": "error",
            "message": f"Invalid mode {mode!r}. Must be 'item', 'file', or 'folder'.",
        }

    try:
        conn = get_kdb_connection()
        _ensure_qlint_loaded(conn)

        arg = code_or_path.encode()
        if mode == "item":
            raw = conn("{.j.j .qlint.lintItem[x; ::]}", arg)
        elif mode == "file":
            raw = conn("{.j.j .qlint.lintFile[x]}", arg)
        else:
            raw = conn("{.j.j .qlint.lintFolder[x]}", arg)

        elapsed = time.perf_counter() - t0

        if hasattr(raw, "py"):
            raw = raw.py()
        if isinstance(raw, (bytes, bytearray)):
            raw = raw.decode("utf-8")

        try:
            violations_raw = json.loads(raw) if isinstance(raw, str) else raw
        except Exception:
            violations_raw = []

        if not isinstance(violations_raw, list):
            violations_raw = []

        def _s(v):
            if isinstance(v, (bytes, bytearray)):
                return v.decode("utf-8")
            return v if v is not None else ""

        violations = [
            {
                "label":        _s(row.get("label", "")),
                "errorClass":   _s(row.get("errorClass", "")),
                "description":  _s(row.get("description", "")),
                "problemText":  _s(row.get("problemText", "")),
                "errorMessage": _s(row.get("errorMessage", "")),
                "startLine":    row.get("startLine", 0),
                "startCol":     row.get("startCol", 0),
                "endLine":      row.get("endLine", 0),
                "endCol":       row.get("endCol", 0),
            }
            for row in violations_raw
            if isinstance(row, dict)
        ]

        logger.info(
            f"kdbx_q_lint: completed in {elapsed:.3f}s"
            f" | mode={mode!r} | violations={len(violations)}"
        )
        return {
            "status": "ok",
            "clean": len(violations) == 0,
            "violation_count": len(violations),
            "violations": violations,
        }

    except RuntimeError as e:
        return {"status": "error", "message": str(e)}
    except Exception as e:
        elapsed = time.perf_counter() - t0
        logger.error(f"kdbx_q_lint: exception after {elapsed:.3f}s | error={e!r}")
        return {"status": "error", "message": str(e)}
```

- [ ] **Step 4: Register `kdbx_q_lint` in `register_tools()`**

In `register_tools(mcp_server)`, after the `kdbx_q_unit_test` registration, add:

```python
    @mcp_server.tool()
    async def kdbx_q_lint(
        mode: str,
        code_or_path: str,
        timeout: int = 30,
    ) -> Dict[str, Any]:
        """
        Lint q/kdb+ code using the KX Developer static linter (qlint.q_).

        Use this as the FIRST gate before kdbx_q_eval or kdbx_q_unit_test.
        It runs purely static analysis — no code is executed.

        Modes
        -----
        item   Lint an inline q code string.
               code_or_path = "myFunc:{[x;y] y*2}"

        file   Lint a single .q or .quke file.
               code_or_path = "/q-modules/finstat/finstat.q"
               Paths under q-modules/ are mounted and accessible.

        folder Recursively lint all .q files in a directory.
               code_or_path = "/q-modules/finstat"

        Output
        ------
        Returns a dict with:
          status          – "ok" or "error"
          clean           – true when no violations found
          violation_count – total number of violations
          violations      – list of violation objects, each with:
                            label, errorClass, description, problemText,
                            errorMessage, startLine, startCol, endLine, endCol

        Common errorClass values
        ------------------------
          UNUSED_PARAM       – function parameter declared but never referenced
          UNDECLARED_VAR     – variable used without prior assignment
          ASSIGN_RESERVED_WORD – assignment to a built-in q name
          FIXED_SEED         – use of a hard-coded random seed

        Args:
            mode         (str): "item", "file", or "folder"
            code_or_path (str): Inline q code (item) or filesystem path (file/folder)
            timeout      (int): Seconds before giving up (default 30)

        Returns:
            Dict with keys: status, clean, violation_count, violations
        """
        return await q_lint_impl(
            mode=mode,
            code_or_path=code_or_path,
            timeout=timeout,
        )
```

Update the return statement to include the new tool name:

```python
    return ['kdbx_q_eval', 'kdbx_q_unit_test', 'kdbx_q_lint']
```

- [ ] **Step 5: Run all lint tests**

```bash
pytest tests/tools/test_kdbx_q_lint.py -v
```
Expected:
```
tests/tools/test_kdbx_q_lint.py::TestFindQlint::test_returns_explicit_setting_when_file_exists PASSED
tests/tools/test_kdbx_q_lint.py::TestFindQlint::test_returns_empty_string_when_not_found PASSED
tests/tools/test_kdbx_q_lint.py::TestFindQlint::test_returns_glob_match_when_no_explicit_setting PASSED
tests/tools/test_kdbx_q_lint.py::TestEnsureQlintLoaded::test_skips_load_when_already_in_session PASSED
tests/tools/test_kdbx_q_lint.py::TestEnsureQlintLoaded::test_loads_when_not_in_session PASSED
tests/tools/test_kdbx_q_lint.py::TestEnsureQlintLoaded::test_raises_when_qlint_not_found PASSED
tests/tools/test_kdbx_q_lint.py::TestQLintImpl::test_item_clean_returns_clean_true PASSED
tests/tools/test_kdbx_q_lint.py::TestQLintImpl::test_item_with_violation_returns_clean_false PASSED
tests/tools/test_kdbx_q_lint.py::TestQLintImpl::test_item_preserves_all_nine_fields PASSED
tests/tools/test_kdbx_q_lint.py::TestQLintImpl::test_file_mode_dispatches_lintFile PASSED
tests/tools/test_kdbx_q_lint.py::TestQLintImpl::test_folder_mode_dispatches_lintFolder PASSED
tests/tools/test_kdbx_q_lint.py::TestQLintImpl::test_invalid_mode_returns_error PASSED
tests/tools/test_kdbx_q_lint.py::TestQLintImpl::test_qlint_not_found_returns_error PASSED
tests/tools/test_kdbx_q_lint.py::TestQLintImpl::test_pykx_exception_returns_error PASSED
tests/tools/test_kdbx_q_lint.py::TestQLintImpl::test_ensure_qlint_loaded_called_on_every_invocation PASSED
15 passed
```

- [ ] **Step 6: Run the full test suite to confirm no regressions**

```bash
pytest tests/ -v --ignore=tests/test_docker_mcp_server.py
```
Expected: all existing tests still pass.

- [ ] **Step 7: Commit**

```bash
git add src/mcp_server/tools/kdbx_q_analytics.py tests/tools/test_kdbx_q_lint.py
git commit -m "feat(qlint): add q_lint_impl and register kdbx_q_lint MCP tool"
```
