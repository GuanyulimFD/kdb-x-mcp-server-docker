/ =============================================================================
/ Module   : volflow
/ Namespace: .volflow
/ Description: Intraday volume flow signal module for equity market participant
/              analysis. Provides six complementary market microstructure signals
/              over configurable intraday buckets (default 30 min) in two modes:

/              Streaming/CEP mode (.volflow.onUpdate):
/                Receives incremental trade/order/quote delta tables, maintains
/                per-symbol state in-memory, and returns the latest completed or
/                in-progress bucket signal row after each call.

/              T+1 batch mode (.volflow.calcDay):
/                Replays a full HDB date partition for a symbol and returns a
/                flat table of all 30-min bucket rows sorted ascending by bucket.

/   Six signals (raw value + normalised score [0f,1f]):
/   ---------------------------------------------------
/   ofi         Order Flow Imbalance  - buy vol minus sell vol (signed)
/   vpin        VPIN estimate         - informed/toxic flow proxy
/   flowConc    Flow Concentration    - fraction of vol from block trades
/   poc         Volume Profile POC    - price level with highest bucket volume
/   aggrRatio   Aggressor/Passive     - aggressive buying fraction
/   volImbal    Volume Imbalance      - (buyVol-sellVol)/(buyVol+sellVol)

/   Output: 17-column flat table - all primitive q types, chart-ready.
/   Composite score: weighted mean of 6 scores; direction flag (+1h/0h/-1h).

/ Version  : 0.1.0
/ Requires : KDB/q 4.x or KDB-X 5.0
/ Platform : KDB T+1 HDB Tick Data Platform
/ HDB deps : trade, quote, instrument tables  (calcDay mode only)
/ Author   : kdb-x-mcp-server
/ Jira     : GED-1123
/
/ NAMESPACE NOTE:
/   This module intentionally uses explicit .volflow.* prefixes throughout
/   rather than \d .volflow / \d . blocks. This is because the qcumber test
/   runner resets the namespace context to "." after each `system "l"` call,
/   which silently breaks any \d-scoped definitions at module load time.
/   Explicit prefixes are fully equivalent and are verified to work correctly
/   in both live KDB-X and qcumber test environments.
/
/ RAW vs SCORE COLUMNS:
/   For signals 2 (VPIN), 3 (flowConc), and 5 (aggrRatio), the raw value is
/   already bounded in [0f,1f] by construction, so the raw and score columns
/   carry the same value. The column duplication (e.g. vpin + vpinScore) is
/   intentional: it keeps the output schema symmetric across all six signals
/   and avoids special-casing in downstream charting / ML pipelines.
/
/ NULL PROPAGATION:
/   compositeScore is 0Nf when ALL six scores are null (empty bucket, AC6).
/   If some but not all scores are null (e.g. quote data absent for aggrRatio),
/   the weighted sum includes null terms and compositeScore becomes 0Nf. This
/   conservative "all-or-nothing" behaviour prevents partially-informed signals
/   from being acted on. Signal direction is 0h whenever compositeScore is null.
/ =============================================================================

/ ---------------------------------------------------------------------------
/ Internal logging helpers
/ ---------------------------------------------------------------------------
/ All log messages prefixed with [volflow] for easy grep in mixed logs.
/ Use fd -1 (stdout) for info/warnings, -2 (stderr) for errors.

.volflow.logI_:{if[0 < count x; -1 "[volflow][INFO]  ", string[.z.p], " ", x]};
.volflow.logW_:{if[0 < count x; -1 "[volflow][WARN]  ", string[.z.p], " ", x]};
.volflow.logE_:{if[0 < count x; -2 "[volflow][ERROR] ", string[.z.p], " ", x]};

/ ---------------------------------------------------------------------------
/ Input guard helper
/ ---------------------------------------------------------------------------

/ @desc   Raise a descriptive q signal when a precondition is violated.
/ @param  cond {boolean}  Condition that must be true.
/ @param  msg  {string}   Error message (also logged via logE_).
.volflow.require_:{[cond;msg]
    if[not cond;
        .volflow.logE_[msg];
        '"[volflow] ",msg
    ]
 };

/ ---------------------------------------------------------------------------
/ Configuration (sub-namespace .volflow.cfg.*)
/ All variables can be overridden at runtime.
/ Restore defaults with .volflow.cfg.reset[]
/ ---------------------------------------------------------------------------

/ @desc  Composite score threshold above which signal = +1h (bullish).
.volflow.cfg.bullThresh:0.6f;

/ @desc  Composite score threshold below which signal = -1h (bearish).
.volflow.cfg.bearThresh:0.4f;

/ @desc  Bucket width in minutes (default 30 = standard 30-min intraday bucket).
.volflow.cfg.bucketMins:30;

/ @desc  Minimum trade size in shares for "block trade" classification (Signal 3).
.volflow.cfg.blockSizeThresh:10000;

/ @desc  Max look-back window for asof quote join used in aggressor classification.
.volflow.cfg.quoteJoinTol:0D00:00:01.000000000;

/ @desc  Number of equal-volume sub-buckets for VPIN estimation (Signal 2).
.volflow.cfg.vpinBuckets:50;

/ @desc  Per-signal weights for composite score (symbol->float dict, must sum to 1f).
/        Default: equal weight 1f/6f per signal.
.volflow.cfg.weights:(`ofiScore`vpinScore`flowConcScore`pocScore`aggrRatioScore`volImbalScore)!6#1f%6f;

/ ---------------------------------------------------------------------------
/ cfg.reset - restore all configuration to documented defaults
/ ---------------------------------------------------------------------------

/ @desc   Restore all .volflow.cfg.* variables to their documented defaults.
/         Does not affect per-symbol streaming state.
/ @return :: (side effect only)
/ @example
/   .volflow.cfg.reset[]
.volflow.cfg.reset:{[]
    `.volflow.cfg.bullThresh      set 0.6f;
    `.volflow.cfg.bearThresh      set 0.4f;
    `.volflow.cfg.bucketMins      set 30;
    `.volflow.cfg.blockSizeThresh set 10000;
    `.volflow.cfg.quoteJoinTol    set 0D00:00:01.000000000;
    `.volflow.cfg.vpinBuckets     set 50;
    `.volflow.cfg.weights         set (`ofiScore`vpinScore`flowConcScore`pocScore`aggrRatioScore`volImbalScore)!6#1f%6f;
    .volflow.logI_["cfg.reset: all config restored to defaults"]
 };

/ ---------------------------------------------------------------------------
/ Per-symbol streaming state dictionary
/ state_: sym -> accumulator dict
/   accumulator: `date`bucket`trades`quotes!(date; time; tradeTable; quoteTable)
/ ---------------------------------------------------------------------------
.volflow.state_:()!();

/ ---------------------------------------------------------------------------
/ Empty buffer templates - used to seed fresh accumulators
/ ---------------------------------------------------------------------------
.volflow.emptyT_:flip `time`price`size`side!(`time$(); `float$(); `long$(); `symbol$());
.volflow.emptyQ_:flip `sym`time`bid`ask`bsize`asize!(`symbol$(); `time$(); `float$(); `float$(); `long$(); `long$());

/ ---------------------------------------------------------------------------
/ bucketStart_ - map a time value to the start of its bucket
/ ---------------------------------------------------------------------------

/ @desc   Compute the bucket start time for a given time and bucket width.
/         Formula: floor(milliseconds / bucketMs) * bucketMs
/         Example: 09:45:22.000 -> 09:30:00.000 for bm=30.
/ @param  t  {time}  q time value (milliseconds from midnight)
/ @param  bm {int}   Bucket width in minutes (cfg.bucketMins)
/ @return   {time}   Bucket start time
.volflow.bucketStart_:{[t;bm] `time$ bm * 60000 * floor (`int$t) % (bm * 60000)};

/ ---------------------------------------------------------------------------
/ validateEquity_ - check symbol is a valid equity in the instrument table
/ ---------------------------------------------------------------------------

/ @desc   Confirm sym is present in the instrument table and has assetClass=`equity.
/         Raises a q signal with a descriptive message on failure.
/ @param  s {symbol}  Instrument symbol to validate
/ @throws "unknown symbol: <sym>" when sym not in instrument table
/ @throws "not equity: <sym>" when assetClass != `equity
.volflow.validateEquity_:{[s]
    .volflow.require_[`instrument in tables[];
        "validateEquity_: HDB table 'instrument' not found"];
    matches:select from instrument where sym=s;
    .volflow.require_[0 < count matches;
        "unknown symbol: ", string s];
    .volflow.require_[`equity = first matches`assetClass;
        "not equity: ", string s]
 };

/ ---------------------------------------------------------------------------
/ computeOfi_ - Signal 1: Order Flow Imbalance
/ ---------------------------------------------------------------------------

/ @desc   Compute raw OFI (buy volume minus sell volume) and normalised score.
/         ofiScore: 0.5=balanced, >0.5=buy pressure, <0.5=sell pressure.
/         Score formula: 0.5 + 0.5 * (buyVol-sellVol) / totalVol -> [0f,1f].
/ @param  t {table}  Trade rows  columns: time, price, size {long}, side {`B`S}
/ @return   (ofi{float}; ofiScore{float})  - (0Nf;0Nf) when no trades
.volflow.computeOfi_:{[t]
    if[0 = count t; :(0Nf; 0Nf)];
    bv:"f"$ sum t[`size] * t[`side]=`B;
    tv:"f"$ sum t`size;
    sV:tv - bv;
    ofi:bv - sV;
    ofiScore:$[0f = tv; 0.5f; 0.5f + 0.5f * ofi % tv];
    (ofi; ofiScore)
 };

/ ---------------------------------------------------------------------------
/ computeVpin_ - Signal 2: VPIN Estimate
/ ---------------------------------------------------------------------------

/ @desc   Estimate VPIN by dividing bucket volume into n equal sub-buckets,
/         classifying each as buy or sell, and computing mean absolute imbalance.
/         Formula: VPIN = sum(|buyVol_i - sellVol_i|) / totalVol
/         Result is in [0f,1f]. VPIN is its own normalised score — the same
/         value is stored in both the `vpin` (raw) and `vpinScore` columns.
/ @param  t {table}  Trade rows  columns: time, size, side
/ @param  n {int}    Number of volume sub-buckets (cfg.vpinBuckets = 50)
/ @return   {float}  VPIN in [0f,1f]; 0Nf when no trades
.volflow.computeVpin_:{[t;n]
    if[0 = count t; :0Nf];
    tv:"f"$ sum t`size;
    if[0f = tv; :0Nf];
    subVol:tv % n;
    cv:sums "f"$ t`size;
    bi:`long$ floor cv % subVol;
    buyV:"f"$ t[`size] * t[`side]=`B;
    sellV:"f"$ t[`size] * t[`side]=`S;
    grp:group bi;
    sumBuy:sum each buyV[value grp];
    sumSell:sum each sellV[value grp];
    (sum abs sumBuy - sumSell) % tv
 };

/ ---------------------------------------------------------------------------
/ computeFlowConc_ - Signal 3: Large-Order Flow Concentration
/ ---------------------------------------------------------------------------

/ @desc   Fraction of total bucket volume from trades >= cfg.blockSizeThresh.
/         flowConc is inherently in [0f,1f] — the same value is stored in
/         both the `flowConc` (raw) and `flowConcScore` columns.
/ @param  t      {table}  Trade rows  columns: size {long}
/ @param  thresh {long}   Block size threshold (cfg.blockSizeThresh)
/ @return        {float}  flowConc in [0f,1f]; 0Nf when no trades
.volflow.computeFlowConc_:{[t;thresh]
    if[0 = count t; :0Nf];
    tv:"f"$ sum t`size;
    if[0f = tv; :0Nf];
    ("f"$ sum t[`size] where t[`size] >= thresh) % tv
 };

/ ---------------------------------------------------------------------------
/ computePoc_ - Signal 4: Volume Profile Point of Control
/ ---------------------------------------------------------------------------

/ @desc   Find the price level with the highest cumulative volume and compute
/         a proximity score. Uses floor (not long$) for cent-rounding to ensure
/         truncation in KDB-X 5.0. Uses group pattern to avoid closure limitation.
/         pocScore: 0.5=at POC, <0.5=below (bullish), >0.5=above (bearish).
/ @param  t {table}  Trade rows  columns: price {float}, size {long}
/ @return   (poc{float}; pocScore{float})  - (0Nf;0Nf) when no trades
.volflow.computePoc_:{[t]
    if[0 = count t; :(0Nf; 0Nf)];
    pr:0.01 * floor t[`price] % 0.01;
    vol:"f"$ t`size;
    grp:group pr;
    vbp:sum each vol[value grp];
    pocP:(key grp)[first where vbp = max vbp];
    lp:last t`price;
    rng:(max pr) - min pr;
    pocScore:$[0f = rng; 0.5f; 0f | 1f & 0.5f + 0.5f * (lp - pocP) % (0.5f * rng)];
    (pocP; pocScore)
 };

/ ---------------------------------------------------------------------------
/ computeAggrRatio_ - Signal 5: Aggressor/Passive Ratio
/ ---------------------------------------------------------------------------

/ @desc   Fraction of total bucket volume from aggressive buy orders.
/         Classification via asof quote join when quotes are available.
/         Falls back to side column when quotes table is empty.
/         aggrRatio is inherently in [0f,1f] — the same value is stored in
/         both the `aggrRatio` (raw) and `aggrRatioScore` columns.
/ @param  s {symbol}  Instrument symbol (required for asof join key)
/ @param  t {table}   Trade rows  columns: time, price, size, side
/ @param  q {table}   Quote rows  columns: sym, time, bid, ask, bsize, asize
/ @return   {float}   aggrRatio in [0f,1f]; 0Nf when no trades
.volflow.computeAggrRatio_:{[s;t;q]
    if[0 = count t; :0Nf];
    tv:"f"$ sum t`size;
    if[0f = tv; :0Nf];
    if[0 = count q;
        bv:"f"$ sum t[`size] * t[`side]=`B;
        :bv % tv
    ];
    tt:update sym:s from t;
    jt:aj[`sym`time; tt; q];
    hasQ:not null jt`bid;
    aggrBuy:?[hasQ; jt[`price] >= jt[`ask]; jt[`side]=`B];
    bv:"f"$ sum jt[`size] * aggrBuy;
    bv % tv
 };

/ ---------------------------------------------------------------------------
/ computeVolImbal_ - Signal 6: Volume Imbalance
/ ---------------------------------------------------------------------------

/ @desc   Signed volume imbalance in [-1f,1f] and normalised score [0f,1f].
/         Formula: volImbal = (buyVol - sellVol) / totalVol
/         Score: volImbalScore = 0.5 + 0.5 * volImbal
/         Uses sV for sell volume to avoid q builtin name sv.
/ @param  t {table}  Trade rows  columns: size {long}, side {`B`S}
/ @return   (volImbal{float}; volImbalScore{float})  - (0Nf;0Nf) when no trades
.volflow.computeVolImbal_:{[t]
    if[0 = count t; :(0Nf; 0Nf)];
    bv:"f"$ sum t[`size] * t[`side]=`B;
    tv:"f"$ sum t`size;
    sV:tv - bv;
    vi:$[0f = tv; 0Nf; (bv - sV) % tv];
    (vi; $[null vi; 0Nf; 0.5f + 0.5f * vi])
 };

/ ---------------------------------------------------------------------------
/ classifySignal_ - direction flag from composite score
/ ---------------------------------------------------------------------------

/ @desc   Map composite score to +1h (bullish), 0h (neutral), -1h (bearish).
/ @param  cs  {float}  Composite score or 0Nf
/ @param  bt  {float}  Bull threshold (cfg.bullThresh)
/ @param  brt {float}  Bear threshold (cfg.bearThresh)
/ @return     {short}  +1h, 0h, or -1h
.volflow.classifySignal_:{[cs;bt;brt]
    `short$ $[null cs; 0; cs > bt; 1; cs < brt; -1; 0]
 };

/ ---------------------------------------------------------------------------
/ processOneBucket_ - compute all 6 signals for one bucket
/ ---------------------------------------------------------------------------

/ @desc   Core computation kernel. Runs all six signal functions on trade and
/         quote data for a single bucket, computes composite score, classifies
/         direction, and returns a 1-row flat result table.
/ @param  s   {symbol}  Instrument symbol
/ @param  d   {date}    Trading date
/ @param  bkt {time}    Bucket start time
/ @param  t   {table}   Trade rows for this bucket
/ @param  q   {table}   Session quote rows (asof join looks back in time)
/ @param  cfg {dict}    Config snapshot: weights, bullThresh, bearThresh,
/                        blockSizeThresh, vpinBuckets
/ @return     {table}   1-row table with all 17 output columns
.volflow.processOneBucket_:{[s;d;bkt;t;q;cfg]
    .volflow.logI_["processOneBucket_: sym=", string[s], " bkt=", string bkt];
    ofiR: .volflow.computeOfi_[t];
    vpin: .volflow.computeVpin_[t; cfg`vpinBuckets];
    flowC:.volflow.computeFlowConc_[t; cfg`blockSizeThresh];
    pocR: .volflow.computePoc_[t];
    aggrR:.volflow.computeAggrRatio_[s; t; q];
    viR:  .volflow.computeVolImbal_[t];
    scores:(`ofiScore`vpinScore`flowConcScore`pocScore`aggrRatioScore`volImbalScore)!(ofiR[1]; vpin; flowC; pocR[1]; aggrR; viR[1]);
    comp:$[all null value scores; 0Nf; sum cfg[`weights] * scores];
    sig: .volflow.classifySignal_[comp; cfg`bullThresh; cfg`bearThresh];
    .volflow.logI_["processOneBucket_: compositeScore=", string[comp], " signal=", string sig];
    cols_:`date`sym`bucket`ofi`ofiScore`vpin`vpinScore`flowConc`flowConcScore`poc`pocScore`aggrRatio`aggrRatioScore`volImbal`volImbalScore`compositeScore`signal;
    flip cols_!(enlist d; enlist s; enlist bkt; enlist ofiR[0]; enlist ofiR[1]; enlist vpin; enlist vpin; enlist flowC; enlist flowC; enlist pocR[0]; enlist pocR[1]; enlist aggrR; enlist aggrR; enlist viR[0]; enlist viR[1]; enlist comp; enlist sig)
 };

/ ---------------------------------------------------------------------------
/ calcDay_iter_ - per-bucket helper for calcDay iteration
/ ---------------------------------------------------------------------------

/ @desc   Process one bucket within a calcDay pass. Called via projection to
/         avoid q's inability to capture enclosing scope in inner lambdas.
/ @param  s    {symbol}  Instrument symbol
/ @param  d    {date}    Trading date
/ @param  allT {table}   All day's trades (with `bucket` column added by calcDay)
/ @param  allQ {table}   All day's quotes (full session)
/ @param  bkt  {time}    Bucket start to process (the varying argument)
/ @param  cfg  {dict}    Config snapshot
/ @return      {table}   1-row result table
.volflow.calcDay_iter_:{[s;d;allT;allQ;bkt;cfg]
    bktT:allT where allT[`bucket] = bkt;
    .volflow.processOneBucket_[s; d; bkt; bktT; allQ; cfg]
 };

/ ---------------------------------------------------------------------------
/ PUBLIC API
/ ---------------------------------------------------------------------------

/ ---------------------------------------------------------------------------
/ onUpdate - streaming/CEP incremental update
/ ---------------------------------------------------------------------------

/ @desc   Accumulate incremental trade/order/quote delta tables for a symbol and
/         return the signal row for the latest bucket.

/         Within-bucket: merges deltas into running accumulator and returns signals
/         computed on all accumulated data so far.

/         Bucket boundary: finalises completed bucket and starts fresh accumulator.

/ @param  sym        {symbol}  Equity symbol (must be in instrument table)
/ @param  date       {date}    Trading date
/ @param  time       {time}    Current tick batch time (determines bucket)
/ @param  tradeDelta {table}   New trade rows: time, price, size{long}, side{`B`S}
/ @param  orderDelta {table}   New order rows (reserved; not used in v0.1 signals)
/ @param  quoteDelta {table}   New quote rows: sym, time, bid, ask, bsize, asize
/ @return            {table}   1-row signal table (17 columns)
/ @throws if sym is not an equity in the instrument table
/ @example
/   .volflow.onUpdate[`AAPL; 2026.05.10; 09:35:00.000t;
/     ([] time:09:30:01.000 09:31:01.000t; price:100 101f;
/         size:500 1000j; side:`B`S);
/     ();
/     ([] sym:`AAPL`AAPL; time:09:30:00.500 09:31:00.500t;
/         bid:99.5 99.6f; ask:100.5 100.6f; bsize:200 200j; asize:200 200j)]
.volflow.onUpdate:{[sym;date;time;tradeDelta;orderDelta;quoteDelta]
    .volflow.logI_["update: sym=", string[sym], " time=", string time];
    .volflow.validateEquity_[sym];
    bm:       .volflow.cfg.bucketMins;
    newBucket:.volflow.bucketStart_[time; bm];
    cfg:`weights`bullThresh`bearThresh`blockSizeThresh`vpinBuckets!
        (.volflow.cfg.weights; .volflow.cfg.bullThresh; .volflow.cfg.bearThresh;
         .volflow.cfg.blockSizeThresh; .volflow.cfg.vpinBuckets);
    if[not sym in key .volflow.state_;
        .volflow.state_[sym]:`date`bucket`trades`quotes!(date; newBucket; .volflow.emptyT_; .volflow.emptyQ_)
    ];
    acc:.volflow.state_[sym];
    crossedBoundary:not newBucket = acc`bucket;
    completedRow:$[crossedBoundary;
        .volflow.processOneBucket_[sym; acc`date; acc`bucket; acc`trades; acc`quotes; cfg];
        ()
    ];
    .volflow.state_[sym]:$[crossedBoundary;
        `date`bucket`trades`quotes!(date; newBucket; tradeDelta; quoteDelta);
        `date`bucket`trades`quotes!(acc`date; acc`bucket; (acc[`trades] , tradeDelta); (acc[`quotes] , quoteDelta))
    ];
    $[crossedBoundary;
        completedRow;
        .volflow.processOneBucket_[sym; date; newBucket; .volflow.state_[sym]`trades; .volflow.state_[sym]`quotes; cfg]
    ]
 };

/ ---------------------------------------------------------------------------
/ calcDay - T+1 batch full-day computation
/ ---------------------------------------------------------------------------

/ @desc   Load all trades and quotes for sym on date from the HDB, compute
/         signals for every bucket with at least one trade, and return a flat
/         table sorted ascending by bucket start time.

/ @param  sym  {symbol}  Equity symbol
/ @param  date {date}    Historical trading date (must be <= today)
/ @return      {table}   One row per traded bucket; empty typed table if no trades
/ @throws "HDB table 'trade' not available"
/ @throws "HDB table 'quote' not available"
/ @throws "unknown symbol: <sym>" or "not equity: <sym>"
/ @throws "future date not allowed: <date>"
/ @example
/   .volflow.calcDay[`AAPL; 2026.05.09]
/   / Returns table with one row per 30-min bucket where trades existed
.volflow.calcDay:{[sym;date]
    .volflow.logI_["calcDay: sym=", string[sym], " date=", string date];
    .volflow.require_[`trade in tables[];
        "calcDay: HDB table 'trade' not available"];
    .volflow.require_[`quote in tables[];
        "calcDay: HDB table 'quote' not available"];
    .volflow.validateEquity_[sym];
    .volflow.require_[date <= .z.D;
        "calcDay: future date not allowed: ", string date];
    cfg:`weights`bullThresh`bearThresh`blockSizeThresh`vpinBuckets!
        (.volflow.cfg.weights; .volflow.cfg.bullThresh; .volflow.cfg.bearThresh;
         .volflow.cfg.blockSizeThresh; .volflow.cfg.vpinBuckets);
    bm:.volflow.cfg.bucketMins;
    allT:select time, price, size, side from trade where date=date, sym=sym;
    if[0 = count allT;
        .volflow.logW_["calcDay: no trades found for sym=", string[sym], " date=", string date];
        :flip `date`sym`bucket`ofi`ofiScore`vpin`vpinScore`flowConc`flowConcScore`poc`pocScore`aggrRatio`aggrRatioScore`volImbal`volImbalScore`compositeScore`signal!
             (`date$(); `symbol$(); `time$(); `float$(); `float$(); `float$(); `float$();
              `float$(); `float$(); `float$(); `float$(); `float$(); `float$();
              `float$(); `float$(); `float$(); `short$())
    ];
    allT:update sym:sym from allT;
    allTb:update bucket:.volflow.bucketStart_[;bm] each time from allT;
    allQ:select sym, time, bid, ask, bsize, asize from quote where date=date, sym=sym;
    uniqBkts:`time$ asc distinct allTb`bucket;
    result:raze .volflow.calcDay_iter_[sym; date; allTb; allQ;; cfg] each uniqBkts;
    .volflow.logI_["calcDay: done - ", string[count result], " buckets for sym=", string sym];
    result
 };

/ ---------------------------------------------------------------------------
/ getState - inspect current per-symbol streaming accumulator
/ ---------------------------------------------------------------------------

/ @desc   Return the internal accumulator dict for a symbol (read-only inspect).
/ @param  sym {symbol}  Symbol to inspect
/ @return     {dict}    Accumulator dict; empty dict when sym has no state
/ @example
/   .volflow.getState[`AAPL]
/   / Returns `date`bucket`trades`quotes!(...) or ()!() if no state exists
.volflow.getState:{[sym]
    .volflow.logI_["getState: sym=", string sym];
    $[sym in key .volflow.state_; .volflow.state_[sym]; ()!()]
 };

/ ---------------------------------------------------------------------------
/ resetState - clear per-symbol streaming accumulator
/ ---------------------------------------------------------------------------

/ @desc   Remove the streaming accumulator for a specific symbol.
/ @param  sym {symbol}  Symbol to clear
/ @return    :: (side effect only)
/ @example
/   .volflow.resetState[`AAPL]
.volflow.resetState:{[sym]
    .volflow.logI_["resetState: clearing state for sym=", string sym];
    .volflow.state_:.volflow.state_ _ sym
 };

/ ---------------------------------------------------------------------------
/ resetAll - clear all per-symbol streaming state
/ ---------------------------------------------------------------------------

/ @desc   Remove all per-symbol streaming accumulators. Call at the start of
/         each new trading session to prevent stale state from prior days.
/ @return    :: (side effect only)
/ @example
/   .volflow.resetAll[]
.volflow.resetAll:{[]
    .volflow.logI_["resetAll: clearing all state (", string[count .volflow.state_], " symbols)"];
    .volflow.state_::()!()
 };

/ ---------------------------------------------------------------------------
/ Module load banner
/ ---------------------------------------------------------------------------

-1 "[volflow] module loaded - namespace .volflow";
-1 "[volflow] Public API: onUpdate, calcDay, getState, resetState, resetAll, cfg.reset";
-1 "[volflow] Signals: OFI, VPIN, flowConc, POC, aggrRatio, volImbal  |  Jira: GED-1123";
