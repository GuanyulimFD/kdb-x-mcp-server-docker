# KDB T+1 HDB Tick Data Platform — Business Context

## Purpose
This platform is a **T+1 historical database (HDB)** built on KDB-X (kdb v5.0). It stores and serves **tick-level market data** — trades, quotes, and order book snapshots — end-of-day after each trading session. Downstream consumers use it for three primary analytical domains:

| Domain | Business Problem | Primary Users |
|--------|-----------------|---------------|
| **Trade P&L Analysis** | Understand realised and unrealised profit/loss per trade, per book, per strategy, per day | Traders, Risk Managers |
| **Customer Profile** | Characterise trading behaviour per client: volume, frequency, instrument mix, execution quality | Sales, Coverage, Client Analytics |
| **Trading Behaviour** | Identify patterns in execution style: aggressor/passive ratio, time-of-day activity, fill rates, slippage | Quant Analysts, Compliance, Algo Teams |

---

## Data Architecture

### Partition Model
- **Partition key**: `date` (daily partitions)
- **Lookback pattern**: T+1 — data for trading day `D` is available from `D+1 00:00 UTC`
- **Typical retention**: 2–5 years of tick history

### Core HDB Tables

| Table | Granularity | Key Columns | Notes |
|-------|-------------|-------------|-------|
| `trade` | Per execution | `date`, `sym`, `time`, `price`, `size`, `side`, `tradeId`, `bookId` | Primary P&L source |
| `quote` | Per quote event | `date`, `sym`, `time`, `bid`, `ask`, `bsize`, `asize` | NBBO / market quotes |
| `order` | Per order lifecycle | `date`, `sym`, `time`, `orderId`, `status`, `price`, `qty`, `fillQty` | Order management |
| `position` | EOD snapshot | `date`, `sym`, `bookId`, `qty`, `avgCost`, `marketValue` | Position P&L base |
| `client` | Reference | `clientId`, `name`, `tier`, `region`, `coverageTeam` | Client dimension |
| `instrument` | Reference | `sym`, `isin`, `assetClass`, `currency`, `exchange` | Instrument dimension |

### Common Join Patterns
- `trade` ⟕ `instrument` on `sym` — enrich with asset class / currency
- `trade` ⟕ `client` on `clientId` — enrich with client tier / region
- `position` ⟕ `trade` (daily) — reconcile EOD position against executed trades
- `trade` `aj` `quote` on `[sym; time]` — arrival price benchmarking (implementation shortfall)

---

## Business Rules & Constraints

### P&L Calculation
- Realised P&L = (sell price − weighted avg cost) × size, signed by `side`
- MTM P&L uses EOD `position.marketValue` as reference
- FX trades require additional FX rate join; not yet automated — flag as out-of-scope unless specified
- Corporate actions (splits, dividends) adjust `avgCost` in `position`; the platform does NOT auto-adjust historical tick data

### Customer Profile
- Client-level aggregation uses `clientId` from `trade`
- Tier classification (Tier 1 / 2 / 3) is sourced from `client` reference table
- Activity metrics: traded value (price × size), trade count, unique symbols per day/week/month
- Execution quality benchmark: VWAP arrival (compare fill price to prevailing VWAP)

### Trading Behaviour
- Aggressor/passive classification: compare `trade.side` with `quote.bid`/`quote.ask` at arrival
- Time-of-day is bucketed in 30-minute windows by convention (`time.hh` ÷ 0.5`)
- Fill rate = `fillQty / qty` from `order` table

---

## Available q-Modules

| Module | Namespace | Relevant For |
|--------|-----------|-------------|
| `finstat` | `.finstat` | VWAP, returns, volatility, EMA/SMA, Sharpe, max drawdown — all P&L and behaviour analytics |
| `dataprofile` | `.dataprofile` | Profiling new data sources / validating ingestion |
| `cron` | `.cron` | Scheduling T+1 batch jobs, scheduled reporting |
| `lookback` | `.lookback` | Rolling window statistics — behaviour trend analysis |

---

## Assumptions Always Requiring Explicit Confirmation
- Date range (start and end date, inclusive/exclusive)
- Symbol universe (all, filtered by asset class, specific list)
- Aggregation level (trade-level, daily, weekly, client-level, book-level)
- Whether FX normalisation is required
- Whether corporate actions need adjusting
- Whether intraday or EOD snapshots are used for position
