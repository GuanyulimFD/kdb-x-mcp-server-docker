// =============================================================================
// Module   : lookback
// Namespace: .lookback
// Description:
//   Lookback statistics for as-of joined market data.
//
//   For each row in a trade table, computes the prevailing quote
//   (bid / ask / sizes) at N configurable lookback horizons relative
//   to the trade timestamp — e.g. t-0, t-30 s, t-1 min, t-5 min.
//
//   The core idiom: for each horizon h, shift the trade timestamp back
//   by h, then call aj[] against the quote table to retrieve the most-
//   recent quote at or before that shifted time.  Results are wide-joined
//   to the original trade table with column-name suffixes <col>_<label>.
//
//   Public API
//   ----------
//   defaultOffsets  Convenience dict: t0 / t30s / t1m / t5m
//   snapAt          Single-horizon lookback as-of join
//   multiSnap       Multi-horizon lookback as-of join (full wide table)
//   nbboAt          Point-in-time NBBO for one (sym, venue) scalar lookup
//
// Version  : 0.1.0
// Requires : KDB/q 4.x or KDB-X 5.0
// Author   : kdb-x-mcp-server
// =============================================================================

\d .lookback

// ---------------------------------------------------------------------------
// Internal logging helpers
// ---------------------------------------------------------------------------
/ All messages prefixed with [lookback] for easy grep in mixed log streams.
/ fd -1 (stdout) for info/warn; fd -2 (stderr) for errors.
/ Guards against null/empty messages to keep logs clean.
/ NOTE: use bracket syntax string[x] and multi-char separators to avoid
/       the q right-to-left parsing and single-char type pitfalls.

logI_:{if[0 < count x; -1 "[lookback][INFO]  ", string[.z.p], "  ", x]}
logW_:{if[0 < count x; -1 "[lookback][WARN]  ", string[.z.p], "  ", x]}
logE_:{if[0 < count x; -2 "[lookback][ERROR] ", string[.z.p], "  ", x]}

// ---------------------------------------------------------------------------
// Internal guard helper
// ---------------------------------------------------------------------------
/ @desc  Raise a descriptive error when a precondition is violated.
require_:{[cond;msg]
    if[not cond;
        .lookback.logE_[msg];
        '"[lookback] ", msg
    ]
 }

// ---------------------------------------------------------------------------
// defaultOffsets
// ---------------------------------------------------------------------------
/ @desc   Returns the standard lookback horizon dictionary:
/           t0   -> 0 (current snapshot, aj at trade time)
/           t30s -> 30 seconds before trade time
/           t1m  -> 1 minute before trade time
/           t5m  -> 5 minutes before trade time
/         Pass the result directly to multiSnap or extend it with custom
/         horizons.
/ @return {dict}  symbol -> timespan mapping
/ @example
/   .lookback.defaultOffsets[]
/   / `t0`t30s`t1m`t5m ! 0D00:00:00 0D00:00:30 0D00:01:00 0D00:05:00
defaultOffsets:{[]
    `t0`t30s`t1m`t5m ! 0D00:00:00 0D00:00:30 0D00:01:00 0D00:05:00
 }

// ---------------------------------------------------------------------------
// Internal: prepareQt_
// ---------------------------------------------------------------------------
/ @desc  Add an adjTime alias column and sort the quote table once so that
/        aj[] can be called efficiently across all horizons without
/        re-sorting per call.
/ @param qt       {table}        Quote / NBBO feed table (must have `time`)
/ @param joinCols {symbol list}  Non-time key columns (e.g. `sym`venue)
/ @return {table} Quote table sorted by (joinCols, adjTime) with adjTime=time
prepareQt_:{[qt;joinCols]
    qt2: update adjTime:time from qt;
    (joinCols, `adjTime) xasc qt2
 }

// ---------------------------------------------------------------------------
// snapAt — single-horizon lookback as-of join
// ---------------------------------------------------------------------------
/ @desc   Shifts each trade's timestamp back by `offset`, performs aj[]
/         against the quote table, and returns the trade table augmented
/         with quote columns renamed <col>_<label>.
/         The quote table is sorted internally — no pre-sorting required.
/ @param  qt        {table}        Quote table.
/                                  Required columns: time, <joinCols>, <quoteCols>
/ @param  tt        {table}        Trade table.
/                                  Required columns: time, <joinCols>
/ @param  joinCols  {symbol list}  Non-time key columns for the aj,
/                                  e.g. `sym`venue
/ @param  label     {symbol}       Suffix label for output columns, e.g. `t30s
/ @param  offset    {timespan}     How far back to shift the timestamp,
/                                  e.g. 0D00:00:30
/ @param  quoteCols {symbol list}  Columns to pull from qt,
/                                  e.g. `bid`ask`bSize`aSize
/ @return {table}  tt with additional columns <col>_<label>
/ @throws if qt/tt are not tables; joinCols or quoteCols missing from schema
/ @example
/   .lookback.snapAt[quotes; trades; `sym`venue; `t30s; 0D00:00:30; `bid`ask]
snapAt:{[qt;tt;joinCols;label;offset;quoteCols]
    .lookback.logI_["snapAt: label=", string[label],
        "  offset=", string[offset],
        "  trades=", string[count tt]];
    .lookback.require_[98h = type qt;         "snapAt: qt must be a table"];
    .lookback.require_[98h = type tt;         "snapAt: tt must be a table"];
    / Normalise scalar symbol to 1-element list
    quoteCols: $[0 > type quoteCols; enlist quoteCols; quoteCols];
    .lookback.require_[`time in cols qt;      "snapAt: qt must have a time column"];
    .lookback.require_[`time in cols tt;      "snapAt: tt must have a time column"];
    .lookback.require_[all joinCols in cols qt;"snapAt: joinCols missing from qt"];
    .lookback.require_[all joinCols in cols tt;"snapAt: joinCols missing from tt"];
    .lookback.require_[all quoteCols in cols qt;"snapAt: quoteCols missing from qt"];

    adjQt:     .lookback.prepareQt_[qt; joinCols];
    shiftedTT: update adjTime:(time - offset) from tt;
    joined:    aj[joinCols, `adjTime; shiftedTT; adjQt];

    / Build suffixed column names: bid_t30s, ask_t30s, etc.
    newNames: `$ string[quoteCols],\:("_", string[label]);
    extra:  newNames xcol (quoteCols # joined);
    result: tt ,' extra;

    .lookback.logI_["snapAt: done — ", string[count result], " rows  ",
        string[count newNames], " column(s) added"];
    result
 }

// ---------------------------------------------------------------------------
// multiSnap — multi-horizon lookback as-of join
// ---------------------------------------------------------------------------
/ @desc   Calls the lookback aj for each (label, offset) pair in `offsets`,
/         building a wide output table with columns <col>_<label> for every
/         combination of quote column and horizon.
/         The quote table is pre-sorted once and reused across all horizons.
/ @param  qt        {table}        Quote table (see snapAt for schema)
/ @param  tt        {table}        Trade table (see snapAt for schema)
/ @param  joinCols  {symbol list}  Non-time key columns (e.g. `sym`venue)
/ @param  offsets   {dict}         label!timespan mapping.
/                                  Use .lookback.defaultOffsets[] for the
/                                  standard t0 / t30s / t1m / t5m set,
/                                  or supply any custom horizons:
/                                    `h1`h2!0D00:00:10 0D00:02:00
/ @param  quoteCols {symbol list}  Columns to pull from qt per horizon
/ @return {table}  tt with <col>_<label> columns for all offsets
/ @throws if offsets is not a non-empty dict, or schema checks fail
/ @example
/   .lookback.multiSnap[quotes; trades; `sym`venue;
/       .lookback.defaultOffsets[]; `bid`ask`bSize`aSize]
multiSnap:{[qt;tt;joinCols;offsets;quoteCols]
    .lookback.logI_["multiSnap: horizons=", .Q.s1[key offsets],
        "  trades=", string[count tt]];
    .lookback.require_[98h = type qt;         "multiSnap: qt must be a table"];
    .lookback.require_[98h = type tt;         "multiSnap: tt must be a table"];
    .lookback.require_[99h = type offsets;    "multiSnap: offsets must be a dict"];
    .lookback.require_[0 < count offsets;     "multiSnap: offsets must not be empty"];
    / Normalise scalar symbol to 1-element list
    quoteCols: $[0 > type quoteCols; enlist quoteCols; quoteCols];

    / Sort quote table once — reused for every horizon pass
    adjQt: .lookback.prepareQt_[qt; joinCols];

    / Inner function: one horizon -> extra cols table (no logging for brevity)
    lookback_:{[adjQt;tt;joinCols;quoteCols;lbl;off]
        shiftedTT: update adjTime:(time - off) from tt;
        joined:    aj[joinCols, `adjTime; shiftedTT; adjQt];
        newNames:  `$ string[quoteCols],\:("_", string[lbl]);
        newNames xcol (quoteCols # joined)
        };

    extraList: lookback_[adjQt;tt;joinCols;quoteCols]'[key offsets; value offsets];
    result:    tt ,' (,'/) extraList;

    .lookback.logI_["multiSnap: done — ", string[count result], " rows  ",
        string[count[offsets] * count quoteCols], " lookback column(s) added"];
    result
 }

// ---------------------------------------------------------------------------
// nbboAt — point-in-time NBBO scalar lookup
// ---------------------------------------------------------------------------
/ @desc   Retrieves the most-recent quote for a single (sym, venue) at or
/         before timestamp `ts`.  Efficient for one-off lookups; for bulk
/         queries across a trade table use multiSnap instead.
/ @param  qt        {table}        Quote table with time, sym, venue columns
/ @param  s         {symbol}       Instrument symbol, e.g. `AAPL
/ @param  ven       {symbol}       Venue / exchange, e.g. `NYSE
/ @param  ts        {timestamp}    Point-in-time, e.g. 2024.01.15D09:31:00
/ @param  quoteCols {symbol list}  Columns to include in the result dict
/ @return {dict}   Column->value dictionary for the most-recent quote row
/                  at or before ts; null values if no prior quote exists
/ @throws if qt is not a table or required columns are missing
/ @example
/   .lookback.nbboAt[quotes; `AAPL; `NYSE; 2024.01.15D09:36:05.000000000;
/       `bid`ask`bSize`aSize]
nbboAt:{[qt;s;ven;ts;quoteCols]
    .lookback.logI_["nbboAt: sym=", string[s],
        "  venue=", string[ven],
        "  t=",     string[ts]];
    .lookback.require_[98h = type qt;         "nbboAt: qt must be a table"];
    .lookback.require_[`time in cols qt;      "nbboAt: qt must have a time column"];
    .lookback.require_[`sym in cols qt;       "nbboAt: qt must have a sym column"];
    .lookback.require_[`venue in cols qt;     "nbboAt: qt must have a venue column"];
    / Normalise scalar symbol to 1-element list
    quoteCols: $[0 > type quoteCols; enlist quoteCols; quoteCols];
    .lookback.require_[all quoteCols in cols qt;"nbboAt: quoteCols missing from qt"];

    / Filter to (sym, venue) and find the last row at or before ts
    sub: select from qt where sym=s, venue=ven, time <= ts;

    if[0 = count sub;
        .lookback.logW_["nbboAt: no quotes found for sym=", string[s],
            "  venue=", string[ven],
            "  at or before t=", string[ts]];
        :quoteCols ! count[quoteCols] # 0Nf
    ];

    result: last (quoteCols # sub);
    .lookback.logI_["nbboAt: found quote at t=", string[last sub`time]];
    result
 }

\d .
-1 "[lookback] module loaded — namespace .lookback";
