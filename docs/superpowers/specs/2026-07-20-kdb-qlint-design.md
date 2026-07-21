# kdb-qlint MCP Tool — Design Spec

**Date:** 2026-07-20  
**Status:** Approved  
**Scope:** Add `kdbx_q_lint` MCP tool to the kdb-x-mcp-server

---

## Overview

Extend the existing MCP server with a static linting tool backed by the KX Developer Linter Library (`qlint.q_`). Linting is the first gate in the SDLC loop — before `kdbx_q_eval` and before `kdbx_q_unit_test`. The tool surfaces syntax errors, formatting issues, and scoping anomalies (e.g. `UNUSED_PARAM`, `UNDECLARED_VAR`, `ASSIGN_RESERVED_WORD`) as structured violations without executing any code.

---

## Architecture

The new tool is registered in `src/mcp_server/tools/kdbx_q_analytics.py` as a third peer to `kdbx_q_eval` and `kdbx_q_unit_test`. No new files are created.

**New additions to `kdbx_q_analytics.py`:**

- `_find_qlint()` — path discovery helper, mirrors `_find_qcumber()`, targets `analyst/ws/qlint.q_` inside the KX Developer install.
- `_ensure_qlint_loaded(conn)` — idempotent loader: checks if `.qlint` namespace is present in the connected q session; if not, runs `\cd <analyst_ws_dir>` then `\l qlint.q_`. The `\cd` is required so `qlint.q_`'s relative internal deps (`.qlint.*.q_`) resolve correctly. This is a one-time side effect per q session.
- `q_lint_impl(mode, code_or_path, timeout)` — core implementation function.
- `kdbx_q_lint` tool registration in `register_tools()`.

**Settings (`src/mcp_server/settings.py`):**

A new `qlint_path: str` field is added to `KDBConfig` (env: `KDBX_DB_QLINT_PATH`, default `""`). When set, `_find_qlint()` uses it directly; otherwise falls back to the same glob patterns as `_find_qcumber()` but targeting `qlint.q_`.

---

## Tool Interface

```
kdbx_q_lint(mode, code_or_path, timeout=30)
```

| Parameter | Type | Description |
|---|---|---|
| `mode` | `"item"` \| `"file"` \| `"folder"` | Selects `.qlint.lintItem`, `.qlint.lintFile`, or `.qlint.lintFolder` |
| `code_or_path` | `str` | Inline q code string for `item`; filesystem path for `file`/`folder` |
| `timeout` | `int` | Seconds before qlint call is considered hung (default 30) |

**Path note for `file`/`folder` modes:** Paths are resolved on the KDB-X server's filesystem. The `q-modules/` directory is already mounted and accessible — paths pointing into it work without extra configuration.

---

## Data Flow

1. `_ensure_qlint_loaded(conn)` checks `.qlint` namespace presence via `@[{key .qlint; 1b}; (::); {0b}]`. Loads once if absent.
2. Dispatch using pykx parameterised calls (avoids string interpolation / injection):
   - `item` → `conn("{.j.j .qlint.lintItem[x; ::]}", code.encode())`
   - `file` → `conn("{.j.j .qlint.lintFile[x]}", path.encode())`
   - `folder` → `conn("{.j.j .qlint.lintFolder[x]}", path.encode())`
3. Parse JSON string returned by `.j.j` into a Python list of dicts.
4. Return structured response.

**Output schema:**

```json
{
  "status": "ok",
  "clean": true,
  "violation_count": 0,
  "violations": [
    {
      "label": "myFunc",
      "errorClass": "UNUSED_PARAM",
      "description": "Parameter x is never used",
      "problemText": "myFunc:{[x;y] y*2}",
      "errorMessage": "x declared but not referenced",
      "startLine": 3,
      "startCol": 0,
      "endLine": 3,
      "endCol": 18
    }
  ]
}
```

All 9 linter table fields are preserved. `clean` is `true` when `violation_count == 0`.

---

## Error Handling

| Condition | Behaviour |
|---|---|
| `qlint.q_` not found | `status: error` with install hint message (mirrors `_QCUMBER_DOWNLOAD_MSG`) |
| No live KDB-X connection | `status: error` propagated from pykx exception, same as `kdbx_q_eval` |
| `\cd` or `\l qlint.q_` fails | `status: error` with q error string |
| `lintFile`/`lintFolder` path not found on server | `status: error` surfaced from q error |
| Timeout | `status: error`, message: `"qlint timed out after {timeout}s"` |

---

## Testing

Unit tests added to `tests/tools/test_kdbx_q_analytics_logging.py` (or a new peer file `tests/tools/test_kdbx_q_lint.py`). All tests mock `get_kdb_connection` — no live KDB-X required.

Test cases:
- `lintItem` clean code → `clean: true`, `violation_count: 0`
- `lintItem` code with violation → `clean: false`, violation list populated with all 9 fields
- `lintFile` happy path → same structure
- `lintFolder` happy path → violations from multiple files aggregated
- `qlint.q_` not found → `status: error` with install hint
- pykx exception → `status: error` propagated
- `_ensure_qlint_loaded` called once across multiple calls (idempotency check via mock call count)

---

## Out of Scope

- `lintNS` (in-memory namespace scanning) — not included in this iteration.
- Pre-flight linting integration inside `kdbx_q_eval` — linting remains a standalone tool; the AI agent decides when to call it.
- Custom rule tables — qlint is called with `::` (default rules) only.
