# GitHub Copilot Instructions — KDB-X MCP Server

> These instructions apply to **all agents** working in this repository.
> They establish contextual knowledge, coding standards, testing requirements,
> and general functional-programming guidelines.

---

## 1. Project Context

This repository is a **Model Context Protocol (MCP) server** whose primary purpose
is to help **KDB/q developers work with AI copilot more effectively** in their
day-to-day KDB development — prototyping q functions, running unit tests, exploring
data, and iterating on analytics — all from within the AI conversation.

Bridging agents to a **KDB-X (kdb version 5.0)** database is the mechanism; the
end goal is accelerating the q developer's workflow. Not every q function needs a
Python MCP wrapper. The two primary AI-facing tools — `kdbx_q_eval` and
`kdbx_q_unit_test` — are often sufficient for the full development cycle.

| Layer | Technology |
|-------|-----------|
| MCP framework | `FastMCP` (Python, `mcp` package) |
| KDB-X client | `pykx` ≥ 4.0 |
| Settings | `pydantic-settings` with `AppSettings` |
| Package manager | `uv` |
| Python test runner | `pytest` + `pytest-asyncio` + `pytest-cov` |
| q/KDB test runner | `qcumber` (`.quke` DSL via `kdbx_q_unit_test` tool) |

### Key entry points

| Path | Purpose |
|------|---------|
| `src/mcp_server/server.py` | `McpServer` class — wires tools/prompts/resources |
| `src/mcp_server/tools/` | MCP tool implementations (one file per tool) |
| `src/mcp_server/resources/` | MCP resource implementations |
| `src/mcp_server/prompts/` | MCP prompt implementations |
| `src/mcp_server/utils/kdbx.py` | Shared KDB-X connection helper |
| `src/mcp_server/tools/kdbx_q_analytics.py` | `kdbx_q_eval` (interactive q) + `kdbx_q_unit_test` (qcumber runner) |
| `scripts/kdbx_init.q` | KDB-X startup script (loads `.ai`, `.s`, then auto-loads `q-modules/`) |
| `q-modules/` | Reusable q module library — one sub-directory per module |

### Tool usage priority

> **RULE**: Always prefer MCP tools over terminal commands when an MCP tool can
> accomplish the task. Terminal (shell) commands are perfectly acceptable when no
> suitable MCP tool exists for the job.

| Situation | Preferred approach |
|-----------|-------------------|
| Execute a q expression or query | `kdbx_q_eval` MCP tool |
| Run qcumber unit tests | `kdbx_q_unit_test` MCP tool |
| Run a SQL query against KDB-X | `kdbx_run_sql_query` MCP tool |
| Semantic / similarity search | `kdbx_similarity_search` / `kdbx_hybrid_search` MCP tools |
| No suitable MCP tool available | Terminal command is fine |

---

### KDB-X service management

> **RULE — HIGHEST PRIORITY**: If MCP tools (`kdbx_q_eval`, `kdbx_q_unit_test`, etc.) are available
> and responding, **NEVER start or stop a KDB-X instance under any circumstances**. Use the MCP tools
> directly. The MCP server manages its own KDB-X connection; agents must not interfere with it.
>
> Only use the start/stop scripts below when explicitly instructed by the user AND the MCP tools
> are confirmed unavailable.

> **RULE**: Agents must **never** attempt to start or stop the KDB-X service by
> constructing their own shell commands. Always use the provided scripts — they
> handle binary discovery, PID tracking, port conflict detection, logging, and
> graceful shutdown correctly.

| Task | Command |
|------|---------|
| Start KDB-X on a port | `./scripts/start_kdbx.sh <port>` — **only when MCP tools are unavailable AND user explicitly asks** |
| Stop KDB-X (by PID file + port) | `./scripts/stop_kdbx.sh <port>` — **only when MCP tools are unavailable AND user explicitly asks** |
| Check if KDB-X is listening | `lsof -iTCP:<port> -sTCP:LISTEN` |
| Tail the live log | `tail -f logs/kdbx_<timestamp>.log` |

**What each script does:**

- `start_kdbx.sh [port]` — locates the `q` binary (checks `~/.kx/bin`, `QHOME`,
  `Q_BINARY`, PATH in that order), checks the port is free, launches KDB-X with
  `scripts/kdbx_init.q`, writes the PID to `logs/kdbx.pid`, and streams output to
  a timestamped log file in `logs/`.
- `stop_kdbx.sh [port]` — reads `logs/kdbx.pid` and sends SIGTERM, waits up to
  5 s for a clean exit, sends SIGKILL if needed, then does a safety-net pass to
  kill any process still holding the port.

If either script is not behaving as expected (e.g. binary not found, port already
in use), **fix or update the script** rather than working around it with ad-hoc
shell commands.

## 2. KDB / q Language Reference

### 2.1 Primary reference — always consult first

When writing, reviewing, or debugging **any q/kdb code** — including inline strings
passed via `pykx` — refer to:

> **Q for Mortals 4.1**
> <https://code.kx.com/kdb-x/learn/q4m/index.html>

Use this resource to verify:
- Correct q syntax (function application, lambdas, projections)
- Data types and type casting (e.g. `1b`, `` `sym``, `` 2023.01.01``  )
- Built-in operators (`each`, `eachright`, `peach`, `over`, `scan`)
- Table operations (select/update/delete/exec, `aj`, `asof`, `lj`)
- List and dictionary manipulation

### 2.2 KDB-X 5.0 vs KDB+ 4.1 — compatibility boundary

> **CRITICAL**: The module framework and `use` keyword below are **KDB-X 5.0 only**.
> They are **not backward compatible** with KDB+ 4.x and earlier.

| Feature | KDB-X 5.0 | KDB+ ≤ 4.x |
|---------|-----------|------------|
| `use` keyword / module loading | ✅ | ❌ |
| `.ai.*` namespace | ✅ | ❌ |
| `.s.e` SQL interface | ✅ | ❌ (use `.s.sq`) |
| Standard q/Q namespaces | ✅ | ✅ |

When contributing code that runs on KDB-X, always document which version is required.

### 2.3 KDB-X module framework

For new KDB-X features, model code around the official module quickstart:

> <https://code.kx.com/kdb-x/modules/module-framework/quickstart.html>

**Module skeleton** (KDB-X 5.0):

```q
// Module: myorg.analytics
// Description: Example analytics module
// Version: 0.1.0

\d .myorg.analytics          / enter namespace

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/ @desc  Compute VWAP for a symbol over a date range
/ @param tbl   {symbol}  Table name (partitioned or in-memory)
/ @param sym   {symbol}  Instrument symbol
/ @param sd    {date}    Start date (inclusive)
/ @param ed    {date}    End date (inclusive)
/ @return      {table}   Single-row table with columns `sym`vwap`volume
calcVwap:{[tbl;sym;sd;ed]
    t: ?[tbl; ((within;`date;(sd;ed)); (=;`sym;sym)); 0b; `price`size!`price`size];
    `sym`vwap`volume!(sym; (sum t[`price]*t[`size])%sum t[`size]; sum t[`size])
    }

// ---------------------------------------------------------------------------
// Module registration (KDB-X 5.0 module framework)
// ---------------------------------------------------------------------------

\d .
.myorg.analytics.calcVwap:.myorg.analytics.calcVwap   / re-export from root
```

---

## 3. q / KDB Coding Guidelines

### 3.1 Naming conventions

| Concept | Convention | Example |
|---------|-----------|---------|
| Namespace | lowercase dotted prefix | `.myorg.tableName`, `.mcp.utils` |
| Public function | lowerCamelCase | `calcVwap`, `runSqlQuery` |
| Private/internal function | trailing underscore | `parseResult_`, `validateArgs_` (leading underscore is q's `drop` operator — do NOT use it as a name prefix) |
| Constants / config | UPPER_SNAKE inside namespace | `.cfg.MAX_ROWS` |
| Table names | lowerCamelCase | `tradeData`, `quoteSnap` |
| Column names | lowerCamelCase | `bidPrice`, `askSize` |

### 3.2 Functional programming principles in q

- **Prefer projections over thunks** — `{[x] f[x;constArg]}` → `f[;constArg]`
- **Avoid global mutation** — use local variables inside lambda scope
- **Prefer iterators over loops** — always reach for q's iterator adverbs before writing an imperative `while` or `do` construct:
  | Iterator | Adverb | Use case |
  |----------|--------|----------|
  | each | `'` | apply a function to every element of a list |
  | each-right / each-left | `/:` / `\:` | broadcast one argument across a list |
  | over (fold) | `/` | accumulate a result across a list (reduce) |
  | scan (prefix scan) | `\` | running accumulation — returns all intermediate results |
  | peach | `':` (with slaves) | parallel `each` for CPU-bound work |
  `while` and `do` are permitted only when the iteration count is genuinely data-dependent and cannot be expressed as a fold/scan.
- **Compose with `@`, `.`, `'`, `/`, `\`** rather than imperative loops where possible
- **Use each-right / each-left** (`/:`, `\:`) for broadcasting operations over lists
- **Keep lambdas small** — extract named sub-functions when a lambda exceeds ~10 lines
- **Add type annotations** in comments (`/ @param name {type} description`)

### 3.3 Error handling

```q
/ Wrap dangerous calls with protected evaluation
result: @[{.s.e x}; sqlString; {[err] `error!(enlist`msg)!(enlist err)}]
if[`error~first key result; '"SQL evaluation failed: ", result`msg]
```

### 3.4 Logging in q

Use the q file-descriptor handles for structured console output. Avoid bare
`show` in production code — it cannot be redirected or suppressed.

| Handle | Destination | Use for |
|--------|-------------|--------|
| `-1` | stdout | info messages, startup banners |
| `-2` | stderr | warnings and errors |

```q
/ Structured log helper (define once per namespace)
.log.info:  {-1 "[INFO]  ", string[.z.p], " ", x}  / timestamped info
.log.warn:  {-1 "[WARN]  ", string[.z.p], " ", x}
.log.error: {-2 "[ERROR] ", string[.z.p], " ", x}

/ Usage
.log.info  "calcVwap: processing ", string[count t], " rows"
.log.error "calcVwap: table not found — ", string tbl
```

- Log at **function entry** when inputs affect behaviour (e.g. row counts, symbol lists).
- Log at **function exit** with a result summary when the operation is expensive.
- **Never log passwords, credentials, or full table contents** in production.
- Wrap the log call in a protected eval if the logger itself could fail:
  ```q
  @[.log.info; "step complete"; {[e] -2 "logger error: ", e}]
  ```

### 3.5 Performance evaluation in q

Always profile before optimising. Use the built-in timing system commands:

| Command | Returns | Use for |
|---------|---------|--------|
| `\t expr` | milliseconds (long) | quick single timing |
| `\ts expr` | `(ms; bytes)` | time **and** heap allocation |
| `\ts:n expr` | `(ms; bytes)` averaged over *n* runs | stable micro-benchmarks |

```q
/ Single timing
\t select from tradeData where date=2024.01.01

/ Time + space
\ts select vwap:size wavg price by sym from tradeData

/ Averaged over 100 iterations
\ts:100 calcVwap[`tradeData;`AAPL;2024.01.01;2024.01.31]
```

**Optimisation checklist** (in order of impact):

1. **Partition pruning** — always filter on the partition column (`date`, `month`) first in `select` / `?[]`.
2. **Column selection** — project only needed columns before joining or aggregating.
3. **Attribute types** — apply `` `p# `` (parted) on the primary grouping column of a splayed table for O(log n) lookup; `` `g# `` for in-memory lookup tables; `` `s# `` for sorted binary search.
4. **`peach` for parallelism** — replace `each` with `peach` for CPU-bound per-partition work; ensure slaves are configured (``-s N`` flag).
5. **Avoid global assignment inside lambdas** — use function return values instead; global writes serialise across threads.
6. **Pre-allocate lists** when building results in a loop: `n#0N` rather than repeated `,:`.

```q
/ Example: partition-aware VWAP with peach
calcVwapByDate:{[tbl;sym;dates]
    f:{[d;tbl;sym]
        t:?[tbl; ((=;.Q.pf;d);(=;`sym;sym)); 0b; `price`size!`price`size];
        if[not count t; :()]; 
        enlist `date`sym`vwap`volume!(d; sym; (sum t[`price]*t[`size])%sum t[`size]; sum t[`size])
        };
    raze f[;tbl;sym] peach dates
    }
```

### 3.6 Documentation comment style

```q
/ @module  myorg.analytics
/ @desc    One-sentence description of what this function does.
/ @param   tbl    {symbol}  Partitioned table name as a symbol
/ @param   n      {long}    Maximum rows to return (default: 1000)
/ @return  {table}          Result table
/ @throws  if table does not exist or column is missing
/ @perf    O(log n) with `p# attribute on sym; ~2ms for 1M rows on M1
/ @example
/   .myorg.analytics.calcVwap[`trades;`AAPL;2024.01.01;2024.01.31]
myFunc:{[tbl;n] ... }
```

---

## 4. Python / MCP Server Coding Guidelines

### 4.1 Tool registration pattern

Every new tool **must** follow the existing file structure:

```
src/mcp_server/tools/
    kdbx_<feature_name>.py     ← one tool per file
```

```python
# src/mcp_server/tools/kdbx_my_feature.py
import logging
from typing import Dict, Any
from mcp_server.utils.kdbx import get_kdb_connection

logger = logging.getLogger(__name__)


async def my_feature_impl(param: str) -> Dict[str, Any]:
    """Core logic — separated from MCP registration for testability."""
    conn = get_kdb_connection()
    # ... implementation ...
    return {"status": "success", "data": result}


def register_tools(mcp_server):
    @mcp_server.tool()
    async def kdbx_my_feature(param: str) -> Dict[str, Any]:
        """
        One-sentence summary shown to the AI agent.

        Longer description: what it does, when to use it, and
        what the return structure looks like.

        Args:
            param: Description of the parameter.

        Returns:
            Dict with keys: status, data, [message], [error_type].
        """
        return await my_feature_impl(param)
```

Register the new tool in `src/mcp_server/tools/__init__.py` — follow the existing
`register_tools` aggregation pattern.

### 4.2 General Python principles

- **Pure functions by default** — functions that do not mutate external state
- **Single responsibility** — one function does one thing well
- **Immutability** — prefer `tuple` and frozen dataclasses over mutable state
- **Type annotations** on every function signature
- **Explicit over implicit** — avoid `*args/**kwargs` in public APIs
- **Error propagation** — raise typed exceptions; catch only at tool boundaries
- **Logging** — use `logger.info`, `logger.warning`, `logger.error` with structured messages; never `print()`
- **Log at boundaries** — log tool entry with key params (`logger.info(f"tool called: param={param!r}")`) and log exit with outcome; never log full payloads at INFO level
- **No magic strings** — use constants or enums for repeated literal values

### 4.3 Returning results from tools

All tools must return a `Dict[str, Any]` with the following contract:

```python
# Success
{"status": "success", "data": <payload>}
{"status": "success", "data": <payload>, "message": "Showing first N of M rows"}

# Error
{"status": "error", "message": "<human-readable>"}
{"status": "error", "error_type": "<machine-tag>", "message": "...", "technical_details": "..."}
```

---

## 5. Unit Testing Requirements

There are **two independent testing layers**. Use whichever applies — a Python
wrapper is **not required** for every piece of q logic.

| Layer | Tool | When to use |
|-------|------|-------------|
| q/KDB logic | **qcumber** (`.quke` DSL) | always — for any q function or module |
| Python tool layer | **pytest** + mocks | only when a new Python MCP tool is added |

---

### 5.1 q/KDB unit tests with qcumber

> **Reference**: <https://code.kx.com/developer/qcumber/>

qcumber is the standard KX unit-testing framework. Tests are authored in the
`.quke` DSL and executed through the `kdbx_q_unit_test` MCP tool
(see `src/mcp_server/tools/kdbx_q_analytics.py`), which invokes the
`qcumber.q_` binary from `ax-libraries`.

#### Development workflow

For **pure q development** (the common case):

```
1.  kdbx_q_eval       — prototype and iterate on q functions interactively
2.  kdbx_q_unit_test  — encode assertions in .quke blocks, run, fix, repeat
    → if the logic is reusable, commit it as a q-modules/<name>/<name>.q file
      with a matching <name>.quke test file (see §8 for layout rules).
    → done. The q module is auto-loaded at KDB-X startup; no Python layer needed.
```

Only add a Python MCP tool wrapper when you need to expose the functionality
as a **new named AI tool** with its own schema, documentation, and argument
validation visible to the AI agent:

```
3.  wrap in Python     — create kdbx_<name>.py, register in __init__.py
4.  pytest             — unit-test the Python wrapper with mocks
```

#### .quke file format

```q
feature <Feature description>

    [before]          / runs once before all shoulds
        <q setup code>

    [before each]     / runs before every should block
        <q setup code>

    should <behaviour description>
        expect <assertion label>
            <q expression — must return 1b to pass>

        expect <use .qu.compare for diff output on failure>
            .qu.compare[expected; actual]

    [after]           / teardown
        <q teardown code>
```

#### Worked example

```
/ Tool call: kdbx_q_unit_test
setup_code:
    "double:{x*2}; vwap:{select vwap:size wavg price by sym from x}"

quke_content:
    feature double function

        should multiply a scalar by two
            expect 5 * 2 = 10
                10 ~ double[5]

            expect 0 * 2 = 0
                0 ~ double[0]

            expect .qu.compare gives clear diff
                .qu.compare[10; double[5]]

    feature vwap function

        before
            trade :: ([]sym:`AAPL`GOOG`AAPL; price:100 200 110f; size:100 50 200)

        should return a keyed table grouped by sym
            expect result type is table
                98h = type vwap[trade]

            expect AAPL vwap is correct
                t: vwap[trade];
                r: exec vwap from t where sym=`AAPL;
                .qu.compare[first r; (100*100f + 200*110f) % 300f]
```

#### Minimum test coverage per q function

1. **Happy path** — expected inputs produce correct output
2. **Edge case** — empty table, single row, null values, boundary dates
3. **Error path** — missing column, wrong type, non-existent table

#### Assertions quick-reference

| Pattern | Purpose |
|---------|---------|
| `expected ~ actual` | exact match (type + value) |
| `.qu.compare[expected; actual]` | value diff on failure (preferred for tables) |
| `0 < count result` | non-empty result |
| `98h = type result` | result is a table |
| `not `error in key result` | no error key in dict result |

---

### 5.2 Python tool tests with pytest

For **every** new tool, resource, or prompt create a corresponding file:
`tests/tools/test_kdbx_<feature_name>.py`

Write at minimum:
- One **happy-path** test
- One **error / exception** test
- One **edge-case** test (empty result, boundary value, etc.)

Before committing, verify q code passed via `pykx` is syntactically correct
by running a live query. The script `scripts/test_mcp_query.sh` can be used
as a reference.

For tests that require a live KDB-X connection, use the `live_kdb` marker:

```python
# tests/conftest.py  (extend, don't replace)
import pytest
import pykx as kx

@pytest.fixture(scope="session")
def kdb_conn():
    """Live KDB-X connection — skipped when service is unavailable."""
    try:
        conn = kx.SyncQConnection(host="127.0.0.1", port=5001, timeout=2)
        yield conn
        conn.close()
    except Exception:
        pytest.skip("KDB-X service not available on port 5001")
```

```python
# tests/tools/test_kdbx_my_feature.py
import pytest
from unittest.mock import patch, MagicMock
from mcp_server.tools.kdbx_my_feature import my_feature_impl


# --- Unit tests (no live KDB required) ---

async def test_my_feature_success():
    mock_result = MagicMock()
    mock_result.__getitem__.side_effect = lambda k: {"rowCount": 2, "data": b'[{},{}]'}[k]
    with patch("mcp_server.tools.kdbx_my_feature.get_kdb_connection") as mock_conn:
        mock_conn.return_value.return_value = mock_result
        result = await my_feature_impl("valid_param")
    assert result["status"] == "success"


async def test_my_feature_kdb_error():
    with patch("mcp_server.tools.kdbx_my_feature.get_kdb_connection") as mock_conn:
        mock_conn.return_value.side_effect = Exception("connection refused")
        result = await my_feature_impl("any_param")
    assert result["status"] == "error"
    assert "message" in result


async def test_my_feature_empty_result():
    mock_result = MagicMock()
    mock_result.__getitem__.side_effect = lambda k: {"rowCount": 0, "data": b'[]'}[k]
    with patch("mcp_server.tools.kdbx_my_feature.get_kdb_connection") as mock_conn:
        mock_conn.return_value.return_value = mock_result
        result = await my_feature_impl("empty_param")
    assert result["status"] == "success"
    assert result["data"] == [] or "message" in result


# --- Integration tests (requires live KDB-X on port 5001) ---

@pytest.mark.live_kdb
async def test_my_feature_live(kdb_conn):
    result = await my_feature_impl("test_param")
    assert result["status"] == "success"
```

### 5.3 Running the test suite

```bash
# Pytest — unit tests only (no live KDB required)
uv run pytest tests/ -m "not live_kdb" -v

# Pytest — all tests (KDB-X must be running on port 5001)
uv run pytest tests/ -v

# Pytest — coverage report
uv run pytest tests/ --cov=mcp_server --cov-report=html

# qcumber — run a .quke file directly via the MCP tool (KDB-X must be running)
# Use the kdbx_q_unit_test MCP tool from your AI assistant, or the shell script:
bash scripts/test_q_analytics.sh
```

Register the `live_kdb` marker in `pyproject.toml` under `[tool.pytest.ini_options]`:

```toml
[tool.pytest.ini_options]
asyncio_mode = "auto"
markers = [
    "live_kdb: requires a running KDB-X service on port 5001 (deselect with '-m not live_kdb')",
]
```

---

## 6. Repository Structure Conventions

```
src/mcp_server/
    tools/          ← one file per MCP tool  (kdbx_*.py)
    resources/      ← one file per MCP resource
    prompts/        ← one file per MCP prompt
    utils/          ← shared helpers (kdbx.py, format_utils.py, …)
    settings.py     ← all config via pydantic-settings
    server.py       ← McpServer wiring only — no business logic
tests/
    tools/          ← mirrors src/mcp_server/tools/
    resources/
    prompts/
    utils/
    conftest.py     ← shared fixtures
scripts/
    kdbx_init.q     ← KDB-X startup (loads .ai, .s, then q-modules/)
    start_kdbx.sh   ← start KDB-X service (binary discovery, PID, logging)
    stop_kdbx.sh    ← stop KDB-X service (graceful SIGTERM → SIGKILL + port check)
q-modules/          ← reusable q module library (auto-loaded by kdbx_init.q)
    README.md       ← module library conventions
    <name>/         ← one sub-directory per module
        <name>.q    ← module implementation (namespace .<name>.*)
        <name>.quke ← qcumber unit tests (MANDATORY)
```

---

## 7. Extending These Instructions

See §10 for how gained KDB-X knowledge must be recorded in the **KDB Know-How** log.

Create a topic-specific instruction file alongside this one and update the table in §9 accordingly.

---

## 8. q-Module Library (`q-modules/`)

Reusable, self-contained q analytics are stored in `q-modules/`. Every module:

### 9.1 File layout

```
q-modules/<name>/
    <name>.q        ← implementation — namespace .<name>.*
    <name>.quke     ← qcumber unit tests  (MANDATORY — see §5.1)
    README.md       ← optional extended documentation
```

### 9.2 Required elements in every `.q` module file

| Element | Requirement |
|---------|------------|
| **File header block** | Multi-line comment with Module name, Namespace, Description, Version, Requires, Author |
| **Namespace declaration** | `\d .<modulename>` at top; `\d .` at bottom |
| **Internal log helpers** | `logI_`, `logW_`, `logE_` using fd -1/-2 with `[<module>]` prefix (trailing-underscore marks internal; leading underscore is invalid in q — it is the drop operator) |
| **Input guard helper** | `require_[cond; msg]` raising a descriptive error on violation |
| **Per-function `@` doc tags** | `/ @desc`, `/ @param name {type}`, `/ @return {type}`, `/ @throws`, `/ @example` |
| **Entry/exit logging** | `_logInfo` at function entry (key params) and exit (result summary) |
| **Load banner** | `-1 "[<module>] module loaded — namespace .<module>"`  at the bottom |

### 9.3 Logging rules for q modules

- Define `_logInfo`, `_logWarn`, `_logErr` **within the module namespace** using fd -1 (info/warn) and fd -2 (errors), prefixed with `[<modulename>][LEVEL]  <timestamp>` for grep-ability.
- Log at **function entry** with all parameters that affect behaviour.
- Log at **function exit** with a concise result summary (no full data dumps at INFO).
- Log **warnings** for degenerate-but-valid cases (e.g. zero stddev in Sharpe).
- Log **errors** via `_logErr` before signalling a signal (`'`) to preserve message context.
- Wrap `_logErr` calls in a protected eval when the logger itself could fail.

### 9.4 Unit test (`<name>.quke`) requirements

Every function in the module **must** have qcumber tests covering:

1. **Happy path** — expected inputs produce the correct output value.
2. **Edge case** — empty list, single-element list, boundary values (n=1 window, alpha=1, etc.).
3. **Error path** — invalid/mismatched inputs raise a signal (verified with `@[fn; args; {1b}]`).

The `.quke` file **must** begin with a `before` or `before each` block that:
- Guards against loading the module twice (`if[not ... in key `.; system "l ..."]`).
- Uses the module path relative to the project root.

See `q-modules/finstat/finstat.quke` as a reference implementation.

### 9.5 Auto-loading at startup

`scripts/kdbx_init.q` scans `q-modules/` at KDB-X startup and `system "l"`-loads
every file matching `q-modules/<name>/<name>.q`. Set `KDBX_SKIP_Q_MODULES=1`
to disable (bare/testing sessions).

### 9.6 Available modules

See `q-modules/README.md` for the current module catalogue.

---

Create a topic-specific instruction file alongside this one and link to it here:

| Use-case document | Purpose |
|-------------------|---------|
| _(add when needed)_ | e.g. `.github/instructions/embeddings.instructions.md` |
| _(add when needed)_ | e.g. `.github/instructions/sql-tools.instructions.md` |
---

## 8.7 Agent Skills

Three agent skills are available in `.github/skills/`. Each is loaded **on demand** when the matching use case arises.

| Skill | Folder | Trigger / Use Case |
|-------|--------|-------------------|
| **KDB Business Analyst** | `.github/skills/kdb-business-analyst/` | Gathering business requirements; writing BDD specifications; creating or reviewing JIRA tickets for trade P&L, client profile, or trading behaviour features. **Never infers — always asks.** |
| **KDB Developer** | `.github/skills/kdb-developer/` | Implementing q modules; testing q syntax via `kdbx_q_eval`; writing qcumber test suites from BDD specs in a separate session. |
| **KDB Doc & Review** | `.github/skills/kdb-doc-review/` | Reviewing documentation completeness; auditing knowledge drift across BDD spec / module / quke tests / README; expert KDB code review; drafting Confluence pages. |
| **MD → PPTX** | `.github/skills/md-to-pptx/` | Converting Markdown files into corporate PowerPoint decks (client pitches, internal training, project showcases) using the First Derivative visual language. |
| **MD → DOCX** | `.github/skills/md-to-docx/` | Converting Markdown files into corporate Word documents: Client Proposal, Client Overview, Internal Guide, Whitepaper, or Blog — each with its own tone, structure, and FD brand styling. |

### Skill Workflow (summary)

```
Business Analyst skill
  └─ Elicits requirements → writes BDD spec + JIRA ticket
        │
        ▼
     KDB Developer skill
       ├─ Phase 1–4: implements module using kdbx_q_eval (tests every expression live)
       └─ Phase 5:   NEW session → writes .quke tests from BDD spec only
              │
              ▼
           KDB Doc & Review skill
             ├─ Documentation completeness audit
             ├─ Knowledge drift check (BDD ↔ module ↔ quke ↔ README)
             ├─ Expert code review (naming, idioms, performance, logging)
             └─ Confluence page draft
```
Topic files should use VS Code's
[scoped instructions](https://code.visualstudio.com/docs/copilot/copilot-customization#_instruction-files)
(`applyTo` glob) to activate only for relevant files.

---

## 9. Quick Reference Card

| Need | Action |
|------|--------|
| Interact with KDB-X | Use an MCP tool (`kdbx_q_eval`, `kdbx_run_sql_query`, etc.) — prefer over terminal |
| No MCP tool for the job | Terminal command is acceptable |
| q syntax question | Check <https://code.kx.com/kdb-x/learn/q4m/index.html> first |
| New KDB-X module | Follow <https://code.kx.com/kdb-x/modules/module-framework/quickstart.html> |
| New reusable q module | Create `q-modules/<name>/<name>.q` + `<name>.quke`; see §8 |
| Available q modules | See `q-modules/README.md` for the full catalogue |
| Gather business requirements / write BDD | Use the `kdb-business-analyst` skill |
| JIRA memory file (handover record) | BA skill auto-creates `.memory/jira/<TICKET-ID>.md`; see template at `.memory/template/JIRA-TEMPLATE.md` |
| Implement a new q module | Use the `kdb-developer` skill |
| Review docs / code quality / knowledge drift | Use the `kdb-doc-review` skill |
| Convert Markdown to corporate PPTX | Use the `md-to-pptx` skill |
| Convert Markdown to corporate DOCX | Use the `md-to-docx` skill |
| qcumber test reference | <https://code.kx.com/developer/qcumber/> |
| New MCP tool | Create `src/mcp_server/tools/kdbx_<name>.py`, register in `__init__.py` |
| Prototype q logic | Call `kdbx_q_eval` tool interactively |
| Test q logic | Call `kdbx_q_unit_test` tool with `.quke` content |
| New pytest file | Mirror path under `tests/`, add `live_kdb` marker for integration tests |
| Profile q code | Use `\t`, `\ts`, `\ts:n` commands inside `kdbx_q_eval` |
| **Start KDB-X** | **NEVER start KDB-X if MCP tools are available.** Only use `./scripts/start_kdbx.sh <port>` when MCP tools are unavailable AND user explicitly requests it |
| **Stop KDB-X** | **NEVER stop KDB-X if MCP tools are available.** Only use `./scripts/stop_kdbx.sh <port>` when MCP tools are unavailable AND user explicitly requests it |
| Check KDB-X is up | `lsof -iTCP:<port> -sTCP:LISTEN` |
| Run MCP server locally | `uv run mcp-server --db.port <port>` |
| Run Python unit tests | `uv run pytest tests/ -m "not live_kdb" -v` |
| Run q integration tests | `bash scripts/test_q_analytics.sh` |
| Run Python unit tests | `uv run pytest tests/ -m "not live_kdb" -v` |
| Run q integration tests | `bash scripts/test_q_analytics.sh` |
| Record new KDB-X insight | Append entry to `.github/kdb-knowhow.md` (see §10) |

---

## 10. KDB Know-How Knowledge Base

> **RULE — mandatory for every agent session**: Whenever you discover, confirm, or
> derive a non-obvious fact about KDB-X, q language behaviour, MCP tool interaction,
> or problem-solving logic during a session, you **must** append it to
> `.github/kdb-knowhow.md` before ending your turn.
>
> This file is the persistent institutional memory of the project. It grows
> continuously and must never be truncated or overwritten — only appended to.
>
> At the **start** of any non-trivial KDB-X task, scan `.github/kdb-knowhow.md`
> for relevant prior knowledge before forming a plan.

### 10.1 When to append

| Trigger | Example |
|---------|---------|
| Unexpected KDB-X behaviour confirmed via `kdbx_q_eval` | ARM64 `.so` must be copied from `lib/ubuntu16_arm64/` for qcumber to load |
| A q idiom that solved a real problem in this repo | Using `@[fn; args; {1b}]` to assert error paths in `.quke` |
| A debugging approach that turned out to be correct | Checking `lsof` before starting KDB-X to detect port conflicts |
| A gotcha or API limitation discovered through MCP | `pykx` result indexing differs from standard dict access |
| A logical deduction that guided a multi-step solution | Why `KDBX_SKIP_Q_MODULES=1` is needed for bare test sessions |
| Any fix applied to a recurring or subtle error | How to resolve `'attr` errors when attribute index is missing |

### 10.2 Entry format

Each entry in `.github/kdb-knowhow.md` must follow this template:

```
### <YYYY-MM-DD> — <Short title (one line)>

**Category**: <one of: q-language | kdb-x-behaviour | mcp-tooling | debugging | performance | module-dev | testing>

**Context**: One sentence describing what task or problem surfaced this insight.

**Insight**:
<The knowledge itself — be precise. Include q code snippets or MCP tool
examples where they make the explanation concrete.>

**Why it matters**:
<One or two sentences on why another developer or agent would want to know this.>

---
```

### 10.3 Principles for good entries

- **Be specific** — vague notes like "KDB-X is finicky" add no value.
- **Include reproducible evidence** — a q snippet, MCP call, or log excerpt wherever applicable.
- **Link to the source** — reference the file, module, or conversation context.
- **Don't duplicate** — scan existing entries first; if knowledge already exists,
  amend the existing entry rather than creating a new one.
- **Reason explicitly** — capture logical deductions, not just outcomes. If you worked
  through multiple hypotheses before finding the answer, briefly describe that reasoning
  chain so the next agent can short-circuit it.

### 10.4 File location and access

| Item | Value |
|------|-------|
| Path | `.github/kdb-knowhow.md` |
| Format | Markdown, append-only |
| Maintained by | All AI agents and human contributors |
| Read at session start? | Yes — scan before starting any non-trivial KDB-X task |
