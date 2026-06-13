# volflow — Intraday Volume Flow Signals

**Namespace**: `.volflow`  
**File**: `q-modules/volflow/volflow.q`  
**Tests**: `q-modules/volflow/volflow.quke`  
**Jira**: GED-1123  
**Version**: 0.1.0

## Purpose

`volflow` computes six complementary market microstructure signals over 30-minute
intraday buckets to detect the presence of informed or institutional equity market
participants. It is designed for **retail algo traders** who need volume flow
intelligence to position ahead of directional momentum.

The module operates in two modes:

| Mode | Function | Use Case |
|------|----------|----------|
| **Streaming/CEP** | `.volflow.onUpdate` | Real-time: accumulate incremental trade/quote deltas per symbol; returns latest bucket signal row after each call |
| **T+1 Batch** | `.volflow.calcDay` | Historical: replay a full HDB day partition and return complete daily signal table |

Output is a **17-column flat table** of primitive q types — directly compatible
with Python/HTML charting libraries and downstream ML pipelines.

## Six Signals

| # | Raw Column | Score Column | Interpretation |
|---|-----------|-------------|----------------|
| 1 | `ofi` — Order Flow Imbalance (buy vol − sell vol) | `ofiScore` | 0.5 = balanced; >0.5 = buy pressure |
| 2 | `vpin` — VPIN estimate (toxic flow proxy) | `vpinScore` | higher = more informed/toxic flow |
| 3 | `flowConc` — fraction of vol from block trades ≥ `blockSizeThresh` | `flowConcScore` | higher = more institutional-scale activity |
| 4 | `poc` — Point of Control price (highest-vol price level) | `pocScore` | <0.5 = price below POC (bullish); >0.5 = above (bearish) |
| 5 | `aggrRatio` — aggressive buy trade fraction | `aggrRatioScore` | >0.5 = aggressor buying dominates |
| 6 | `volImbal` — (buyVol − sellVol) / totalVol | `volImbalScore` | >0.5 = buy side dominates |

`compositeScore` = weighted mean of the six scores (default: equal weight 1/6).  
`signal` = +1h (bullish), 0h (neutral), -1h (bearish) based on threshold comparison.

> **Note on raw vs score**: For signals 2 (VPIN), 3 (flowConc), and 5 (aggrRatio),
> the raw value is already in [0f,1f] by construction, so the raw and score columns
> carry the same value. This keeps the schema symmetric across all six signals.

## Output Schema

| Column | q Type | Description |
|--------|--------|-------------|
| `date` | date | Trading date |
| `sym` | symbol | Instrument symbol |
| `bucket` | time | Start of 30-min window (e.g. `09:30:00.000t`) |
| `ofi` | float | Raw OFI (signed) |
| `ofiScore` | float | Normalised OFI [0f,1f] |
| `vpin` | float | VPIN estimate [0f,1f] |
| `vpinScore` | float | Normalised VPIN [0f,1f] |
| `flowConc` | float | Block trade fraction [0f,1f] |
| `flowConcScore` | float | Normalised flow concentration [0f,1f] |
| `poc` | float | POC price level |
| `pocScore` | float | POC proximity score [0f,1f] |
| `aggrRatio` | float | Aggressive buy fraction [0f,1f] |
| `aggrRatioScore` | float | Normalised aggressor score [0f,1f] |
| `volImbal` | float | Volume imbalance in [-1f,1f] |
| `volImbalScore` | float | Normalised vol imbalance [0f,1f] |
| `compositeScore` | float | Weighted mean of all *Score columns [0f,1f] |
| `signal` | short | +1h (bullish), 0h (neutral), -1h (bearish) |

## Public API

### `.volflow.onUpdate[sym; date; time; tradeDelta; orderDelta; quoteDelta]`

Streaming/CEP mode. Accumulates incremental delta tables for `sym` and returns
the 17-column signal row for the current (or just-completed) 30-min bucket.

```q
/ Setup (once, before the trading session)
.volflow.resetAll[]

/ Tick batch at 09:35 — first call seeds accumulator for AAPL at 09:30 bucket
r: .volflow.onUpdate[`AAPL; 2026.05.10; 09:35:00.000t;
    ([] time:09:30:01.000 09:31:01.000t; price:100.5 101.0f;
        size:500 1000j; side:`B`S);
    ();
    ([] sym:`AAPL`AAPL; time:09:30:00.500 09:31:00.500t;
        bid:99.5 100.0f; ask:100.5 101.0f; bsize:200 200j; asize:200 200j)]

/ r is a 1-row table: bucket=09:30:00.000t, all 6 signals computed
```

Bucket boundary behaviour: when `time` crosses into the next 30-min window,
the completed bucket row is returned and a fresh accumulator is started.

### `.volflow.calcDay[sym; date]`

T+1 batch mode. Queries `trade` and `quote` HDB tables and returns one row per
traded 30-min bucket, sorted ascending by `bucket`.

```q
/ Compute all signals for AAPL on 2026-05-09
r: .volflow.calcDay[`AAPL; 2026.05.09]
/ r is a flat table with one row per bucket that had at least one trade
```

### `.volflow.getState[sym]`

Return the current in-memory accumulator for a symbol (read-only).

```q
.volflow.getState[`AAPL]
/ Returns `date`bucket`trades`quotes!(...) or ()!() if no state exists
```

### `.volflow.resetState[sym]`

Clear the streaming accumulator for a specific symbol.

```q
.volflow.resetState[`AAPL]   / AAPL is no longer in .volflow.state_
```

### `.volflow.resetAll[]`

Clear all per-symbol streaming accumulators. **Call at the start of each new
trading session** to prevent stale state from prior days.

```q
.volflow.resetAll[]
```

### `.volflow.cfg.reset[]`

Restore all configuration variables to their documented defaults.

```q
.volflow.cfg.bullThresh: 0.75f   / override
.volflow.cfg.reset[]             / restore to 0.6f
```

## Configuration

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `.volflow.cfg.bullThresh` | float | `0.6f` | compositeScore threshold for +1h (bullish) |
| `.volflow.cfg.bearThresh` | float | `0.4f` | compositeScore threshold for -1h (bearish) |
| `.volflow.cfg.bucketMins` | int | `30` | Bucket width in minutes |
| `.volflow.cfg.blockSizeThresh` | long | `10000` | Min shares for a "block trade" (Signal 3) |
| `.volflow.cfg.quoteJoinTol` | timespan | `0D00:00:01t` | Max look-back for asof quote join |
| `.volflow.cfg.vpinBuckets` | int | `50` | Sub-buckets for VPIN estimation |
| `.volflow.cfg.weights` | dict (sym→float) | equal 1f/6f | Per-signal weights for composite score |

All variables can be overridden at runtime without modifying source code:

```q
/ Give OFI double the weight of each other signal
.volflow.cfg.weights: `ofiScore`vpinScore`flowConcScore`pocScore`aggrRatioScore`volImbalScore!
    0.333 0.133 0.133 0.133 0.133 0.133f
```

## HDB Dependencies

| Table | Columns Used | Mode |
|-------|-------------|------|
| `trade` | `date`, `sym`, `time`, `price`, `size`, `side` | T+1 batch only |
| `quote` | `sym`, `date`, `time`, `bid`, `ask`, `bsize`, `asize` | T+1 batch only |
| `instrument` | `sym`, `assetClass` | Both modes |

- `side` values must be `` `B `` / `` `S `` (buy / sell).
- `instrument.assetClass` must equal `` `equity `` for the symbol to be accepted.

## Known Limitations

| Limitation | Detail |
|-----------|--------|
| Equities only | Asset class filter enforced via `instrument` table |
| No corporate action adjustment | POC price levels not adjusted for splits/dividends |
| Partial-null composite | If ANY of the 6 scores is null (e.g. no quote data for aggrRatio), compositeScore is null and signal=0h — conservative design |
| Bucket boundary on `time` parameter | The `time` parameter to `onUpdate` determines the bucket; late ticks are merged into the current accumulator regardless of their individual timestamps |
| No HDB write-back | Results are in-memory only |
| `orderDelta` reserved | The `orderDelta` parameter is accepted but not used in v0.1 signal computation |

## Performance Notes

- Target latency: < 10ms per `.volflow.onUpdate` call (single symbol, typical intraday batch)
- T+1 batch: `date` filter applied first for partition pruning before any join
- Quote asof join (`aj`) is pre-filtered on `sym` and `date` before calling; still O(n log n) on quote table size
- For large universes of symbols, call `.volflow.resetAll[]` at session open to avoid state accumulation from prior days

## Changelog

| Version | Date | Author | Change |
|---------|------|--------|--------|
| 0.1.0 | 2026-05-11 | kdb-x-mcp-server | Initial implementation (GED-1123): 6 signals, streaming + T+1 batch modes |
