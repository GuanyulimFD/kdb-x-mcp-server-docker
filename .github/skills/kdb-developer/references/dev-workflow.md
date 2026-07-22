# KDB Developer — Workflow & quke Patterns Reference

## Development Checklist

Use this checklist for every new module before marking it ready for code review.

### Pre-Development
- [ ] `.github/kdb-knowhow.md` scanned for relevant entries (q-language, kdb-x-behaviour, module-dev)
- [ ] BDD specification read and acceptance criteria mapped to function responsibilities
- [ ] `q-modules/README.md` reviewed — existing modules identified or "none applicable" confirmed
- [ ] Module template reviewed: `q-modules/<name>/<name>.q` does not yet exist (or planned extension is understood)

### Per-Function Development (repeat for each public function)
- [ ] Core expression tested in isolation via `kdbx_q_eval`
- [ ] Full function definition tested via `kdbx_q_eval`
- [ ] Edge case (empty input, single row, boundary values) tested via `kdbx_q_eval`
- [ ] HDB integration tested against at least one real date partition
- [ ] Code transcribed to `.q` file ONLY after all three checks pass
- [ ] `kdbx_q_lint mode="file"` run after transcription — `clean: true` required before moving to next function

### Module Assembly
- [ ] File header block present (Module, Namespace, Description, Version, Requires, Author)
- [ ] `\d .<modulename>` at top; `\d .` at bottom
- [ ] `logI_`, `logW_`, `logE_` defined with `[<module>]` prefix and timestamp
- [ ] `require_` input guard defined
- [ ] Every public function has complete `@` doc tags (`@desc`, `@param`, `@return`, `@throws`, `@example`)
- [ ] Entry log at start of every function (key params), exit log at end (result summary)
- [ ] Load banner as last line before `\d .`

### Final Module Verification
- [ ] `system "l q-modules/<name>/<name>.q"` succeeds via `kdbx_q_eval`
- [ ] `key `.<name>` returns all expected function names
- [ ] Each public function runs correctly with representative inputs
- [ ] Error guard `require_` triggers on known bad input
- [ ] Module auto-loaded at KDB-X restart (or tested with `kdbx_q_eval` `\l` command)
- [ ] `kdbx_q_lint mode="file"` on assembled module returns `clean: true` — **blocks sign-off if violations remain**

### Test Suite (new session)
- [ ] NEW conversation started — module source code not loaded into context
- [ ] BDD specification pasted as the only implementation reference
- [ ] Each BDD `Scenario:` has at least one corresponding `.quke` `should` block
- [ ] Happy path covered for each public function
- [ ] Edge case covered for each public function
- [ ] Error path covered: `@[fn; badArgs; {1b}]` pattern used
- [ ] All scenarios pass via `kdbx_q_unit_test`
- [ ] Test file saved as `q-modules/<name>/<name>.quke`

### Sign-off
- [ ] Any non-obvious KDB-X insights recorded in `.github/kdb-knowhow.md`
- [ ] Module entry added to `q-modules/README.md` available modules table

---

## Linting with kdbx_q_lint

Run `kdbx_q_lint` at two points: after each function is transcribed (item/file mode) and as a hard gate before sign-off (file mode on the full module).

### Lint a single function body (during Phase 1)
```
kdbx_q_lint mode="item" code_or_path="<paste function body here>"
```
Useful when iterating on a tricky function — catches unused params and variable issues before writing to disk.

### Lint the full module file (Phase 2 → Phase 3 gate)
```
kdbx_q_lint mode="file" code_or_path="q-modules/<name>/<name>.q"
```
Expected clean result:
```json
{ "status": "ok", "clean": true, "violation_count": 0, "violations": [] }
```

### Lint the entire module directory
```
kdbx_q_lint mode="folder" code_or_path="q-modules/<name>"
```
Useful when a module has multiple `.q` files and you want a single pass before opening a PR.

### Common violations and fixes

| Violation | Cause | Fix |
|-----------|-------|-----|
| `UNUSED_PARAM` | Parameter declared but never referenced in body | Remove it or use it; use `_` convention if intentionally ignored |
| `UNUSED_VAR` | Local variable assigned but never used | Remove the assignment or use the value |
| `SHADOW_GLOBAL` | Local name shadows a global | Rename the local |

A `violation_count > 0` result is treated as a failing test — do not proceed to Phase 4 or code review.

---

## quke Pattern Reference

### Basic should block
```q
feature <feature description>

    should <expected behaviour>
        expect <assertion label>
            <q expression returning 1b>
```

### Before block (module loading guard — mandatory)
```q
feature <feature>

    before
        / Guard: only load module if not already in session
        if[not `.<modulename> in key `.; system "l q-modules/<name>/<name>.q"]
```

### Exact match assertion
```q
        expect result equals expected value
            expectedValue ~ actualCall[args]
```

### Diff assertion (preferred for tables — shows diff on failure)
```q
        expect .qu.compare gives clear diff on mismatch
            .qu.compare[expectedTable; actualCall[args]]
```

### Non-empty result
```q
        expect result is not empty
            0 < count actualCall[args]
```

### Table type assertion
```q
        expect result is a table (type 98h)
            98h = type actualCall[args]
```

### Error path — function raises signal on bad input
```q
        expect invalid args raises a signal
            @[.<modulename>.myFunction; (::); {1b}]
```

### Edge case — empty input
```q
    should handle empty input gracefully
        expect empty table in returns empty table out
            t: ([]sym:`symbol$(); price:`float$(); size:`long$())
            0 = count .<modulename>.myFunction[t]
```

### Worked .quke example — based on VWAP BDD spec
```q
feature Daily VWAP calculation for a single symbol

    before
        if[not `.finstat in key `.; system "l q-modules/finstat/finstat.q"]
        trade :: ([]
            sym:   `AAPL`AAPL`AAPL`GOOG`GOOG;
            price: 100 102 101 200 205f;
            size:  100 200 150 300 100)

    should return one row per symbol with correct VWAP
        expect result is a table
            98h = type .finstat.vwap[trade]

        expect AAPL VWAP is correct (size-weighted)
            t: .finstat.vwap[trade];
            expected: (100*100f + 102*200f + 101*150f) % 450f;
            actual: first exec vwap from t where sym=`AAPL;
            .qu.compare[expected; actual]

    should return empty table for empty input
        expect 0 rows returned
            empty: ([]sym:`symbol$(); price:`float$(); size:`long$());
            0 = count .finstat.vwap[empty]

    should raise error on missing price column
        expect signal raised
            bad: ([]sym:`AAPL; size:100);
            @[.finstat.vwap; bad; {1b}]
```

---

## Common q Gotchas (from kdb-knowhow.md)

### exec inside function body → `'from` error
```q
/ WRONG — parse error at load time:
not jname in exec .cron.jobs`name

/ CORRECT — direct column index:
not jname in .cron.jobs`name
```

### string x,y in comma expression → right-to-left parse
```q
/ WRONG — string applied to (jname , " suffix"):
"prefix=", string jname, " suffix"

/ CORRECT — bracket notation forces monadic:
"prefix=", string[jname], " suffix"
```

### Trailing vs leading underscore
```q
/ CORRECT — trailing underscore marks private:
parseResult_:{...}

/ WRONG — leading underscore is the q `drop` operator, NOT a prefix:
_parseResult:{...}   / this is not what you think
```
