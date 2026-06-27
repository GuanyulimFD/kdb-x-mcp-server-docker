// ============================================================================
// Module:      rm-agent
// Namespace:   .rmag
// Description: AI Relationship Manager analytics module.
//
//              DATA ARCHITECTURE — KDB-X DB Service
//              ─────────────────────────────────────
//              AlphaVantage Poller (Python)
//                  │  polls REST API at configurable intervals
//                  ▼
//              rtpy.rt_helper.insert(h, table, rows)
//                  │  Reliable Transport (RT) — port 5002
//                  ▼
//              DB Service Storage Manager (SM)
//                  ├─ RDB  (in-memory — today's data)         DAP RDB port 5010
//                  ├─ IDB  (intraday writedown — SM managed)
//                  └─ HDB  (on-disk, partitioned by date)     DAP HDB port 5011
//
//              Tables (schema defined in DB Service, owned by SM):
//                  rmag_ohlcv      — daily OHLCV bars (date, sym, open/high/low/close/vol)
//                  rmag_quote      — live quotes      (ts, sym, price, change, volume)
//                  rmag_intraday   — 1-min bars       (ts, sym, open/high/low/close/vol)
//                  rmag_news       — news + sentiment (ts, sym, title, summary, sentiment)
//
//              ANALYTICS (all in q — loaded into DB Service DAP at startup)
//              ─────────────────────────────────────────────────────────────
//              Python calls these via POST /api/v0/query/q from DB Service REST API.
//              The DB Service Gateway routes the query to the correct DAP tier and
//              automatically aggregates results across RDB + IDB + HDB.
//
//              .rmag.computeMetrics   — Sharpe, CAGR, max drawdown, ann. vol
//              .rmag.equityCurveData  — cumulative return series for charting
//              .rmag.searchNews       — composite relevance ranking
//
//              DEPLOYMENT
//              ──────────
//              Clone github.com/KxSystems/kdbx-db-service and add this file
//              to the DAP startup configuration (e.g. via KDBX_INIT_SCRIPT env var
//              or by referencing it in the docker-compose .env).
//
// Version:     0.3.0
// Requires:    KDB-X DB Service (preview) + KDB-X 5.0
// Author:      kdb-ai-demo-agent
// ============================================================================

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
    require_[0<count rmag_ohlcv; `"computeMetrics: no OHLCV data — run the feed poller first"];
    logI_ "computeMetrics: ",(" " sv string syms)," lookback=",string lookbackDays;

    cutoff: .z.d - lookbackDays;
    ann:    252f;

    calcOne_:{[sym;cutoff;ann]
        prices: exec close from rmag_ohlcv where sym=sym, date>=cutoff;
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
    require_[0<count rmag_ohlcv; `"equityCurveData: no OHLCV data available"];
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

// ── Module load banner ───────────────────────────────────────────────────────

\d .
-1 "[rmag] v0.3.0 loaded — DB Service analytics module";
-1 "[rmag] Analytics : .rmag.computeMetrics | .rmag.equityCurveData | .rmag.searchNews";
-1 "[rmag] Data tier : rmag_ohlcv | rmag_news | rmag_quote | rmag_intraday (owned by DB Service SM)";
-1 "[rmag] Interface : query via POST /api/v0/query/q on DB Service Gateway";

