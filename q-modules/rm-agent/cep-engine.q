// ============================================================================
// Module:      rm-agent.cep-engine
// Namespace:   .cep
// Description: Complex Event Processing (CEP) engine for the AI Relationship
//              Manager demo. Evaluates 5 market-event rules against live quote,
//              OHLCV and news data and appends alerts to a persistent
//              rmag_events table.
// 
//              Architecture: this process polls the KDB-X DB Service RDB via
//              a configurable timer (.z.ts). For production deployment the poll
//              loop should be replaced with a Reliable-Transport (RT) subscriber
//              so that events are processed as data arrives, not on a schedule.
// 
// Version:     0.1.0
// Requires:    KDB-X 5.0  (uses .z.p, mavg, maxs, protected-eval @[])
// Author:      AI RM Demo
// ============================================================================

\d .cep

// ---------------------------------------------------------------------------
// Internal log helpers
// ---------------------------------------------------------------------------

logI_:{-1 "[cep][INFO]  ", string[.z.p], " ", x}
logW_:{-1 "[cep][WARN]  ", string[.z.p], " ", x}
logE_:{-2 "[cep][ERROR] ", string[.z.p], " ", x}

// ---------------------------------------------------------------------------
// require_ - input guard
// Usage: require_[condition; "descriptive error message"]
// ---------------------------------------------------------------------------

require_:{[cond;msg] if[not cond; logE_ msg; '"cep: ", msg]}

// ---------------------------------------------------------------------------
// Configuration  (override via .cep.cfg before loading)
// ---------------------------------------------------------------------------

cfg:`priceThresh`volMultiplier`newsThresh`drawdownThresh`tickIntervalMs!(
    2.0;    / PRICE_ALERT:    abs changePct >= 2 %
    2.0;    / VOLUME_SPIKE:   volume > 2x 5-period rolling average
    0.5;    / NEWS_ALERT:     abs sentiment >= 0.5
    -0.05;  / DRAWDOWN_ALERT: rolling max drawdown < -5 %
    30000   / timer interval in milliseconds (30 s)
    )

// ---------------------------------------------------------------------------
// Event table - persists alerts for the lifetime of the process
// ---------------------------------------------------------------------------

rmag_events:([]
    evtId:    `long$();
    ts:       `timestamp$();
    sym:      `$();
    evtType:  `$();
    severity: `$();
    val:      `float$();
    thrshVal: `float$();
    msg:      `$()
    )

// ---------------------------------------------------------------------------
// Rule 1 - PRICE_ALERT
// 
// @desc   Fires when |changePct| exceeds threshold on the most recent quote.
// @param  quotes    {table}  rmag_quote rows (cols: ts sym changePct volume)
// @param  threshold {float}  Alert when |changePct| >= this value (e.g. 2.0)
// @return {table}   Zero or more alert rows in rmag_events schema (no evtId).
// ---------------------------------------------------------------------------

priceAlertRule:{[quotes;threshold]
    require_[98h=type quotes;    "priceAlertRule: quotes must be a table"];
    require_[`changePct in cols quotes; "priceAlertRule: missing column changePct"];
    triggered:select from quotes where abs[changePct]>=threshold;
    n:count triggered;
    if[n=0; logI_ "PRICE_ALERT: no triggers"; :()];
    sev:`MEDIUM`HIGH@(abs[triggered`changePct])>=5f;
    logI_ "PRICE_ALERT: ", string[n], " trigger(s)";
    ([]
        evtId:    n#0Nj;
        ts:       triggered`ts;
        sym:      triggered`sym;
        evtType:  n#`PRICE_ALERT;
        severity: sev;
        val:      triggered`changePct;
        thrshVal: n#threshold;
        msg:      `$"changePct: " ,/: string triggered`changePct
        )
    }

// ---------------------------------------------------------------------------
// Rule 2 - VOLUME_SPIKE
// 
// @desc   Fires when the latest volume for a sym exceeds nAvg times the
//         5-period rolling average across all quotes supplied.
// @param  quotes     {table}  rmag_quote rows (cols: ts sym volume)
// @param  nAvg       {float}  Multiplier for the rolling average (e.g. 2.0)
// @return {table}   Zero or more alert rows in rmag_events schema (no evtId).
// ---------------------------------------------------------------------------

volumeSpikeRule:{[quotes;nAvg]
    require_[98h=type quotes;  "volumeSpikeRule: quotes must be a table"];
    require_[`volume in cols quotes; "volumeSpikeRule: missing column volume"];
    withAvg:update rolAvg:mavg[5;volume] by sym from quotes;
    latest:0!(select last ts, last volume, last rolAvg by sym from withAvg);
    triggered:select from latest where volume>"j"$nAvg*rolAvg;
    n:count triggered;
    if[n=0; logI_ "VOLUME_SPIKE: no triggers"; :()];
    logI_ "VOLUME_SPIKE: ", string[n], " trigger(s)";
    ([]
        evtId:    n#0Nj;
        ts:       triggered`ts;
        sym:      triggered`sym;
        evtType:  n#`VOLUME_SPIKE;
        severity: n#`HIGH;
        val:      "f"$triggered`volume;
        thrshVal: triggered[`rolAvg]*nAvg;
        msg:      `$"vol: " ,/: string triggered`volume
        )
    }

// ---------------------------------------------------------------------------
// Rule 3 - MOMENTUM_SIGNAL (golden / death cross)
// 
// @desc   Detects when the 5-day moving average crosses the 20-day moving
//         average for any symbol in the supplied OHLCV table.
//         MOMENTUM_GOLDEN: 5-day crosses above 20-day (bullish).
//         MOMENTUM_DEATH:  5-day crosses below 20-day (bearish).
// @param  ohlcv  {table}  rmag_ohlcv rows (cols: date sym close)
// @return {table} Zero or more alert rows (no evtId).
// ---------------------------------------------------------------------------

momentumRule:{[ohlcv]
    require_[98h=type ohlcv;  "momentumRule: ohlcv must be a table"];
    require_[`close in cols ohlcv; "momentumRule: missing column close"];
    withMA:update ma5:mavg[5;close], ma20:mavg[20;close] by sym from ohlcv;
    n1:count withMA;
    if[n1<2; logW_ "momentumRule: fewer than 2 rows - no cross possible"; :()];
    cur:0!(select last close, last ma5, last ma20 by sym from withMA);
    prv:0!(select last close, last ma5, last ma20 by sym from select from withMA where i<n1-1);
    / golden: was below, now above
    goldenSyms:exec sym from prv where ma5<ma20;
    golden:select from cur where (ma5>=ma20), sym in goldenSyms;
    / death: was above, now below
    deathSyms:exec sym from prv where ma5>ma20;
    death:select from cur where (ma5<=ma20), sym in deathSyms;
    ng:count golden; nd:count death;
    logI_ "MOMENTUM: ", string[ng], " golden, ", string[nd], " death cross(es)";
    evts:();
    if[ng>0;
        evts,:([]
            evtId:    ng#0Nj;
            ts:       ng#.z.p;
            sym:      golden`sym;
            evtType:  ng#`MOMENTUM_GOLDEN;
            severity: ng#`MEDIUM;
            val:      golden`ma5;
            thrshVal: golden`ma20;
            msg:      ng#`$"5d MA crossed above 20d MA"
            )
        ];
    if[nd>0;
        evts,:([]
            evtId:    nd#0Nj;
            ts:       nd#.z.p;
            sym:      death`sym;
            evtType:  nd#`MOMENTUM_DEATH;
            severity: nd#`MEDIUM;
            val:      death`ma5;
            thrshVal: death`ma20;
            msg:      nd#`$"5d MA crossed below 20d MA"
            )
        ];
    evts
    }

// ---------------------------------------------------------------------------
// Rule 4 - DRAWDOWN_ALERT
// 
// @desc   Fires when the rolling max drawdown for a sym falls below threshold.
//         Drawdown is computed as (close - rolling_max_close) / rolling_max_close.
// @param  ohlcv     {table}  rmag_ohlcv rows (cols: date sym close)
// @param  threshold {float}  Alert when drawdown < threshold (e.g. -0.05 for -5%)
// @return {table}   Zero or more alert rows (no evtId).
// ---------------------------------------------------------------------------

drawdownRule:{[ohlcv;threshold]
    require_[98h=type ohlcv;  "drawdownRule: ohlcv must be a table"];
    require_[`close in cols ohlcv; "drawdownRule: missing column close"];
    withDD:update rolMax:maxs close, dd:(close - maxs close) % maxs close by sym from ohlcv;
    latest:0!(select last close, last rolMax, last dd by sym from withDD);
    triggered:select from latest where dd<threshold;
    n:count triggered;
    if[n=0; logI_ "DRAWDOWN_ALERT: no triggers"; :()];
    logI_ "DRAWDOWN_ALERT: ", string[n], " trigger(s)";
    ([]
        evtId:    n#0Nj;
        ts:       n#.z.p;
        sym:      triggered`sym;
        evtType:  n#`DRAWDOWN_ALERT;
        severity: n#`HIGH;
        val:      triggered`dd;
        thrshVal: n#threshold;
        msg:      `$"dd: " ,/: string triggered`dd
        )
    }

// ---------------------------------------------------------------------------
// Rule 5 - NEWS_ALERT
// 
// @desc   Fires when |sentiment| exceeds threshold in the latest news rows.
// @param  news      {table}  rmag_news rows (cols: ts sym sentiment)
// @param  threshold {float}  Alert when |sentiment| >= threshold (e.g. 0.5)
// @return {table}   Zero or more alert rows (no evtId).
// ---------------------------------------------------------------------------

newsAlertRule:{[news;threshold]
    require_[98h=type news;  "newsAlertRule: news must be a table"];
    require_[`sentiment in cols news; "newsAlertRule: missing column sentiment"];
    triggered:select from news where abs[sentiment]>=threshold;
    n:count triggered;
    if[n=0; logI_ "NEWS_ALERT: no triggers"; :()];
    sev:`MEDIUM`HIGH@abs[triggered`sentiment]>=0.8f;
    logI_ "NEWS_ALERT: ", string[n], " trigger(s)";
    ([]
        evtId:    n#0Nj;
        ts:       triggered`ts;
        sym:      triggered`sym;
        evtType:  n#`NEWS_ALERT;
        severity: sev;
        val:      triggered`sentiment;
        thrshVal: n#threshold;
        msg:      `$"sentiment: " ,/: string triggered`sentiment
        )
    }

// ---------------------------------------------------------------------------
// Event log helpers
// ---------------------------------------------------------------------------

// @desc   Append new event rows to rmag_events, assigning sequential IDs.
// @param  newEvts {table}  Alert rows returned by rule functions.
// @return {()} side-effecting - appends to .cep.rmag_events
appendEvents_:{[newEvts]
    if[0=count newEvts; :()];
    baseId:$[0=count rmag_events; 0j; 1+max rmag_events`evtId];
    newEvts:update evtId:baseId+til count newEvts from newEvts;
    if[not `msg in cols newEvts; newEvts:update msg:count[newEvts]#` from newEvts];
    rmag_events,: select evtId,ts,sym,evtType,severity,val,thrshVal,msg from newEvts;
    logI_ "appended ", string[count newEvts], " event(s) - total: ", string count rmag_events
    }

// ---------------------------------------------------------------------------
// Dispatcher - run all rules against supplied data and append results
// 
// @param  quoteData {table}  Latest quotes (rmag_quote subset)
// @param  ohlcvData {table}  OHLCV history (rmag_ohlcv subset)
// @param  newsData  {table}  Recent news (rmag_news subset)
// ---------------------------------------------------------------------------

runRules:{[quoteData;ohlcvData;newsData]
    evts:();
    evts,: .[priceAlertRule;  (quoteData; cfg`priceThresh);   {[e] logE_ "priceAlertRule error: ",e; ()}];
    evts,: .[volumeSpikeRule; (quoteData; cfg`volMultiplier); {[e] logE_ "volumeSpikeRule error: ",e; ()}];
    evts,: .[momentumRule;    enlist ohlcvData;               {[e] logE_ "momentumRule error: ",e; ()}];
    evts,: .[drawdownRule;    (ohlcvData; cfg`drawdownThresh);{[e] logE_ "drawdownRule error: ",e; ()}];
    evts,: .[newsAlertRule;   (newsData;  cfg`newsThresh);    {[e] logE_ "newsAlertRule error: ",e; ()}];
    appendEvents_[evts];
    count evts
    }

// ---------------------------------------------------------------------------
// Query API - called by rm-agent or Python via REST
// ---------------------------------------------------------------------------

// @desc   Return recent events, optionally filtered by symbol and/or type.
// @param  syms     {symbol[]}  Filter by sym list; () = all syms
// @param  evtTypes {symbol[]}  Filter by evtType list; () = all types
// @param  lim      {long}      Maximum rows to return (most recent first)
// @return {table}  rmag_events rows

getEvents:{[syms;evtTypes;lim]
    require_[lim>0; "getEvents: lim must be positive"];
    t:rmag_events;
    if[0<count syms;     t:select from t where sym in syms];
    if[0<count evtTypes; t:select from t where evtType in evtTypes];
    (neg lim) sublist t
    }

// @desc   Return open (recent) alerts within a time window.
// @param  syms       {symbol[]}  Filter by sym; () = all syms
// @param  windowMins {long}      Look-back window in minutes
// @return {table}   rmag_events rows within the window

getOpenAlerts:{[syms;windowMins]
    cutoff:.z.p - `long$windowMins*60*1e9;
    t:select from rmag_events where ts>=cutoff;
    if[0<count syms; t:select from t where sym in syms];
    t
    }

// ---------------------------------------------------------------------------
// Timer-driven polling loop
// ---------------------------------------------------------------------------

// Internal state - track last poll timestamp per data source
lastQuoteTs_:  0Np
lastOhlcvDate_: 0Nd
lastNewsTs_:   0Np

// @desc   Called on each .z.ts tick. Queries DB Service REST API for new data
//         (or in-process tables if running inside the DAP), applies CEP rules.
// 
// PRODUCTION NOTE: Replace this polling approach with an RT subscriber once
// real-time streaming is available. The rule functions are transport-agnostic
// and require no changes when the data source is swapped.
tickHandler_:{[]
    logI_ "CEP tick - polling data sources";
    / In demo mode, rule functions operate on globally-visible tables loaded
    / by the DB Service DAP (rmag_quote, rmag_ohlcv, rmag_news). When running
    / as a standalone process, replace with HTTP GET calls to the DB Service.
    quoteData:$[`rmag_quote in tables[]; rmag_quote; ([]ts:`timestamp$();sym:`$();changePct:`float$();volume:`long$())];
    ohlcvData:$[`rmag_ohlcv in tables[]; rmag_ohlcv; ([]date:`date$();sym:`$();close:`float$())];
    newsData: $[`rmag_news  in tables[]; rmag_news;  ([]ts:`timestamp$();sym:`$();sentiment:`float$())];
    @[runRules; (quoteData;ohlcvData;newsData); {[e] logE_ "CEP runRules error: ",e}];
    }

// Activate timer (only if not already set)
startTimer:{[]
    if[0<system"t"; logW_ "timer already running"; :()];
    interval:"j"$cfg`tickIntervalMs;
    system "t ", string interval;
    logI_ "CEP timer started at ", string[interval], " ms interval"
    }

stopTimer:{[]
    system "t 0";
    logI_ "CEP timer stopped"
    }

// Wire the timer callback
.z.ts:{tickHandler_[]}

\d .

// ---------------------------------------------------------------------------
// Load banner
// ---------------------------------------------------------------------------

-1 "[cep] CEP engine loaded - namespace .cep";
-1 "[cep] Rules: PRICE_ALERT | VOLUME_SPIKE | MOMENTUM_SIGNAL | DRAWDOWN_ALERT | NEWS_ALERT";
-1 "[cep] Call .cep.startTimer[] to activate polling loop";
