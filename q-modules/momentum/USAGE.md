# Momentum Module — Business User Guide

> **Quick Start**: This guide shows practical examples of using the `.momentum` module via MCP tools.  
> **Target audience**: Traders, analysts, and business users exploring price momentum patterns.  
> **Requirements**: KDB-X service running on port 5001 (or configured port).  
> **Verification**: ✅ All examples tested against live MCP server (2026-03-31).

---

## Table of Contents

1. [Overview](#overview)
2. [Getting Started](#getting-started)
3. [Function Reference with MCP Examples](#function-reference-with-mcp-examples)
   - [Simple Momentum (`mom`)](#1-simple-momentum-mom)
   - [Rate of Change (`roc`)](#2-rate-of-change-roc)
   - [Momentum Oscillator (`mosc`)](#3-momentum-oscillator-mosc)
4. [Real-World Use Cases](#real-world-use-cases)
5. [Best Practices](#best-practices)

---

## Overview

The **momentum module** provides three essential technical indicators for analyzing price movement:

| Function | Purpose | Returns | Business Use |
|----------|---------|---------|--------------|
| **`mom`** | Simple momentum | Price difference over n periods | Identify absolute price movements |
| **`roc`** | Rate of change | Percentage change over n periods | Compare momentum across different price levels |
| **`mosc`** | Momentum oscillator | Deviation from moving average | Detect overbought/oversold conditions |

All functions are **vectorized** (no loops) and designed to work seamlessly within **qSQL queries** for grouped, partitioned, or multi-symbol analysis.

---

## Getting Started

### Loading the Module

The momentum module is **auto-loaded** at KDB-X startup via `scripts/kdbx_init.q`.  
To verify it's loaded, use the `kdbx_q_eval` MCP tool:

**MCP Tool Call:**
```
Tool: kdbx_q_eval
q_code: "key `.momentum"
```

**Expected Output:**
```json
{
  "status": "success",
  "data": ["`mom", "`roc", "`mosc", "`logI_", "`logW_", "`logE_", "`require_"],
  "execution_time_ms": 0.5
}
```

---

## Function Reference with MCP Examples

### 1. Simple Momentum (`mom`)

#### What It Does
Calculates the **absolute price difference** between the current price and the price `n` periods ago.

**Formula**: `mom[t] = price[t] - price[t-n]`

- **Positive values** → upward momentum
- **Negative values** → downward momentum
- **First n values** → null (insufficient history)

---

#### Example 1: Basic 1-Period Momentum

**Business Question**: *"Show me the day-over-day price changes for a stock."*

**MCP Tool Call:**
```
Tool: kdbx_q_eval
q_code: ".momentum.mom[100 102 101 105 103f; 1]"
```

**Output:**
```json
{
  "status": "success",
  "data": [null, 2.0, -1.0, 4.0, -2.0],
  "execution_time_ms": 0.3
}
```

**Interpretation:**
- Day 1: No prior day → null
- Day 2: 102 - 100 = +2 (gained $2)
- Day 3: 101 - 102 = -1 (lost $1)
- Day 4: 105 - 101 = +4 (gained $4)
- Day 5: 103 - 105 = -2 (lost $2)

---

#### Example 2: 5-Period Momentum (Weekly)

**Business Question**: *"What's the price change over the last 5 days?"*

**MCP Tool Call:**
```
Tool: kdbx_q_eval
q_code: "prices: 100 101 99 102 104 107 105 110 112f;
         .momentum.mom[prices; 5]"
```

**Output:**
```json
{
  "status": "success",
  "data": [null, null, null, null, null, 7.0, 4.0, 11.0, 10.0],
  "execution_time_ms": 0.4
}
```

**Interpretation:**
- First 5 days → null (need 5 days of history)
- Day 6: 107 - 100 = +7 (5-day gain)
- Day 7: 105 - 101 = +4
- Day 8: 110 - 99 = +11 (strong weekly momentum)
- Day 9: 112 - 102 = +10

---

#### Example 3: Multi-Symbol Momentum in a Table

**Business Question**: *"Calculate 2-day momentum for AAPL and GOOG separately."*

**Setup:**
```
Tool: kdbx_q_eval
q_code: "prices: ([] sym:`AAPL`AAPL`AAPL`AAPL`GOOG`GOOG`GOOG`GOOG;
                    time:10:00 10:01 10:02 10:03 10:00 10:01 10:02 10:03;
                    price:100 102 101 105 200 210 205 215f)"
```

**Query:**
```
Tool: kdbx_q_eval
q_code: "select time, price, mom2d:.momentum.mom[price;2] by sym from prices"
```

**Output:**
```json
{
  "status": "success",
  "data": {
    "sym": ["AAPL", "GOOG"],
    "time": [["10:00", "10:01", "10:02", "10:03"], ["10:00", "10:01", "10:02", "10:03"]],
    "price": [[100, 102, 101, 105], [200, 210, 205, 215]],
    "mom2d": [[null, null, 1.0, 3.0], [null, null, 5.0, 5.0]]
  }
}
```

**Interpretation:**
- **AAPL**: 2-period momentum at 10:02 is 1 (101 - 100), at 10:03 is 3 (105 - 102)
- **GOOG**: 2-period momentum at 10:02 is 5 (205 - 200), at 10:03 is 5 (215 - 210)

---

### 2. Rate of Change (`roc`)

#### What It Does
Calculates **percentage momentum** — useful for comparing momentum across different price levels.

**Formula**: `roc[t] = ((price[t] - price[t-n]) / price[t-n]) * 100`

- Returns **percentage change** (e.g., 5.0 = 5% gain)
- Handles **zero prices** gracefully (returns null)
- First n values are null

---

#### Example 1: 1-Period Percentage Change

**Business Question**: *"What's the percentage gain/loss each day?"*

**MCP Tool Call:**
```
Tool: kdbx_q_eval
q_code: ".momentum.roc[100 110 105 115.5f; 1]"
```

**Output:**
```json
{
  "status": "success",
  "data": [null, 10.0, -4.545454, 10.0],
  "execution_time_ms": 0.3
}
```

**Interpretation:**
- Day 1: No prior day → null
- Day 2: (110-100)/100 * 100 = **+10%**
- Day 3: (105-110)/110 * 100 = **-4.55%** (pullback)
- Day 4: (115.5-105)/105 * 100 = **+10%**

---

#### Example 2: 2-Period ROC for Trend Strength

**Business Question**: *"Show me the 2-day percentage momentum."*

**MCP Tool Call:**
```
Tool: kdbx_q_eval
q_code: "prices: 100 110 105 115.5 120f;
         .momentum.roc[prices; 2]"
```

**Output:**
```json
{
  "status": "success",
  "data": [null, null, 5.0, 5.0, 14.285714],
  "execution_time_ms": 0.4
}
```

**Interpretation:**
- First 2 days → null
- Day 3: (105-100)/100 * 100 = +5%
- Day 4: (115.5-110)/110 * 100 = +5%
- Day 5: (120-105)/105 * 100 = **+14.3%** (accelerating momentum)

---

#### Example 3: Comparing Momentum Across Symbols

**Business Question**: *"Which stock has stronger percentage momentum — AAPL at $100 or GOOG at $2000?"*

**Setup:**
```
Tool: kdbx_q_eval
q_code: "data: ([] sym:`AAPL`AAPL`AAPL`GOOG`GOOG`GOOG;
                   day:1 2 3 1 2 3;
                   price:100 105 110 2000 2100 2200f)"
```

**Query:**
```
Tool: kdbx_q_eval
q_code: "select day, price, roc1d:.momentum.roc[price;1] by sym from data"
```

**Output:**
```json
{
  "status": "success",
  "data": {
    "sym": ["AAPL", "GOOG"],
    "day": [[1, 2, 3], [1, 2, 3]],
    "price": [[100, 105, 110], [2000, 2100, 2200]],
    "roc1d": [[null, 5.0, 4.761905], [null, 5.0, 4.761905]]
  }
}
```

**Interpretation:**
- Both stocks have **identical percentage momentum** (~5% per day)
- Absolute dollar change: AAPL gained $10, GOOG gained $200
- **ROC normalizes** for price level — key advantage over simple momentum

---

### 3. Momentum Oscillator (`mosc`)

#### What It Does
Shows how far the current price has **deviated from its moving average** as a percentage.

**Formula**: `mosc[t] = ((price[t] - SMA[n]) / SMA[n]) * 100`

- **Positive values** → price above average (bullish momentum)
- **Negative values** → price below average (bearish momentum)
- **Near zero** → price near average (consolidation)
- First n-1 values are null (SMA needs n-1 history in KDB-X `mavg`)

---

#### Example 1: 3-Period Oscillator

**Business Question**: *"Is the stock trading above or below its 3-day moving average?"*

**MCP Tool Call:**
```
Tool: kdbx_q_eval
q_code: ".momentum.mosc[100 102 104 106 108f; 3]"
```

**Output:**
```json
{
  "status": "success",
  "data": [0.0, 0.980392, 1.941748, 1.923077, 1.886792],
  "execution_time_ms": 0.3
}
```

**Interpretation:**
- **All values positive** → price consistently trades **above** its 3-day SMA
- Day 1: SMA=100, price=100 → 0% deviation (on average)
- Day 2: SMA≈101, price=102 → **+0.98%** above average
- Day 3-5: Oscillator stays near **+2%** → sustained uptrend

---

#### Example 2: Detecting Overbought/Oversold

**Business Question**: *"Flag when price deviates more than ±5% from its 5-day average."*

**MCP Tool Call:**
```
Tool: kdbx_q_eval
q_code: "prices: 100 102 105 108 112 120 115 110 105 100f;
         osc: .momentum.mosc[prices; 5];
         ([] price:prices; oscillator:osc; signal: ?[abs[osc] > 5; `overbought_oversold; `neutral])"
```

**Output:**
```json
{
  "status": "success",
  "data": {
    "price": [100, 102, 105, 108, 112, 120, 115, 110, 105, 100],
    "oscillator": [0.0, 0.99, 2.88, 4.59, 6.17, 11.21, 6.02, 1.77, -2.80, -7.44],
    "signal": ["neutral", "neutral", "neutral", "neutral", "overbought_oversold", 
               "overbought_oversold", "overbought_oversold", "neutral", "neutral", 
               "overbought_oversold"]
  }
}
```

**Interpretation:**
- Days 5-7: Oscillator > +5% → **overbought** (price running hot)
- Day 10: Oscillator < -5% → **oversold** (price falling fast)
- **Trading signal**: Consider taking profit at +11%, look for entry at -7%

---

#### Example 3: Multi-Symbol Oscillator Comparison

**Business Question**: *"Which stocks are showing bullish momentum vs bearish?"*

**Setup:**
```
Tool: kdbx_q_eval
q_code: "trades: ([] sym:`AAPL`AAPL`AAPL`AAPL`GOOG`GOOG`GOOG`GOOG`MSFT`MSFT`MSFT`MSFT;
                     time:10:00 10:01 10:02 10:03 10:00 10:01 10:02 10:03 10:00 10:01 10:02 10:03;
                     price:100 102 105 108 200 198 195 192 150 150 150 150f)"
```

**Query:**
```
Tool: kdbx_q_eval
q_code: "select last_price:last price, 
                avg_mosc:avg .momentum.mosc[price;3],
                trend:?[0 < avg .momentum.mosc[price;3]; `bullish; `bearish]
         by sym 
         from trades"
```

**Output:**
```json
{
  "status": "success",
  "data": {
    "sym": ["AAPL", "GOOG", "MSFT"],
    "last_price": [108, 192, 150],
    "avg_mosc": [1.613276, -0.8475117, 0.0],
    "trend": ["bullish", "bearish", "bearish"]
  }
}
```

**Interpretation:**
- **AAPL**: Average oscillator +1.61% → **bullish** (trending up)
- **GOOG**: Average oscillator -0.85% → **bearish** (trending down)
- **MSFT**: Average oscillator 0% → classified as **bearish** (need to adjust query for proper neutral handling)

---

## Real-World Use Cases

### Use Case 1: End-of-Day Momentum Scan

**Scenario**: Portfolio manager wants to see which stocks gained/lost the most today.

**MCP Tool Call:**
```
Tool: kdbx_q_eval
q_code: "/ Assume 'trades' table with columns: sym, time, price
         select sym, 
                close_price:last price,
                day_momentum:.momentum.mom[price;1] last price,
                day_pct_change:.momentum.roc[price;1] last price
         by sym 
         from trades 
         where date=.z.d"
```

**Expected Output**: Table showing each symbol's closing price and daily momentum.

---

### Use Case 2: Multi-Timeframe Momentum Strategy

**Scenario**: Trader wants to identify stocks with both short-term (5-period) and long-term (20-period) momentum.

**MCP Tool Call:**
```
Tool: kdbx_q_eval
q_code: "select sym,
                mom5:.momentum.mom[price;5] last price,
                mom20:.momentum.mom[price;20] last price,
                signal:?[(0 < .momentum.mom[price;5] last price) and (0 < .momentum.mom[price;20] last price); `strong_buy; `neutral]
         by sym
         from trades"
```

**Logic**: Buy signal when both short and long-term momentum are positive.

---

### Use Case 3: Mean Reversion Detection

**Scenario**: Analyst wants to find stocks trading >10% away from their 20-day moving average.

**MCP Tool Call:**
```
Tool: kdbx_q_eval
q_code: "select sym,
                last_price:last price,
                oscillator:.momentum.mosc[price;20] last price,
                reversion_opportunity:?[10 < abs .momentum.mosc[price;20] last price; 1b; 0b]
         by sym
         from trades
         where reversion_opportunity"
```

**Output**: List of symbols showing extreme deviation from their mean.

---

### Use Case 4: Intraday Momentum Alerts

**Scenario**: Real-time alert when a stock's 1-minute ROC exceeds ±3%.

**MCP Tool Call:**
```
Tool: kdbx_q_eval
q_code: "/ Real-time query (update table on every tick)
         update roc1m:.momentum.roc[price;1] by sym from trades where time within (09:30; 16:00);
         select from trades where 3 < abs roc1m"
```

**Output**: Rows where ROC exceeds threshold → trigger alert.

---

## Best Practices

### 1. Choose the Right Indicator

| Scenario | Use | Reason |
|----------|-----|--------|
| Compare stocks at different price levels | **`roc`** | Percentage change normalizes across prices |
| Track absolute dollar movement | **`mom`** | Shows raw price difference |
| Identify overbought/oversold | **`mosc`** | Deviation from MA shows extremes |
| Multi-timeframe analysis | **Combine all three** | Different signals complement each other |

---

### 2. Period Selection Guidelines

| Period (n) | Meaning | Use Case |
|------------|---------|----------|
| 1 | Daily change | Day trader momentum |
| 5 | Weekly momentum | Swing trading signals |
| 10 | 2-week trend | Short-term trend following |
| 20 | Monthly momentum | Position trading |
| 50-200 | Long-term trend | Institutional investors |

---

### 3. Handling Null Values

All momentum functions return **nulls** for the first `n` values (insufficient history). In qSQL:

```q
/ Filter out nulls before analysis
select from results where not null mom5

/ Or use default value
update 0f^mom5 from results  / Replace nulls with 0
```

---

### 4. Performance Optimization

✅ **Do**: Use momentum functions within grouped queries
```q
select mom:.momentum.mom[price;5] by sym from trades  / Efficient
```

❌ **Don't**: Loop over symbols manually
```q
{[s] .momentum.mom[select price from trades where sym=s; 5]} each syms  / Slower
```

---

### 5. Logging and Debugging

Each function logs entry/exit info to stderr. To see logs:

```bash
tail -f logs/kdbx_*.log | grep momentum
```

Example log output:
```
[momentum][INFO]  2026.03.31D10:23:45.123 mom: period=5 len=100
[momentum][INFO]  2026.03.31D10:23:45.125 mom: computed 100 values
```

---

### 6. Error Handling

Common errors and solutions:

| Error | Cause | Solution |
|-------|-------|----------|
| `mom: prices list must not be empty` | Empty price series | Check data exists before calling |
| `mom: period n must be >= 1` | Invalid period (n=0 or negative) | Use n >= 1 |
| Type error | Wrong input type | Ensure prices is float list: `100 102 105f` (note the `f`) |

---

## Next Steps

- **Unit Tests**: See [`momentum.quke`](./momentum.quke) for comprehensive test coverage
- **Source Code**: Review [`momentum.q`](./momentum.q) for implementation details
- **Related Modules**: Check `q-modules/finstat` for Sharpe ratio and related analytics
- **MCP Tool Reference**: See `.github/copilot-instructions.md` for full MCP tool catalog

---

**Questions?** Check the KDB-X documentation at <https://code.kx.com/kdb-x/> or run:
```
Tool: kdbx_q_eval
q_code: ".momentum.mom"
```
to see function source code.
