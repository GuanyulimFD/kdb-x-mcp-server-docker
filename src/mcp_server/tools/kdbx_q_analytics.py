import glob
import logging
import json
import os
import platform
import subprocess
import tempfile
import shutil
import time
from typing import Dict, Any, List, Optional, Tuple
from mcp_server.utils.kdbx import get_kdb_connection
from mcp_server.server import app_settings

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _find_q_binary() -> str:
    """Locate the q binary, mirroring the priority order in start_kdbx.sh."""
    candidates = [
        os.path.expanduser("~/.kx/bin/q"),
        os.path.join(os.environ.get("QHOME", ""), "m64", "q"),
        os.path.join(os.environ.get("QHOME", ""), "l64", "q"),
    ]
    for c in candidates:
        if c and os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    found = shutil.which("q")
    return found or ""


# Download instructions shown when qcumber.q_ cannot be found
_QCUMBER_DOWNLOAD_MSG = (
    "qcumber.q_ not found. It is bundled with KX Analyst (KX Developer).\n"
    "\n"
    "  Quickest fix — run the bundled install script to vendor ax-libraries:\n"
    "    ./scripts/install_ax_libraries.sh [/path/to/developer-<ver>-<os>]\n"
    "\n"
    "  Download KX Analyst from: https://code.kx.com/developer/getting-started/\n"
    "\n"
    "  After downloading, you can also set one of:\n"
    "    • AXLIBRARIES_HOME=/path/to/developer-<ver>-<os>/ax-libraries\n"
    "    • KDBX_DB_QCUMBER_PATH=/path/to/developer-<ver>-<os>/ax-libraries/ws/qcumber.q_\n"
    "  Or pass qcumber_path directly in the tool call."
)


def _find_qcumber() -> str:
    """Resolve qcumber.q_ path from settings, env vars, or common locations.

    Search order:
      1. Explicit KDBX_DB_QCUMBER_PATH setting / env var
      2. vendor/ax-libraries/ws/qcumber.q_  (project-local, --project flag)
      3. ~/.kx/ax-libraries/ws/qcumber.q_   (standard KX tooling home, default
         install destination of scripts/install_ax_libraries.sh)
      4. AXLIBRARIES_HOME/ws/qcumber.q_     (explicit env override)
      5. KX Analyst default install: ~/developer-*[-osx|-linux]/ax-libraries/ws/
      6. ~/.kx/lib, ~/ax-libraries, /usr/local/lib fallbacks
    """
    # 1. Explicit setting / env var
    configured = app_settings.db.qcumber_path
    if configured and os.path.isfile(configured):
        return configured

    # 2. Project-local vendor/ax-libraries (installed via install_ax_libraries.sh --project)
    #    Derive project root as two levels up from this file:
    #    src/mcp_server/tools/kdbx_q_analytics.py → project root
    _this_file = os.path.abspath(__file__)
    _project_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(_this_file))))
    vendor_candidate = os.path.join(_project_root, "vendor", "ax-libraries", "ws", "qcumber.q_")
    if os.path.isfile(vendor_candidate):
        return vendor_candidate

    # 3. Standard KX tooling home: ~/.kx/ax-libraries  (default install destination)
    #    Sits alongside ~/.kx/bin/q — no env var required after running
    #    scripts/install_ax_libraries.sh (the default, no flags needed).
    kx_candidate = os.path.join(os.path.expanduser("~"), ".kx", "ax-libraries", "ws", "qcumber.q_")
    if os.path.isfile(kx_candidate):
        return kx_candidate

    # 4. AXLIBRARIES_HOME standard layout
    ax = os.environ.get("AXLIBRARIES_HOME", "")
    if ax:
        candidate = os.path.join(ax, "ws", "qcumber.q_")
        if os.path.isfile(candidate):
            return candidate

    # 5. KX Analyst – glob any versioned developer-* install under HOME
    #    On macOS arm64, analyst/ws/qcumber.q_ is PREFERRED over ax-libraries/ws/qcumber.q_
    #    because running analyst qcumber with cwd=ax-libraries/ws/ makes q load .qu.*.q_
    #    deps via a *relative* path (no QHOME/m64 prepend) — the only way native libs work.
    for pattern in [
        os.path.expanduser("~/developer-*/analyst/ws/qcumber.q_"),
        os.path.expanduser("~/developer-*-osx/analyst/ws/qcumber.q_"),
        os.path.expanduser("~/developer-*-linux/analyst/ws/qcumber.q_"),
        os.path.expanduser("~/developer-*/ax-libraries/ws/qcumber.q_"),
        os.path.expanduser("~/developer-*-osx/ax-libraries/ws/qcumber.q_"),
        os.path.expanduser("~/developer-*-linux/ax-libraries/ws/qcumber.q_"),
        os.path.expanduser("~/.kx/developer-*/analyst/ws/qcumber.q_"),
        "/opt/developer/analyst/ws/qcumber.q_",
        "/usr/local/developer/analyst/ws/qcumber.q_",
    ]:
        matches = sorted(glob.glob(pattern), reverse=True)  # newest version first
        if matches:
            return matches[0]

    # 6. Legacy / alternative install paths
    for candidate in [
        os.path.expanduser("~/.kx/lib/qcumber.q_"),
        os.path.expanduser("~/ax-libraries/ws/qcumber.q_"),
        "/usr/local/lib/qcumber.q_",
    ]:
        if os.path.isfile(candidate):
            return candidate

    return ""


def _get_q_arch_prefix() -> list:
    """
    On arm64 macOS the ax-libraries native .so files are x86_64 only.
    Force the q process to run as x86_64 via Rosetta 2 so dlopen succeeds.
    On all other platforms (Linux arm64, x86_64) no prefix is needed.
    """
    if platform.machine() == "arm64" and platform.system() == "Darwin":
        return ["arch", "-x86_64"]
    return []


def _derive_axlibraries_home(qcumber_path: str) -> str:
    """
    Derive AXLIBRARIES_HOME from the resolved qcumber.q_ path.

    Layout examples:
      ~/developer-1.5.4-osx/ax-libraries/ws/qcumber.q_  → ~/developer-1.5.4-osx/ax-libraries
      ~/developer-1.5.4-osx/analyst/ws/qcumber.q_       → ~/developer-1.5.4-osx/ax-libraries
    """
    ws_dir  = os.path.dirname(qcumber_path)          # …/ws
    pkg_dir = os.path.dirname(ws_dir)                # …/ax-libraries  OR  …/analyst

    # Case A: qcumber is already inside ax-libraries
    if os.path.basename(pkg_dir) == "ax-libraries":
        return pkg_dir

    # Case B: qcumber is inside analyst (or similar) – look for ax-libraries sibling
    root_dir = os.path.dirname(pkg_dir)              # ~/developer-X.Y.Z-osx
    candidate = os.path.join(root_dir, "ax-libraries")
    if os.path.isdir(candidate):
        return candidate

    # Fallback – return the ws parent as best guess
    return pkg_dir


async def q_eval_impl(code: str) -> Dict[str, Any]:
    """Execute a raw q expression and return the result."""
    _preview = code[:300] + ("..." if len(code) > 300 else "")
    logger.info(f"kdbx_q_eval: evaluating q expression ({len(code)} chars) | code={_preview!r}")
    t0 = time.perf_counter()
    try:
        conn = get_kdb_connection()

        # Wrap evaluation in a protected call so q parse/runtime errors are
        # surfaced as structured data rather than raising a pykx exception.
        result = conn(
            '{res:@[value; x; {`status`error!(`error; x)}]; '
            '$[99h=type res; '
            '  $[`status in key res; $[res[`status]=`error; res; `status`result!((`ok); .j.j res)]; `status`result!((`ok); .j.j res)]; '
            '  `status`result!((`ok); .j.j res)]}',
            code.encode()
        )

        elapsed = time.perf_counter() - t0
        status = str(result['status'])
        if status == 'error':
            error_msg = result['error'].py() if hasattr(result['error'], 'py') else str(result['error'])
            logger.warning(
                f"kdbx_q_eval: q error after {elapsed:.3f}s | error={error_msg!r} | code={_preview!r}"
            )
            return {"status": "error", "message": error_msg}

        raw = result['result']
        if hasattr(raw, 'py'):
            raw = raw.py()
        if isinstance(raw, (bytes, bytearray)):
            raw = raw.decode('utf-8')
        try:
            parsed = json.loads(raw)
        except Exception:
            parsed = raw

        result_type = type(parsed).__name__
        result_size = len(parsed) if isinstance(parsed, (list, dict, str)) else ""
        size_str = f", size={result_size}" if result_size != "" else ""
        logger.info(
            f"kdbx_q_eval: completed in {elapsed:.3f}s | status=ok | result_type={result_type}{size_str}"
        )
        return {"status": "ok", "result": parsed}

    except Exception as e:
        elapsed = time.perf_counter() - t0
        logger.error(f"kdbx_q_eval: exception after {elapsed:.3f}s | error={e!r} | code={_preview!r}")
        return {"status": "error", "message": str(e)}


# ---------------------------------------------------------------------------
# kdbx_q_unit_test  (qCumber-backed)
# ---------------------------------------------------------------------------

def _parse_qcumber_json(raw: Any) -> List[Dict[str, Any]]:
    """
    Normalise the JSON array written by qcumber -out results.json.

    qCumber 1.x output schema (actual fields observed):
      success      bool   – did the expectation pass?
      feature      str    – feature block name
      description  str    – should block description
      expectations str    – expect label
      error        str    – error message (empty string on pass)
      aborted      bool
      skipped      bool
      parseError   bool

    Legacy / alternate field names are also handled.
    """
    results = []
    if not isinstance(raw, list):
        raw = [raw]
    for item in raw:
        if not isinstance(item, dict):
            continue
        # Skip meta / summary rows that only have totals
        if not any(k in item for k in ("success", "feature", "result", "passed")):
            continue
        # Resolve pass/fail — prefer the explicit boolean "success" field
        passed = item.get("success")
        if passed is None:
            passed = item.get("passed", item.get("status", ""))
        if isinstance(passed, str):
            passed = passed.lower() in ("pass", "passed", "true", "1")
        elif isinstance(passed, (int, float)):
            passed = bool(passed)
        else:
            passed = bool(passed)

        # Description is "description" in qCumber 1.x, "should" in older schemas
        should = item.get("description", item.get("should", ""))
        # Expectation label
        expect = item.get("expectations", item.get("expect", item.get("expectation", "")))
        # Error text
        error  = item.get("error") or None

        results.append({
            "feature": item.get("feature", ""),
            "should":  should,
            "expect":  expect,
            "passed":  passed,
            "error":   error if error else None,
            "time_ms": item.get("time", None),
        })
    return results


async def q_unit_test_impl(
    quke_content: str,
    setup_code: Optional[str] = None,
    qcumber_path: Optional[str] = None,
    timeout: int = 60,
) -> Dict[str, Any]:
    """
    Write a .quke file and run it through the qCumber test runner.
    Returns a structured pass/fail report.
    """
    logger.info(
        f"kdbx_q_unit_test: starting | quke_chars={len(quke_content)}"
        f" | setup={'yes' if setup_code and setup_code.strip() else 'no'}"
        f" | timeout={timeout}s"
    )
    if setup_code and setup_code.strip():
        _setup_preview = setup_code[:200] + ("..." if len(setup_code) > 200 else "")
        logger.debug(f"kdbx_q_unit_test: setup_code={_setup_preview!r}")

    t0 = time.perf_counter()

    q_bin = _find_q_binary()
    if not q_bin:
        logger.error("kdbx_q_unit_test: cannot locate q binary")
        return {
            "status": "error",
            "message": "Cannot locate q binary. Set Q_BINARY or ensure ~/.kx/bin/q exists.",
        }

    qc_path = qcumber_path or _find_qcumber()
    if not qc_path:
        logger.error("kdbx_q_unit_test: qcumber.q_ not found")
        return {"status": "error", "message": _QCUMBER_DOWNLOAD_MSG}

    logger.debug(f"kdbx_q_unit_test: q_bin={q_bin!r} | qcumber={qc_path!r}")

    tmpdir = tempfile.mkdtemp(prefix="kdbx_qcumber_")
    try:
        quke_file    = os.path.join(tmpdir, "test.quke")
        results_file = os.path.join(tmpdir, "results.json")

        with open(quke_file, "w") as f:
            f.write(quke_content)

        # Derive ax-libraries home and the ws/ directory used as cwd.
        # Running analyst/ws/qcumber.q_ with cwd=ax-libraries/ws/ forces q to load
        # .qu.*.q_ deps via a *relative* path (\l .qu.to), which avoids the
        # QHOME/m64/<absolute> mis-construction that happens with absolute paths.
        ax_home = os.environ.get("AXLIBRARIES_HOME") or _derive_axlibraries_home(qc_path)
        ax_ws   = os.path.join(ax_home, "ws")   # cwd during qcumber run
        if not os.path.isdir(ax_ws):
            ax_ws = None  # fall back to no cwd override

        # On arm64 macOS, force Rosetta 2 (x86_64) so the osx_x64 native .so
        # files in ax-libraries/ws/lib/osx_x64/ can be loaded (they are Intel only).
        arch_prefix = _get_q_arch_prefix()

        # Build subprocess environment
        # q resolves `2: (`libname; ...) via $QHOME/<arch>/libname.so.
        # The Dockerfile copies ax-libs there at build time.
        # As a belt-and-braces fallback, also add the top-level ws/lib/ to the
        # appropriate dynamic linker search path env variable.
        ax_lib_dir = os.path.join(ax_home, "ws", "lib")
        if platform.system() == "Darwin":
            extra_lib_env = {
                "DYLD_LIBRARY_PATH": os.pathsep.join(filter(None, [
                    os.path.join(ax_lib_dir, "osx_x64"),
                    ax_lib_dir,
                    os.environ.get("DYLD_LIBRARY_PATH", ""),
                ])),
            }
        else:
            # Linux: LD_LIBRARY_PATH
            extra_lib_env = {
                "LD_LIBRARY_PATH": os.pathsep.join(filter(None, [
                    ax_lib_dir,
                    os.environ.get("LD_LIBRARY_PATH", ""),
                ])),
            }
        env = {
            **os.environ,
            "QLIC": os.environ.get("QLIC", os.path.expanduser("~/.kx")),
            "AXLIBRARIES_HOME": ax_home,
            **extra_lib_env,
        }
        logger.info(f"kdbx_q_unit_test: AXLIBRARIES_HOME={ax_home} | cwd={ax_ws} | arch_prefix={arch_prefix}")

        cmd = arch_prefix + [q_bin, qc_path, "-test", quke_file, "-out", results_file, "-quiet"]

        # Always pass -src to qcumber, even when setup_code is empty.
        # qcumber requires a -src file for `before` blocks to function correctly
        # with KDB-X 5.0 — without -src, before block processing raises 'type.
        # A no-op "1b" is written when the caller provides no setup_code.
        setup_file = os.path.join(tmpdir, "setup.q")
        with open(setup_file, "w") as f:
            f.write(setup_code if (setup_code and setup_code.strip()) else "1b")
        cmd += ["-src", setup_file]

        logger.info(f"kdbx_q_unit_test: running qCumber | cmd={' '.join(cmd)!r}")
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            env=env,
            cwd=ax_ws,             # resolve .qu.*.q_ deps relative to ax-libraries/ws/
            stdin=subprocess.DEVNULL,  # prevent q from waiting for interactive input
        )
        elapsed = time.perf_counter() - t0
        logger.debug(
            f"kdbx_q_unit_test: qCumber subprocess exited | returncode={proc.returncode}"
            f" | elapsed={elapsed:.3f}s"
        )
        if proc.stdout.strip():
            logger.debug(f"kdbx_q_unit_test: qCumber stdout={proc.stdout.strip()!r}")
        if proc.stderr.strip():
            logger.debug(f"kdbx_q_unit_test: qCumber stderr={proc.stderr.strip()!r}")

        # Parse JSON results file produced by qcumber -out
        tests: List[Dict[str, Any]] = []
        if os.path.isfile(results_file) and os.path.getsize(results_file) > 0:
            with open(results_file) as f:
                raw_json = json.load(f)
            tests = _parse_qcumber_json(raw_json)
        elif proc.returncode not in (0, 1):  # 1 = test failures (expected)
            logger.error(
                f"kdbx_q_unit_test: qCumber exited with unexpected code {proc.returncode}"
                f" | stderr={proc.stderr.strip()!r}"
            )
            return {
                "status": "error",
                "message": f"qCumber exited with code {proc.returncode}",
                "stderr": proc.stderr.strip(),
                "stdout": proc.stdout.strip(),
            }

        passed = sum(1 for t in tests if t["passed"])
        failed = len(tests) - passed
        summary = f"{passed}/{len(tests)} passed" + (f", {failed} failed" if failed else "")

        # Log a one-line summary always, then individual failures at WARNING level
        log_fn = logger.warning if failed else logger.info
        log_fn(
            f"kdbx_q_unit_test: {summary} | elapsed={elapsed:.3f}s"
            f" | quke_chars={len(quke_content)}"
        )
        for t in tests:
            if not t["passed"]:
                logger.warning(
                    f"kdbx_q_unit_test: FAIL | feature={t['feature']!r}"
                    f" | should={t['should']!r} | expect={t['expect']!r}"
                    + (f" | error={t['error']!r}" if t.get("error") else "")
                )

        return {
            "status": "ok",
            "summary": summary,
            "passed": passed,
            "failed": failed,
            "total": len(tests),
            "tests": tests,
            "stdout": proc.stdout.strip() or None,
        }

    except subprocess.TimeoutExpired:
        elapsed = time.perf_counter() - t0
        logger.error(f"kdbx_q_unit_test: timed out after {elapsed:.3f}s (limit={timeout}s)")
        return {"status": "error", "message": f"qCumber timed out after {timeout}s"}
    except Exception as e:
        elapsed = time.perf_counter() - t0
        logger.error(f"kdbx_q_unit_test: exception after {elapsed:.3f}s | error={e!r}")
        return {"status": "error", "message": str(e)}
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------

def register_tools(mcp_server):

    @mcp_server.tool()
    async def kdbx_q_eval(code: str) -> Dict[str, Any]:
        """
        Evaluate a raw q expression on the connected KDB-X server and return
        the result. Use this to:
          - Define q functions in the server's global namespace for later use
          - Inspect tables, variables and namespaces (e.g. `tables[]`, `key .q`)
          - Run one-off q analytics and transformations
          - Prototype logic before formalising it as a unit-tested function

        The expression is executed inside a protected call so parse errors and
        runtime errors are returned as structured error objects rather than
        raising an exception.

        Examples
        --------
        Define a function:
            code = "myVwap:{[t] select vwap: size wavg price by sym from t}"

        Inspect available tables:
            code = "tables[]"

        Quick calculation:
            code = "sum 1 2 3 4 5"

        Args:
            code (str): Any valid q expression or statement.

        Returns:
            Dict with keys:
              status  – "ok" or "error"
              result  – JSON-serialisable representation of the q result (ok)
              message – error description (error)
        """
        return await q_eval_impl(code)

    @mcp_server.tool()
    async def kdbx_q_unit_test(
        quke_content: str,
        setup_code: Optional[str] = None,
        qcumber_path: Optional[str] = None,
        timeout: int = 60,
    ) -> Dict[str, Any]:
        """
        Run a qCumber (.quke) test suite against the KDB-X server.

        qCumber is the standard KX unit-testing framework. Tests are written in
        the .quke DSL (feature / should / expect blocks) and executed via the
        qcumber.q_ binary from ax-libraries.

        Workflow for Copilot
        --------------------
        1. Use `kdbx_q_eval` to prototype and refine q functions interactively.
        2. Once satisfied, encode the final function definitions in `setup_code`.
        3. Write .quke assertions in `quke_content` and call this tool.
        4. Read the pass/fail report and iterate until all tests pass.

        .quke file format
        -----------------
        feature <Feature name>

            [before]          <- optional: runs once before all shoulds
                <q code>

            [before each]     <- optional: runs before each should
                <q code>

            should <behaviour description>
                expect <assertion description>
                    <q expression that must return 1b to pass>

                expect <use .qu.compare for value diff>
                    .qu.compare[expected; actual]

            [after]           <- optional: teardown
                <q code>

        Example
        -------
        setup_code:
            "double:{x*2}; vwap:{select vwap:size wavg price by sym from x}"

        quke_content:
            '''
            feature double function

                should multiply by two
                    expect double 5 to be 10
                        10 ~ double[5]

                    expect double 0 to be 0
                        0 ~ double[0]

                    expect .qu.compare for clear diff output
                        .qu.compare[10; double[5]]

            feature vwap function

                before
                    trade :: ([]sym:`AAPL`GOOG`AAPL; price:100 200 110f; size:100 50 200)

                should group by sym
                    expect result to be a table
                        98h = type vwap[trade]

                    expect AAPL vwap
                        t: vwap[trade];
                        r: exec vwap from t where sym=`AAPL;
                        .qu.compare[first r; (100*100f + 200*110f) % 300f]
            '''

        Args:
            quke_content  (str):           Full content of the .quke test file.
            setup_code    (str, optional): q source code loaded before tests run
                                           (equivalent to qcumber -src). Define
                                           functions and fixtures here.
            qcumber_path  (str, optional): Absolute path to qcumber.q_. Falls back
                                           to KDBX_DB_QCUMBER_PATH env var, then
                                           AXLIBRARIES_HOME/ws/qcumber.q_.
            timeout       (int):           Max seconds to wait for test run (default 60).

        Returns:
            Dict with keys:
              status   – "ok" or "error"
              summary  – e.g. "3/4 passed, 1 failed"
              passed   – count of passing tests
              failed   – count of failing tests
              total    – total test count
              tests    – list of per-test result objects
                           {feature, should, expect, passed, error, time_ms}
              stdout   – raw qCumber console output (if any)
        """
        return await q_unit_test_impl(
            quke_content=quke_content,
            setup_code=setup_code,
            qcumber_path=qcumber_path,
            timeout=timeout,
        )

    return ['kdbx_q_eval', 'kdbx_q_unit_test']
