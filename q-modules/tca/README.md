# tca — T+1 TCA Module

*Namespace: `.tca` | Version: 0.1.0 | Last Updated: 2026-04-22 | JIRA: [GEP-1123](../../../.memory/jira/GEP-1123.md)*

---

## Purpose

The `tca` module computes **T+1 Transaction Cost Analysis (TCA)** metrics at the
equity parent order level, enabling traders and quant analysts to evaluate execution
quality and identify delays in the PM-to-execution order lifecycle.

Three metrics are computed per equity parent order:

| Metric | Definition |
|--------|-----------|
| `fillRate` | Proportion of the parent order qty filled across all child order slices (0.0–1.0) |
| `traderHoldTimeSecs` | Elapsed seconds from PM order creation (`parentOrderTime`) to the first child order slice |
| `execHoldTimeSecs` | Elapsed seconds from the first child order slice to the **last** fill in the trade table |

---

## Platform Context

Queries three HDB tables:

| Table | Role |
|-------|------|
| `order` | Parent and child order rows (same table). Parent rows have `orderId = parentOrderId`; child rows differ. |
| `trade` | Fill records keyed by `orderId` (child order IDs). |
| `instrument` | Reference table; `assetClass` column used to restrict output to equity instruments only. |

Run via the T+1 daily batch job after all three tables have been ingested for the reporting date.

---

## Public API

| Function | Parameters | Returns | Description |
|----------|-----------|---------|-------------|
| `.tca.calcDaily` | `d {date}` | `{table}` | Compute TCA metrics for all equity parent orders on date `d`. Reads live HDB tables. |

### Internal helpers (not for direct use)

| Symbol | Description |
|--------|-------------|
| `.tca.calcWith_` | Core computation accepting mock table arguments — used by `calcDaily` and qcumber tests. |
| `.tca.require_` | Input guard; logs an error and raises a descriptive signal on precondition violation. |
| `.tca.logI_` / `.tca.logW_` / `.tca.logE_` | Structured log helpers (INFO on stdout, WARN on stdout, ERROR on stderr). |

---

## Data Flow

```
Input: order {HDB table}, trade {HDB table}, instrument {ref table}, d {date}
         │
         ▼
  .tca.calcDaily[d]
         │
         ├─ equity symbol list  ←  instrument where assetClass=`equity
         │
         ├─ parent orders       ←  order where date=d, orderId=parentOrderId, sym in eqSyms
         │
         ├─ child aggregates    ←  order where date=d, orderId<>parentOrderId
         │                         → sum fillQty (totFill), min time (firstCTime) per parentOrderId
         │
         ├─ fill aggregates     ←  trade where date=d
         │                         → max fill time (lastFTime) per parentOrderId
         │
         └─ metric computation  ←  fillRate, traderHoldTimeSecs, execHoldTimeSecs
                  │
                  ▼
Output: {table} — one row per equity parent order
  date  sym  parentOrderId  fillRate  traderHoldTimeSecs  execHoldTimeSecs
```

---

## Usage Examples

### Single-date batch call

```q
/ Loaded automatically at KDB-X startup. To load manually during development:
system "l q-modules/tca/tca.q"

/ Compute TCA for 2026-04-18
result: .tca.calcDaily[2026.04.18]

/ Expected output (illustrative):
/ date       sym   parentOrderId fillRate traderHoldTimeSecs execHoldTimeSecs
/ --------------------------------------------------------------------------
/ 2026.04.18 MSFT  PO001         1f       300f               165f
/ 2026.04.18 AAPL  PO002         0.4f     120f               300f
```

### Multi-date iteration

```q
/ Single-threaded iteration over a week of dates:
dates: 2026.04.14 + til 5
results: raze .tca.calcDaily each dates

/ Parallel — requires KDB-X started with -s N slaves:
results: raze .tca.calcDaily peach dates
```

### Direct use of calcWith_ (testing / prototyping)

```q
/ Build mock tables, bypass live HDB dependency:
oTbl: ([] date:2#2026.04.18; sym:2#`MSFT; orderId:`PO001`CO001;
         parentOrderId:`PO001`PO001; time:2026.04.18D09:00:00.000000000 2026.04.18D09:05:00.000000000;
         qty:1000 1000; fillQty:0N 1000; status:`open`filled);
tTbl: ([] date:1#2026.04.18; sym:1#`MSFT; orderId:1#`CO001;
         time:1#2026.04.18D09:07:00.000000000; size:1#1000);
iTbl: ([] sym:1#`MSFT; assetClass:1#`equity);

.tca.calcWith_[oTbl; tTbl; iTbl; 2026.04.18]
```

---

## Result Schema

| Column | Type | Notes |
|--------|------|-------|
| `date` | date (-14h) | Reporting date |
| `sym` | symbol (-11h) | Equity instrument symbol |
| `parentOrderId` | symbol (-11h) | Parent order identifier |
| `fillRate` | float (9h) | Fill proportion [0.0–1.0]; `0n` when total child `fillQty` = 0 or no child orders |
| `traderHoldTimeSecs` | float (9h) | Seconds from PM order creation to first child slice; `0n` if `parentOrderTime` is null or no children |
| `execHoldTimeSecs` | float (9h) | Seconds from first child slice to last fill; `0n` if no fills in trade table |

---

## Known Limitations

- **Live HDB dependency**: `.tca.calcDaily` reads `order`, `trade`, and `instrument` from the global namespace. If any table is absent, q will signal `'<tablename>`. Always run after T+1 batch ingestion.
- **Equity only**: Non-equity instruments are excluded via `instrument.assetClass`. The column must be present.
- **Single-date function**: `.tca.calcDaily` processes one date per call. Use `each` / `peach` for date ranges.
- **Multi-column `by` constraint**: A KDB-X 5.0 build-specific constraint requires single-column `by` in grouped aggregations. The workaround groups by `parentOrderId` and adds the `date` column post-join.
- **Corporate actions**: Fill prices and quantities are not adjusted for corporate actions.
- **No persistence**: This function computes and returns results; persistence to `tcaAnalytics` HDB is a separate future concern (see GEP-1123 open questions).

---

## Changelog

| Version | Date | Author | Change |
|---------|------|--------|--------|
| 0.1.0 | 2026-04-20 | kdb-developer | Initial implementation — GEP-1123 |
| 0.1.1 | 2026-04-22 | kdb-doc-review | Added logW_ for empty equity-syms and zero-pOrders; second @throws tag; README created |
