# momentum — Momentum Indicators Module

Namespace: `.momentum`  
Version: 0.1.0  
Requires: KDB/q 4.x (compatible with KDB-X 5.0)

---

## 📖 Quick Links

- **[Business User Guide (USAGE.md)](./USAGE.md)** — MCP tool examples with worked input/output for traders and analysts
- **[Unit Tests (momentum.quke)](./momentum.quke)** — qcumber test suite with comprehensive coverage
- **[Source Code (momentum.q)](./momentum.q)** — Implementation reference

---

## Overview

The momentum module provides three key momentum indicators commonly used in
technical analysis and quantitative trading strategies. All functions are:

- **Functional** — no `for`/`while` loops; uses vector operations
- **Dynamic** — parameterized lookback periods
- **qSQL-ready** — designed to work seamlessly in `select`/`update` queries with `by` clauses

## Functions

### `.momentum.mom` — Simple Momentum

**Signature**: `mom:{[prices;n]}`

Computes the difference between the current price and the price `n` periods ago.  
This is the most fundamental momentum measure.

**Parameters**:
- `prices` — float list of ordered prices (oldest first)
- `n` — lookback period (integer ≥ 1)

**Returns**: float list (first `n` values are null)

**Formula**: `price[t] - price[t-n]`

**Interpretation**:
- Positive values → upward momentum
- Negative values → downward momentum
- Zero → no momentum change

**Example**:
```q
q) .momentum.mom[100 102 101 105 103f; 2]
0n 0n 1 3 2f
/ At t=2: 101 - 100 = 1
/ At t=3: 105 - 102 = 3
/ At t=4: 103 - 101 = 2
```

**qSQL usage**:
```q
q) trades:([]sym:`AAPL`AAPL`AAPL`AAPL; time:10:00+til 4; price:100 102 101 105f)
q) select time, price, mom2:.momentum.mom[price;2] from trades
time  price mom2
-------------------
10:00 100   
10:01 102   
10:02 101   1
10:03 105   3
```

---

### `.momentum.roc` — Rate of Change

**Signature**: `roc:{[prices;n]}`

Computes the percentage change in price over `n` periods.  
Expresses momentum as a percentage for easy comparison across different price levels.

**Parameters**:
- `prices` — float list of ordered prices (oldest first)
- `n` — lookback period (integer ≥ 1)

**Returns**: float list of percentage changes (first `n` values are null)

**Formula**: `((price[t] - price[t-n]) / price[t-n]) × 100`

**Interpretation**:
- `5.0` → 5% increase over n periods
- `-5.0` → 5% decrease over n periods
- Handles zero prices gracefully (returns null)

**Example**:
```q
q) .momentum.roc[100 110 105 115.5f; 2]
0n 0n 5 5f
/ At t=2: ((105-100)/100)*100 = 5.0%
/ At t=3: ((115.5-110)/110)*100 = 5.0%
```

**qSQL usage**:
```q
q) update roc5:.momentum.roc[price;5] by sym from trades
```

---

### `.momentum.mosc` — Momentum Oscillator

**Signature**: `mosc:{[prices;n]}`

Computes how far the current price deviates from its simple moving average,  
expressed as a percentage. Combines trend (SMA) and momentum in one indicator.

**Parameters**:
- `prices` — float list of ordered prices (oldest first)
- `n` — SMA window size (integer ≥ 1)

**Returns**: float list of percentage deviations (first `n-1` values are null)

**Formula**: `((price[t] - SMA[n][t]) / SMA[n][t]) × 100`

**Interpretation**:
- Positive values → price is above its moving average (bullish momentum)
- Negative values → price is below its moving average (bearish momentum)
- Large absolute values → strong momentum divergence from trend

**Example**:
```q
q) .momentum.mosc[100 102 104 106 108f; 3]
0n 0n 1.960784 1.923077 1.886792f
/ At t=2: SMA[3]=102, ((104-102)/102)*100 = 1.96%
/ At t=3: SMA[3]=104, ((106-104)/104)*100 = 1.92%
```

**qSQL usage**:
```q
q) select sym, time, price, mosc10:.momentum.mosc[price;10] by sym from trades
```

---

## Performance Characteristics

| Function | Time complexity | Space complexity | Loops |
|----------|----------------|------------------|-------|
| `mom` | O(n) | O(n) | None — vector subtraction |
| `roc` | O(n) | O(n) | None — vector operations |
| `mosc` | O(n) | O(n) | None — uses `mavg` + vector ops |

All functions are safe for large datasets and leverage q's native vector optimizations.

---

## Working with Missing Data

All functions handle null/missing prices gracefully:

```q
q) .momentum.mom[100 0N 105 110f; 2]
0n 0n 0n 0n
/ Propagates nulls through the calculation

q) .momentum.roc[100 0 110f; 1]
0n 0n 0n
/ Zero prices produce null ROC (division by zero)
```

In production, consider filling or interpolating missing prices before applying
momentum indicators if the data gaps are not intentional.

---

## Common Patterns

### Multi-period momentum analysis

```q
q) trades:([]time:10:00+til 20; price:100+sums 20?5f)
q) update mom1:.momentum.mom[price;1],
         mom5:.momentum.mom[price;5],
         mom10:.momentum.mom[price;10]
    from trades
```

### Momentum signals in backtesting

```q
/ Buy signal: 5-period ROC crosses above +2%
q) update signal:roc5>2 from 
    update roc5:.momentum.roc[price;5] by sym from trades

/ Sell signal: price falls below 20-period SMA (mosc < 0)
q) update exit:mosc20<0 from
    update mosc20:.momentum.mosc[price;20] by sym from trades
```

### Combining with other indicators

```q
q) \l q-modules/finstat/finstat.q
q) \l q-modules/momentum/momentum.q

q) select sym, time, price,
         sma20:.finstat.sma[price;20],
         mom10:.momentum.mom[price;10],
         roc5:.momentum.roc[price;5]
    by sym from trades
```

---

## MCP Tool Usage (Business Users)

For **worked examples with MCP tools** (`kdbx_q_eval`, `kdbx_q_unit_test`) showing how to use these functions interactively with real input/output, see:

**👉 [USAGE.md — Business User Guide](./USAGE.md)**

The usage guide includes:
- Step-by-step MCP tool calls with JSON responses
- Real-world trading scenarios (momentum scans, trend detection, mean reversion)
- Multi-symbol analysis examples
- Best practices for period selection and error handling

---

## Testing

Unit tests are in `momentum.quke`. Run via:

```bash
# Using the MCP tool wrapper
bash scripts/test_q_analytics.sh

# Or directly via kdbx_q_unit_test tool
```

Coverage includes:
- ✅ Happy path calculations for each function
- ✅ Edge cases (single element, n=1, n=count prices)
- ✅ Error handling (empty list, n<1)
- ✅ Integration with qSQL queries (by-clauses, grouped data)

---

## References

- **Simple Momentum**: Classic price difference indicator
- **Rate of Change (ROC)**: First introduced by Welles Wilder, used widely in mean-reversion strategies
- **Momentum Oscillator**: Variation of price/SMA deviation, useful for overbought/oversold detection

For production use, consider combining momentum indicators with:
- `.finstat.rollingVol` (volatility-adjusted momentum)
- `.finstat.ema` (exponential smoothing to reduce noise)
- Volume confirmation (VWAP, volume-weighted momentum)
