// =============================================================================
// Module : finstat
// Namespace : .finstat
// Description : Common financial statistics for KDB/q developers working
//               with price and volume time-series data.
//
//   Included analytics
//   ------------------
//   sma             Simple Moving Average (window average)
//   ema             Exponential Moving Average (decay-factor smoothing)
//   simpleReturns   Arithmetic period-over-period returns
//   logReturns      Natural log period-over-period returns
//   rollingVol      Annualised rolling historical volatility (log returns)
//   vwap            Volume-Weighted Average Price
//   cumulativeReturn Total fractional return from first to last price
//   sharpe          Annualised Sharpe ratio (excess return / vol)
//   maxDrawdown     Maximum peak-to-trough drawdown of a price series
//
// Version  : 0.1.0
// Requires : KDB/q  4.x  (no KDB-X 5 module framework used  compatible
//            with both 4.x and KDB-X 5.0)
// Author   : kdb-x-mcp-server
// =============================================================================

\d .finstat

// ---------------------------------------------------------------------------
// Internal logging helpers
// ---------------------------------------------------------------------------
/ All log messages are prefixed with [finstat] for easy grep in mixed logs.
/ Use fd -1 (stdout) for info, -2 (stderr) for warnings and errors.
/ Guards against null/empty messages to keep logs clean.

logI_: {if[0 < count x; -1 "[finstat][INFO]  ", string[.z.p], " ", x]}
logW_: {if[0 < count x; -1 "[finstat][WARN]  ", string[.z.p], " ", x]}
logE_: {if[0 < count x; -2 "[finstat][ERROR] ", string[.z.p], " ", x]}

// ---------------------------------------------------------------------------
// Internal guard helpers
// ---------------------------------------------------------------------------

/ @desc Raise a descriptive error when a precondition is violated.
require_:{[cond;msg]
    if[not cond;
        .finstat.logE_[msg];
        '"[finstat] ",msg
    ]
 }

// ---------------------------------------------------------------------------
// sma  Simple Moving Average
// ---------------------------------------------------------------------------

/ @desc   Compute the simple (unweighted) moving average over a rolling window
/         of length n.  Uses q's built-in mavg, which returns nulls for the
/         first n-1 positions (consistent with industry convention).
/ @param  prices {float list}   Ordered price series (oldest first).
/ @param  n      {long}         Lookback window size (must be  1 and 
/                               count prices).
/ @return        {float list}   SMA series; first n-1 values are null.
/ @throws        if n < 1 or count prices < 1.
/ @example
/   .finstat.sma[100 101 102 103 104f; 3]
/   /  0n 0n 101 102 103f
sma:{[prices;n]
    .finstat.logI_["sma: window=", string[n], " len=", string count prices];
    .finstat.require_[0 < count prices; "sma: prices list must not be empty"];
    .finstat.require_[n >= 1; "sma: window n must be >= 1"];
    result: mavg[n; prices];
    .finstat.logI_["sma: computed ", string[count result], " values"];
    result
 }

// ---------------------------------------------------------------------------
// ema  Exponential Moving Average
// ---------------------------------------------------------------------------

/ @desc   Compute the Exponential Moving Average using a fixed smoothing factor
/         alpha.  The first output is seeded to the first input price; subsequent
/         values use the recurrence:
/             ema[t] = alpha * price[t]  +  (1 - alpha) * ema[t-1]
//
/         Common alpha choices: 2 % (n+1) for an n-period EMA.
/ @param  prices {float list}   Ordered price series (oldest first).
/ @param  alpha  {float}        Smoothing factor in the open interval (0, 1].
/ @return        {float list}   EMA series (same length as prices).
/ @throws        if prices is empty or alpha is out of range.
/ @perf   O(n)  single pass via explicit while loop.
/ @example
/   .finstat.ema[100 101 102 103 104f; 0.5]
/   /  100 100.5 101.25 102.125 103.0625f
.finstat.ema:{[prices;alpha]
    .finstat.logI_["ema: alpha=", string[alpha], " len=", string count prices];
    .finstat.require_[0 < count prices; "ema: prices list must not be empty"];
    .finstat.require_[(alpha > 0f) and alpha <= 1f;
        "ema: alpha must be in (0,1] - got ", string alpha];
    / Build EMA iteratively (scan adverb \ cannot be used inside a function
    / body when file-loading under KDB-X 5.0, so use explicit while loop)
    n: count prices;
    result: n#0f;
    result[0]: prices[0];
    i: 1;
    while[i < n;
        result[i]: result[i-1] + alpha*(prices[i]-result[i-1]);
        i+:1
    ];
    .finstat.logI_["ema: computed ", string[count result], " values"];
    result
 }

// ---------------------------------------------------------------------------
// simpleReturns  Arithmetic period-over-period returns
// ---------------------------------------------------------------------------

/ @desc   Compute the simple (arithmetic) return for each period:
/             r[t] = (p[t] - p[t-1]) / p[t-1]
/         The returned list has the same length as the input with all-null
/         first element removed (length n-1).
/ @param  prices {float list}   Ordered price series (oldest first).
/ @return        {float list}   Simple returns; length = count[prices] - 1.
/ @throws        if prices has fewer than 2 elements or contains zero prices
/                at t-1 positions (division by zero guard).
/ @perf   O(n)  vectorised subtraction and division.
/ @example
/   .finstat.simpleReturns[100 105 110 99f]
/   /  0.05 0.04761905 -0.1f
simpleReturns:{[prices]
    .finstat.logI_["simpleReturns: len=", string count prices];
    .finstat.require_[1 < count prices;
        "simpleReturns: need at least 2 prices"];
    .finstat.require_[not any 0 = prev prices;
        "simpleReturns: zero price detected - would cause division by zero"];
    result: 1_ (prices - prev prices) % prev prices;
    .finstat.logI_["simpleReturns: computed ", string[count result], " returns"];
    result
 }

// ---------------------------------------------------------------------------
// logReturns  Natural log period-over-period returns
// ---------------------------------------------------------------------------

/ @desc   Compute the natural log return for each period:
/             r[t] = ln( p[t] / p[t-1] )
/         Log returns are additive across time and symmetric around zero 
/         preferred for volatility and Sharpe calculations.
/         The returned list has length count[prices] - 1.
/ @param  prices {float list}   Ordered price series (oldest first, all > 0).
/ @return        {float list}   Log returns; length = count[prices] - 1.
/ @throws        if prices has fewer than 2 elements or any price  0.
/ @example
/   .finstat.logReturns[100 105 110 99f]
/   /  0.04879016 0.04652002 -0.1053605f
logReturns:{[prices]
    .finstat.logI_["logReturns: len=", string count prices];
    .finstat.require_[1 < count prices;
        "logReturns: need at least 2 prices"];
    .finstat.require_[all prices > 0f;
        "logReturns: all prices must be positive for log returns"];
    result: 1_ log prices % prev prices;
    .finstat.logI_["logReturns: computed ", string[count result], " returns"];
    result
 }

// ---------------------------------------------------------------------------
// rollingVol  Annualised rolling historical volatility
// ---------------------------------------------------------------------------

/ @desc   Compute rolling annualised historical volatility from a price series
/         using the standard deviation of log returns scaled by sqrt(annFactor).
//
/             vol[t] = stddev( logReturn[t-window+1 .. t] ) * sqrt(annFactor)
//
/         The first window-1 output values are null (insufficient history).
/ @param  prices    {float list}   Ordered price series (oldest first, all > 0).
/ @param  window    {long}         Rolling window length (must be  2).
/ @param  annFactor {long}         Annualisation factor  number of periods per
/                                  year.  Typical values:
/                                    252  (daily equity)
/                                    52   (weekly)
/                                    12   (monthly)
/ @return           {float list}   Annualised vol series; length = count prices - 1
/                                  (matches logReturns length).
/ @throws           if prices is too short, window < 2, or annFactor < 1.
/ @perf   O(n)  uses q's mdev (moving standard deviation) built-in.
/ @example
/   .finstat.rollingVol[100 102 101 105 104 108f; 3; 252]
rollingVol:{[prices;window;annFactor]
    .finstat.logI_["rollingVol: window=", string[window],
                   " annFactor=", string[annFactor],
                   " len=", string count prices];
    .finstat.require_[1 < count prices;
        "rollingVol: need at least 2 prices"];
    .finstat.require_[window >= 2;
        "rollingVol: window must be >= 2"];
    .finstat.require_[annFactor >= 1;
        "rollingVol: annFactor must be >= 1"];
    r: logReturns prices;
    / Prepend a null so mdev window aligns with the same index as prices
    result: sqrt[annFactor] * mdev[window; 0nf,r];
    .finstat.logI_["rollingVol: computed ", string[count result], " vol values"];
    result
 }

// ---------------------------------------------------------------------------
// vwap  Volume-Weighted Average Price
// ---------------------------------------------------------------------------

/ @desc   Compute the scalar Volume-Weighted Average Price:
/             vwap = sum(price[i] * volume[i]) / sum(volume)
/         Typically applied intraday over a set of trades.
/ @param  prices  {float list}   Trade prices (must be non-empty, same length
/                                as volumes).
/ @param  volumes {long|float list}  Trade volumes (each > 0; negative volumes
/                                raise an error).
/ @return         {float}        VWAP scalar.
/ @throws         if inputs are empty, mismatched lengths, or total volume = 0.
/ @example
/   .finstat.vwap[100 102 101f; 200 150 300]
/   /  101.0667f
vwap:{[prices;volumes]
    .finstat.logI_["vwap: len=", string count prices];
    .finstat.require_[0 < count prices; "vwap: prices list must not be empty"];
    .finstat.require_[(count prices) = count volumes;
        "vwap: prices and volumes must be the same length"];
    .finstat.require_[0 < sum volumes;
        "vwap: total volume must be > 0"];
    .finstat.require_[all volumes >= 0;
        "vwap: volumes must be non-negative"];
    result: (sum prices * `float$volumes) % `float$sum volumes;
    .finstat.logI_["vwap: result=", string result];
    result
 }

// ---------------------------------------------------------------------------
// cumulativeReturn  Total fractional return over the full series
// ---------------------------------------------------------------------------

/ @desc   Compute the total (cumulative) arithmetic return from the first price
/         to the last:
/             cumulativeReturn = (last[prices] - first[prices]) / first[prices]
/ @param  prices {float list}   Ordered price series (oldest first; first > 0).
/ @return        {float}        Fractional total return (e.g. 0.1 = +10%).
/ @throws        if prices has fewer than 2 elements or first price  0.
/ @example
/   .finstat.cumulativeReturn[100 105 110f]
/   /  0.1f
cumulativeReturn:{[prices]
    .finstat.logI_["cumulativeReturn: len=", string count prices];
    .finstat.require_[1 < count prices;
        "cumulativeReturn: need at least 2 prices"];
    .finstat.require_[first[prices] > 0f;
        "cumulativeReturn: first price must be positive"];
    result: (last[prices] - first[prices]) % first[prices];
    .finstat.logI_["cumulativeReturn: result=", string result];
    result
 }

// ---------------------------------------------------------------------------
// sharpe  Annualised Sharpe ratio
// ---------------------------------------------------------------------------

/ @desc   Compute the annualised Sharpe ratio from a series of log returns:
//
/             excess[t]  = return[t] - riskFreeRate / annFactor
/             sharpe     = mean(excess) / stddev(excess) * sqrt(annFactor)
//
/         A Sharpe > 1 is generally considered acceptable; > 2 is strong.
/ @param  returns   {float list}   Period log returns (e.g. from logReturns[]).
/ @param  riskFree  {float}        Annualised risk-free rate as a decimal
/                                  (e.g. 0.05 = 5%).  Pass 0f for a pure
/                                  excess-return Sharpe.
/ @param  annFactor {long}         Periods per year (252 = daily, 52 = weekly,
/                                  12 = monthly).
/ @return           {float}        Annualised Sharpe ratio (null if stddev = 0).
/ @throws           if returns is empty or annFactor < 1.
/ @example
/   .finstat.sharpe[r; 0.04; 252]    / daily returns, 4% risk-free rate
sharpe:{[returns;riskFree;annFactor]
    .finstat.logI_["sharpe: len=", string[count returns],
                   " riskFree=", string[riskFree],
                   " annFactor=", string annFactor];
    .finstat.require_[0 < count returns; "sharpe: returns list must not be empty"];
    .finstat.require_[annFactor >= 1; "sharpe: annFactor must be >= 1"];
    periodRf: riskFree % annFactor;
    excess: returns - periodRf;
    excessStd: dev excess;
    if[excessStd = 0f;
        .finstat.logW_["sharpe: zero standard deviation - returning null"];
        :0nf
    ];
    result: sqrt[`float$annFactor] * avg[excess] % excessStd;
    .finstat.logI_["sharpe: result=", string result];
    result
 }

// ---------------------------------------------------------------------------
// maxDrawdown  Maximum peak-to-trough drawdown
// ---------------------------------------------------------------------------

/ @desc   Compute the maximum peak-to-trough drawdown of a price series.
/         At each point the drawdown is measured as the fractional decline from
/         the running maximum price up to that point:
//
/             drawdown[t] = (price[t] - maxPrice[0..t]) / maxPrice[0..t]
//
/         Returns the minimum (most negative) value of the drawdown series.
/         A return of -0.2 means the series fell 20% from its peak.
/ @param  prices {float list}   Ordered price series (oldest first; all > 0).
/ @return        {float}        Maximum drawdown ( 0); 0 means no drawdown.
/ @throws        if prices is empty or contains non-positive values.
/ @example
/   .finstat.maxDrawdown[100 110 95 105 90f]
/   /  -0.1818182f   (110  90 is an 18.18% decline)
maxDrawdown:{[prices]
    .finstat.logI_["maxDrawdown: len=", string count prices];
    .finstat.require_[0 < count prices; "maxDrawdown: prices list must not be empty"];
    .finstat.require_[all prices > 0f;
        "maxDrawdown: all prices must be positive"];
    runPeak: maxs prices;
    dd: (prices - runPeak) % runPeak;
    result: min dd;
    .finstat.logI_["maxDrawdown: result=", string result];
    result
 }

// ---------------------------------------------------------------------------
// Module load confirmation
// ---------------------------------------------------------------------------

\d .
-1 "[finstat] module loaded - namespace .finstat";
-1 "[finstat] public API: sma ema simpleReturns logReturns rollingVol vwap cumulativeReturn sharpe maxDrawdown";
