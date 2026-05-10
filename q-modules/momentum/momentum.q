// =============================================================================
// Module : momentum
// Namespace : .momentum
// Description : Momentum indicators for KDB/q developers working with
//               price time-series data. All functions are designed to be
//               used within qSQL queries and avoid imperative loops.
//
//   Included analytics
//   ------------------
//   mom             Simple Momentum - price difference over n periods
//   roc             Rate of Change - percentage momentum over n periods
//   mosc            Momentum Oscillator - normalized momentum using MA
//
// Version  : 0.1.0
// Requires : KDB/q  4.x  (compatible with both 4.x and KDB-X 5.0)
// Author   : kdb-x-mcp-server
// =============================================================================

\d .momentum

// ---------------------------------------------------------------------------
// Internal logging helpers
// ---------------------------------------------------------------------------
/ All log messages are prefixed with [momentum] for easy grep in mixed logs.
/ Use fd -1 (stdout) for info, -2 (stderr) for warnings and errors.
/ Guards against null/empty messages to keep logs clean.

logI_: {if[0 < count x; -1 "[momentum][INFO]  ", string[.z.p], " ", x]}
logW_: {if[0 < count x; -1 "[momentum][WARN]  ", string[.z.p], " ", x]}
logE_: {if[0 < count x; -2 "[momentum][ERROR] ", string[.z.p], " ", x]}

// ---------------------------------------------------------------------------
// Internal guard helpers
// ---------------------------------------------------------------------------

/ @desc Raise a descriptive error when a precondition is violated.
require_:{[cond;msg]
    if[not cond;
        .momentum.logE_[msg];
        '"[momentum] ",msg
    ]
 }

// ---------------------------------------------------------------------------
// mom  Simple Momentum
// ---------------------------------------------------------------------------

/ @desc   Compute simple momentum as the difference between the current price
/         and the price n periods ago. Uses functional prev operator to shift
/         the series. First n values will be null (insufficient history).
/         This is the most basic momentum indicator - positive values indicate
/         upward momentum, negative values indicate downward momentum.
/ @param  prices {float list}   Ordered price series (oldest first).
/ @param  n      {long}         Lookback period (must be >= 1 and <= count prices).
/ @return        {float list}   Momentum series; first n values are null.
/ @throws        if n < 1 or prices is empty.
/ @perf   O(n) using vector subtraction; no loops.
/ @example
/   .momentum.mom[100 102 101 105 103f; 2]
/   /  0n 0n 1 3 2f   (101-100, 105-102, 103-101)
mom:{[prices;n]
    .momentum.logI_["mom: period=", string[n], " len=", string count prices];
    .momentum.require_[0 < count prices; "mom: prices list must not be empty"];
    .momentum.require_[n >= 1; "mom: period n must be >= 1"];
    / Shift prices by n periods using built-in xprev
    result: prices - n xprev prices;
    .momentum.logI_["mom: computed ", string[count result], " values"];
    result
 }

// ---------------------------------------------------------------------------
// roc  Rate of Change
// ---------------------------------------------------------------------------

/ @desc   Compute the Rate of Change (ROC) as percentage momentum over n periods.
/         Formula: ((price[t] - price[t-n]) / price[t-n]) * 100
/         Returns percentage change; positive = upward momentum, negative = downward.
/         First n values are null. Handles zero/null prices gracefully.
/ @param  prices {float list}   Ordered price series (oldest first).
/ @param  n      {long}         Lookback period (must be >= 1).
/ @return        {float list}   ROC percentage series; first n values are null.
/ @throws        if n < 1 or prices is empty.
/ @perf   O(n) using vector operations; no loops.
/ @example
/   .momentum.roc[100 110 105 115.5f; 2]
/   /  0n 0n 5 5f   ((105-100)/100*100 = 5%, (115.5-110)/110*100 = 5%)
roc:{[prices;n]
    .momentum.logI_["roc: period=", string[n], " len=", string count prices];
    .momentum.require_[0 < count prices; "roc: prices list must not be empty"];
    .momentum.require_[n >= 1; "roc: period n must be >= 1"];
    / Shift prices by n periods using built-in xprev
    prevPrices: n xprev prices;
    / Calculate percentage change, handling zero denominators
    result: ?[prevPrices = 0f; 0Nf; ((prices - prevPrices) % prevPrices) * 100f];
    .momentum.logI_["roc: computed ", string[count result], " values"];
    result
 }

// ---------------------------------------------------------------------------
// mosc  Momentum Oscillator
// ---------------------------------------------------------------------------

/ @desc   Compute the Momentum Oscillator as the difference between price and
/         its simple moving average, normalized by the SMA. This shows how far
/         the current price has deviated from its average - a momentum measure.
/         Formula: ((price - SMA[n]) / SMA[n]) * 100
/         Positive values = price above average (bullish momentum)
/         Negative values = price below average (bearish momentum)
/         First n-1 values are null (insufficient SMA history).
/ @param  prices {float list}   Ordered price series (oldest first).
/ @param  n      {long}         SMA window size (must be >= 1).
/ @return        {float list}   Oscillator percentage series; first n-1 null.
/ @throws        if n < 1 or prices is empty.
/ @perf   O(n) using mavg and vector operations; no loops.
/ @example
/   .momentum.mosc[100 102 104 106 108f; 3]
/   /  0n 0n 2.0 2.0 2.0f approx (price deviates ~2% above SMA)
mosc:{[prices;n]
    .momentum.logI_["mosc: window=", string[n], " len=", string count prices];
    .momentum.require_[0 < count prices; "mosc: prices list must not be empty"];
    .momentum.require_[n >= 1; "mosc: window n must be >= 1"];
    sma: mavg[n; prices];
    / Calculate deviation from SMA as percentage, handle zero SMA
    result: ?[sma = 0f; 0Nf; ((prices - sma) % sma) * 100f];
    .momentum.logI_["mosc: computed ", string[count result], " values"];
    result
 }

// ---------------------------------------------------------------------------
// Module registration and load banner
// ---------------------------------------------------------------------------

\d .
.momentum.mom:.momentum.mom
.momentum.roc:.momentum.roc
.momentum.mosc:.momentum.mosc

-1 "[momentum] module loaded — namespace .momentum"
-1 "[momentum] Available functions: mom (simple momentum), roc (rate of change), mosc (momentum oscillator)"
