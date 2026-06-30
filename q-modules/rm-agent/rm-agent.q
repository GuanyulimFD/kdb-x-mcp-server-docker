// ============================================================================
// Module:      rm-agent
// Namespace:   .rmag
// Description: AI Relationship Manager — KDB-X data platform module.
//
//              DATA ARCHITECTURE — Standalone KDB-X (MCP server mode)
//              ─────────────────────────────────────────────────────────
//              Python Feed Services  (PyKX IPC — port 5001)
//                  ingest_ohlcv.py  — asyncio timer, AlphaVantage → rmag_ohlcv
//                  ingest_news.py   — news source (REST/WebSocket) → rmag_news
//
//              Tables (owned by this module in standalone mode):
//                  rmag_ohlcv      — daily OHLCV bars (date, sym, open/high/low/close/vol)
//                  rmag_quote      — live quote snapshot (ts, sym, price, changePct, volume)
//                  rmag_intraday   — 1-min bars  (ts, sym, open/high/low/close/vol)
//                  rmag_news       — news + sentiment (ts, sym, title, url, sentiment)
//
//              MODULES
//              ───────
//              Ingestion  : .rmag.ingestOhlcv | .rmag.ingestNews
//              Analytics  : .rmag.computeMetrics | .rmag.equityCurveData
//              Query      : .rmag.queryOhlcv | .rmag.queryNews | .rmag.searchNews
//              CEP        : .rmag.runCep | .rmag.getEvents | .rmag.getOpenAlerts
//
//              Python MCP tools call these via pykx.SyncQConnection (port 5001).
//              See src/mcp_server/tools/kdbx_rm_agent.py for MCP registrations.
//
// Version:     0.5.0
// Requires:    KDB-X 5.0
// Author:      kdb-ai-demo-agent
// ============================================================================

// ── Standalone mode: initialise tables in .rmag namespace ────────────────────
// Tables live in .rmag namespace so all functions in that namespace find them
// via direct local lookup. Variable-based operations (,:) respect namespace;
// symbol-based upsert (`name) is AVOIDED in favour of direct append.
//
// In DB Service mode the SM owns the tables — the `if not` guards prevent
// overwriting SM-managed tables (which land in the same .rmag namespace).

if[not `rmag_ohlcv in key `.rmag;
    .rmag.rmag_ohlcv:([]date:`date$();sym:`$();open:`float$();high:`float$();low:`float$();close:`float$();vol:`long$())]

if[not `rmag_quote in key `.rmag;
    .rmag.rmag_quote:([]ts:`timestamp$();sym:`$();price:`float$();change:`float$();changePct:`float$();volume:`long$();high:`float$();low:`float$();open:`float$())]

if[not `rmag_intraday in key `.rmag;
    .rmag.rmag_intraday:([]ts:`timestamp$();sym:`$();open:`float$();high:`float$();low:`float$();close:`float$();vol:`long$())]

if[not `rmag_news in key `.rmag;
    .rmag.rmag_news:([]ts:`timestamp$();sym:`$();title:`$();url:`$();source:`$();published:`$();summary:`$();sentiment:`float$();sentLabel:`$())]

// ── Load CEP engine if not already present ──────────────────────────────────
// kdbx_init.q loads only <dir>/<dir>.q; cep-engine.q is loaded explicitly here.

if[not `.cep in key `.; system "l q-modules/rm-agent/cep-engine.q"]

\d .rmag

// ── Internal log helpers ────────────────────────────────────────────────────

logI_:{-1 "[rmag][INFO]  ",string[.z.p]," ",x;}
logW_:{-1 "[rmag][WARN]  ",string[.z.p]," ",x;}
logE_:{-2 "[rmag][ERROR] ",string[.z.p]," ",x;}

require_:{[cond;msg] if[not cond; logE_ string msg; 'msg]}

// ── Performance analytics (all formulas in q) ────────────────────────────────
// These functions run inside the DB Service DAP process and have direct access
// to rmag_ohlcv, rmag_news, etc. managed by the DB Service Storage Manager.
// Python calls them via POST /api/v0/query/q — no pykx IPC needed.

/ @desc  Compute per-symbol performance metrics over the most recent N calendar days.
/        Reads closes from rmag_ohlcv across all tiers (RDB + IDB + HDB).
/        Sharpe uses 252-day annualisation convention. Risk-free rate = 0.
/ @param syms        {symbol[]} Ticker symbols to analyse
/ @param lookbackDays {long}    Calendar days of history (e.g. 90)
/ @return {dict}  symbol → {cumulative_return, sharpe_ratio, max_drawdown,
/                            cagr, annualised_volatility}
/ @throws if rmag_ohlcv table is empty
/ @example .rmag.computeMetrics[`AAPL`MSFT`TSM; 90]
computeMetrics:{[syms;lookbackDays]
    require_[0<count rmag_ohlcv; `$"computeMetrics: no OHLCV data - run the feed poller first"];
    logI_ "computeMetrics: ",(" " sv string syms)," lookback=",string lookbackDays;

    cutoff: .z.d - lookbackDays;
    ann:    252f;

    calcOne_:{[s;cutoff;ann]
        prices: exec close from rmag_ohlcv where sym=s, date>=cutoff;
        prices: prices where not null prices;
        if[2>count prices; :()];

        rets:  1_deltas log prices;
        n:     count rets;
        if[0=n; :()];

        mu:    avg rets;
        sigma: dev rets;

        cumRet:  (last prices % first prices) - 1f;
        sharpe:  $[sigma>0f; mu%sigma*sqrt ann; 0f];
        annVol:  sigma * sqrt ann;
        peaks:   maxs prices;
        mdd:     min (prices-peaks)%peaks;
        nYears:  n%ann;
        cagr:    $[nYears>0f; ((last prices%first prices)xexp(1%nYears))-1f; 0f];

        (`cumulative_return`sharpe_ratio`max_drawdown`cagr`annualised_volatility)!
        (cumRet; sharpe; mdd; cagr; annVol)
        };

    result: syms ! calcOne_[;cutoff;ann] each syms;
    result: result where 0<count each result;
    logI_ "computeMetrics: computed ",string[count result]," of ",string[count syms]," symbols";
    result
    }

/ @desc  Return cumulative return series for equity curve charting.
/        Python renders a matplotlib chart from these q-computed values.
/ @param syms        {symbol[]} Ticker symbols
/ @param lookbackDays {long}    Calendar days
/ @return {table}  (date; sym; cum_return_pct) — rebased to 0% at start of window
/ @throws if rmag_ohlcv table is empty
/ @example .rmag.equityCurveData[`AAPL`MSFT; 90]
equityCurveData:{[syms;lookbackDays]
    require_[0<count rmag_ohlcv; `$"equityCurveData: no OHLCV data available"];
    logI_ "equityCurveData: ",(" " sv string syms);

    cutoff: .z.d - lookbackDays;

    buildCurve_:{[sym;cutoff]
        t: `date xasc select date, close from rmag_ohlcv where sym=sym, date>=cutoff;
        if[0=count t; :()];
        firstClose: first t`close;
        if[0f=firstClose; :()];
        update sym:sym, cum_return_pct:100f*(close%firstClose)-1f from t
        };

    curves: raze buildCurve_[;cutoff] each syms;
    if[0=count curves;
        :enlist([]date:`date$();sym:`$();cum_return_pct:`float$())];
    select date, sym, cum_return_pct from curves
    }

/ @desc  Rank and retrieve relevant news from rmag_news.
/        Composite score: 0.5*symbolMatch + 0.2*|sentiment|
/        (recency already handled by DB Service time-range query)
/ @param syms   {symbol[]} Portfolio symbols to match
/ @param query  {symbol}   Natural language query hint (reserved for KDB.AI path)
/ @param limit  {long}     Maximum articles to return
/ @return {table} Top N articles sorted by composite relevance score
/ @example .rmag.searchNews[`AAPL`MSFT; `""; 10]
searchNews:{[syms;query;limit]
    if[0=count rmag_news;
        logW_ "searchNews: rmag_news is empty — returning empty result";
        :([]title:`$();url:`$();source:`$();published:`$();
            summary:`$();sentiment:`float$();sent_label:`$();syms:`$())];

    logI_ "searchNews: ranking for ",(" " sv string syms)," limit=",string limit;

    scoreOne_:{[row;symSet]
        artSyms: `$"|" vs string row`syms;
        symScore: (count artSyms inter symSet) % count symSet;
        composite: (0.5*symScore) + (0.2*abs row`sentiment);
        composite
        };

    scores: scoreOne_[;syms] each rmag_news;
    ranked: `score xdesc update score:scores from rmag_news;
    limit # delete score from ranked
    }

// ── Ingestion (called by Python feed services via PyKX IPC) ─────────────────

/ @desc  Append daily OHLCV rows into rmag_ohlcv.
/        Called by ingest_ohlcv.py after each AlphaVantage poll cycle.
/ @param dates   {date[]}   Trading dates
/ @param syms    {symbol[]} Ticker symbols
/ @param opens   {float[]}  Opening prices
/ @param highs   {float[]}  Session highs
/ @param lows    {float[]}  Session lows
/ @param closes  {float[]}  Closing prices
/ @param volumes {long[]}   Traded volumes
/ @return {long} Row count appended
/ @example .rmag.ingestOhlcv[2024.01.15 2024.01.15; `AAPL`MSFT; 182.0 370.0; 185.0 375.0; 181.0 368.0; 184.0 373.0; 1000000j 500000j]
ingestOhlcv:{[dates;syms;opens;highs;lows;closes;volumes]
    rows:([]date:dates;sym:syms;open:opens;high:highs;low:lows;close:closes;vol:volumes);
    n:count rows;
    require_[0<n; `$"ingestOhlcv: no rows to insert"];
    rmag_ohlcv,:rows;
    logI_ "ingestOhlcv: appended ",string[n]," rows (total: ",string[count rmag_ohlcv],")";
    n
    }

/ @desc  Append news articles into rmag_news.
/        Called by ingest_news.py after each poll or WebSocket batch.
/ @param titles    {symbol[]} Article headlines
/ @param urls      {symbol[]} Source URLs
/ @param sources   {symbol[]} Publisher names
/ @param published {symbol[]} Publication timestamps (ISO string from provider)
/ @param summaries {symbol[]} Article lead paragraphs
/ @param scores    {float[]}  NLP sentiment in [-1.0, 1.0]
/ @param labels    {symbol[]} Sentiment labels (Positive|Neutral|Negative)
/ @param symStrs   {symbol[]} Primary ticker as symbol (one per article)
/ @return {long} Article count appended
/ @example .rmag.ingestNews[(`$enlist "Headline"); (`$enlist "https://..."); (`$enlist "Reuters"); (`$enlist "2024-01-15"); (`$enlist "Summary"); enlist 0.6; (`$enlist "Positive"); (`$enlist "AAPL")]
ingestNews:{[titles;urls;sources;published;summaries;scores;labels;symStrs]
    n:count titles;
    require_[0<n; `$"ingestNews: no articles to insert"];
    rows:([]ts:n#.z.p;sym:`$symStrs;title:`$titles;url:`$urls;
           source:`$sources;published:`$published;summary:`$summaries;
           sentiment:scores;sentLabel:`$labels);
    rmag_news,:rows;
    logI_ "ingestNews: appended ",string[n]," articles (total: ",string[count rmag_news],")";
    n
    }

// ── Structured queries (API-driven — called by Python MCP query tools) ───────

/ @desc  Query OHLCV bars for a symbol basket over a date range.
/        Returns all symbols when syms is empty.
/ @param syms      {symbol[]} Tickers; () = all symbols
/ @param startDate {date}     Start date (inclusive)
/ @param endDate   {date}     End date (inclusive)
/ @return {table} Columns: date sym open high low close vol; sorted by date asc, sym asc
/ @example .rmag.queryOhlcv[`AAPL`MSFT; 2024.01.01; 2024.03.31]
queryOhlcv:{[syms;startDate;endDate]
    if[0=count rmag_ohlcv;
        logW_ "queryOhlcv: rmag_ohlcv is empty — ingest data first";
        :([]date:`date$();sym:`$();open:`float$();high:`float$();low:`float$();close:`float$();vol:`long$())];
    logI_ "queryOhlcv: syms=",($[0=count syms;"*";" " sv string syms])," ",string[startDate]," to ",string[endDate];
    q:$[0=count syms;
        select date,sym,open,high,low,close,vol from rmag_ohlcv where date within (startDate;endDate);
        select date,sym,open,high,low,close,vol from rmag_ohlcv where sym in syms, date within (startDate;endDate)
    ];
    `date`sym xasc q
    }

/ @desc  Query recent news articles for a symbol basket, newest first.
/        Returns all symbols when syms is empty.
/ @param syms  {symbol[]} Tickers; () = all symbols
/ @param limit {long}     Maximum articles to return
/ @return {table} Columns: ts sym title url source sentiment sentLabel; newest first
/ @example .rmag.queryNews[`AAPL; 20]
queryNews:{[syms;limit]
    if[0=count rmag_news;
        logW_ "queryNews: rmag_news is empty — ingest news first";
        :([]ts:`timestamp$();sym:`$();title:`$();url:`$();source:`$();sentiment:`float$();sentLabel:`$())];
    logI_ "queryNews: syms=",($[0=count syms;"*";" " sv string syms])," limit=",string limit;
    q:$[0=count syms;
        select ts,sym,title,url,source,sentiment,sentLabel from rmag_news;
        select ts,sym,title,url,source,sentiment,sentLabel from rmag_news where sym in syms
    ];
    limit # `ts xdesc q
    }

// ── CEP runner (pipes current table state through cep-engine rules) ──────────

/ @desc  Run all CEP rules against the current in-memory table state.
/        Alerts are appended to .cep.rmag_events.
/        Call this after each ingestion cycle or from a scheduled timer.
/ @return {long} Total new events fired across all 5 rules
/ @example .rmag.runCep[]
runCep:{
    require_[0<count key `.cep; `$"runCep: cep-engine.q not loaded"];
    qData:$[0<count rmag_quote;
        select from rmag_quote;
        ([]ts:`timestamp$();sym:`$();changePct:`float$();volume:`long$())];
    oData:$[0<count rmag_ohlcv;
        select from rmag_ohlcv;
        ([]date:`date$();sym:`$();close:`float$())];
    nData:$[0<count rmag_news;
        select from rmag_news;
        ([]ts:`timestamp$();sym:`$();sentiment:`float$())];
    n:.cep.runRules[qData;oData;nData];
    logI_ "runCep: ",string[n]," new event(s) fired";
    n
    }

// ── CEP event log API (delegates to .cep.* — requires cep-engine.q loaded) ──

// @desc  Query the CEP event log with optional sym/evtType filters and row limit.
//        Delegates to .cep.getEvents. Requires cep-engine.q to be loaded.
// @param syms     {symbol[]} Filter by sym; pass () for all symbols
// @param evtTypes {symbol[]} Filter by evtType; pass () for all types
// @param lim      {long}     Maximum rows to return (must be > 0)
// @return {table} Event log rows (evtId, ts, sym, evtType, severity, val, thrshVal, msg)
// @example .rmag.getEvents[`AAPL`MSFT; enlist `PRICE_ALERT; 50]
getEvents:{[syms;evtTypes;lim]
    require_[0<count key `.cep; `$"getEvents: cep-engine.q not loaded - load cep-engine.q first"];
    .cep.getEvents[syms;evtTypes;lim]
    }

// @desc  Return events fired within the last windowMins minutes (open alerts).
//        Delegates to .cep.getOpenAlerts. Requires cep-engine.q to be loaded.
// @param syms       {symbol[]} Filter by sym; pass () for all symbols
// @param windowMins {long}     Lookback window in minutes
// @return {table} Recent event rows sorted descending by ts
// @example .rmag.getOpenAlerts[`AAPL; 60]
getOpenAlerts:{[syms;windowMins]
    require_[0<count key `.cep; `$"getOpenAlerts: cep-engine.q not loaded - load cep-engine.q first"];
    .cep.getOpenAlerts[syms;windowMins]
    }

// ── Module load banner ───────────────────────────────────────────────────────

\d .
-1 "[rmag] v0.5.0 loaded — standalone KDB-X analytics module";
-1 "[rmag] Ingest    : .rmag.ingestOhlcv | .rmag.ingestNews";
-1 "[rmag] Analytics : .rmag.computeMetrics | .rmag.equityCurveData";
-1 "[rmag] Query     : .rmag.queryOhlcv | .rmag.queryNews | .rmag.searchNews";
-1 "[rmag] CEP       : .rmag.runCep | .rmag.getEvents | .rmag.getOpenAlerts";
-1 "[rmag] Tables    : rmag_ohlcv | rmag_quote | rmag_intraday | rmag_news (in-memory)";

