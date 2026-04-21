# Expert KDB Code Review Checklist

Reference for the `kdb-doc-review` skill — Step 4.

Each section maps to a quality dimension. Rate as **PASS**, **NEEDS WORK**, or **FAIL** then list specific findings.

---

## 1. Documentation Accuracy

**Standard**: All `@` doc tags must accurately describe the *actual* implementation — not an idealised or outdated version.

| Check | Pass Criterion |
|-------|---------------|
| `@desc` matches actual behaviour | Description is accurate to the current code, not aspirational |
| `@param` types are correct | KDB type name matches what the code actually expects (e.g. `{symbol}` not `{string}`) |
| `@param` names match function signature | Parameter names in tags match the lambda `[paramName]` exactly |
| `@return` describes actual shape | Return type and structure (table, dict, scalar, list) is accurate |
| `@throws` lists real error conditions | Signals actually raised by `require_` or `'` are listed |
| `@example` executes correctly | Paste the example into `kdbx_q_eval` — it must run without error |

**Red flags**:
- `@param` says `{table}` but code accepts a symbol and queries the HDB internally
- `@return {dict}` but function returns a table in the happy path
- `@example` references a symbol that doesn't exist in the live HDB

---

## 2. Verbose Coding (Naming & Intermediate Variables)

**Standard**: KDB code is terse by nature; the counterbalance is intentional verbosity through naming and structure.

| Check | Pass Criterion |
|-------|---------------|
| Variable names are descriptive | `filteredTrades` not `t2`; `dailyVwap` not `r` |
| Intermediate results are named | Complex expressions are broken into named steps, not chained into one long line |
| Function names express intent | `calcRealisedPnl` not `f1`; `filterActiveTrades_` not `g` |
| Parameter names are meaningful | `startDate` not `sd` in public API; abbreviations acceptable in short private helpers |
| Magic literals are named | `.cfg.MAX_ROWS:1000` not `1000` hardcoded into logic |

**Red flags**:
```q
/ BAD — what does r mean? what is t2?
r:{[t] t2:select from t where 0<size; (sum t2`price * t2`size) % sum t2`size}

/ GOOD — intent is clear at each step
calcVwap:{[trades]
    activeTrades: select from trades where 0 < size;
    weightedSum:  sum activeTrades[`price] * activeTrades[`size];
    totalVolume:  sum activeTrades`size;
    weightedSum % totalVolume
    }
```

---

## 3. q Idiom Usage — Iterators, Projections, Overloads

**Standard**: q has powerful functional programming primitives. Avoid imperative loops when an idiomatic iterator exists.

| Check | Pass Criterion |
|-------|---------------|
| `each` / `'` used instead of explicit loops | Single-argument iteration uses `f each list` or `f '` |
| `over` / `/` used for accumulation | Running reductions use `/` not `while` |
| `scan` / `\` used for running results | Prefix scans use `\` not a growing list in a loop |
| Projections used over thunks | `f[;constArg]` used where `{[x] f[x;constArg]}` appears |
| `each-right` / `each-left` used for broadcasting | `f[list1;] each list2` or `list1 f/: list2` |
| `while`/`do` loops justified | If present, must have a comment explaining why an iterator was insufficient |

**Overloads — good use**:
```q
/ Accept either a symbol or a list of symbols
myFunc:{[syms]
    syms: $[10h = type syms; enlist syms; syms];  / normalize atom → list
    select from trade where sym in syms
    }
```

**Red flags**:
```q
/ BAD — imperative loop where each would work:
i:0; result:(); while[i < count syms; result,:calcOne[syms i]; i+:1]

/ GOOD:
result: calcOne each syms
```

---

## 4. Error Handling

**Standard**: Errors at system boundaries must be caught with protected eval; internal preconditions must be guarded with `require_`; error messages must be actionable.

| Check | Pass Criterion |
|-------|---------------|
| `require_` used for precondition violations | All input validation uses the module's `require_` helper |
| Error messages are descriptive | `'"[module] sym must be a symbol, got: "` not `'"type error"` |
| Protected eval at HDB boundaries | `@[select from...; (); {...}]` pattern used where table may not exist |
| Error path logged via `logE_` before signalling | `logE_` called before `'"..."` to preserve context |
| No silent swallowing of errors | `@[fn; args; {[e] 1b}]` only in tests; never in production code without surfacing e |

**Red flags**:
```q
/ BAD — silent catch:
result: @[dangerousFn; args; {`}]

/ BAD — uninformative error:
if[not 11h = type sym; '"type"]

/ GOOD:
require_[11h = type sym; "sym must be a symbol, got type ", string type sym]
```

---

## 5. Performance Considerations

**Standard**: HDB queries on large partitioned datasets require disciplined query construction. Every non-trivial function must demonstrate awareness of partition pruning and attribute usage.

| Check | Pass Criterion |
|-------|---------------|
| Partition column (`date`) filtered first | Every select/`?[]` on a partitioned table has `date` as the first where clause |
| Column projection before joins | Only required columns selected before any `aj`, `lj`, or join |
| Attribute annotations present/justified | `p#`/`g#`/`s#` on known sorted/parted columns; or a comment explaining why N/A |
| `\ts` timing evidence for expensive functions | At least one `\ts` comment showing measured latency with a representative dataset size |
| `peach` considered for per-date parallelism | If iterating over many dates, `peach` used or explicitly not used with justification |
| No repeated full-partition scans | Aggregations done once, results cached in a local variable if reused |

**Red flags**:
```q
/ BAD — no date filter → full HDB scan:
select from trade where sym=`AAPL

/ BAD — join before projection → large intermediate table:
aj[`sym`time; trade; quote]

/ GOOD:
t: select date, sym, price, size from trade where date within (sd;ed), sym=s;
q: select date, sym, time, bid, ask from quote where date within (sd;ed), sym=s;
aj[`sym`time; t; q]
```

---

## 6. Logging Discipline

**Standard**: Logs must be useful for debugging in production without creating noise or security risk.

| Check | Pass Criterion |
|-------|---------------|
| `logI_` at function entry with key params | First statement logs function name + controlling inputs (symbol, date range, etc.) |
| `logI_` at function exit with summary | Last statement before return logs result summary (row count, not full data) |
| `logW_` for degenerate-but-valid cases | Zero-size result, boundary condition logged as WARN |
| `logE_` before every `'"..."` signal | Error logged before signalling so the message is preserved in `-2` stream |
| No full table dumps at INFO | `count result` not `result` logged; never `show` in production code |
| No credentials or sensitive values logged | Position sizes, client IDs should be aggregated or omitted in log messages |

**Red flags**:
```q
/ BAD — logs full table (could be millions of rows):
logI_ "result: ", .Q.s result

/ BAD — no exit log — can't trace what the function returned:
myFunction:{[sym] select from trade where sym=sym}

/ GOOD:
myFunction:{[sym]
    logI_ "myFunction: entry | sym=", string sym;
    result: select from trade where date within (.z.d-1; .z.d), sym=sym;
    logI_ "myFunction: exit  | rows=", string count result;
    result
    }
```
