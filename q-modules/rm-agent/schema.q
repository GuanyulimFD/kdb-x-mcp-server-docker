// ============================================================================
// Module:      rm-agent/schema
// Namespace:   .rmagschema (schema registration helpers)
// Description: Table schema definitions for the AI-RM demo.
//
//              Tables are OWNED by the DB Service Storage Manager (SM).
//              This file defines empty prototype tables that can be used to:
//                 1. Register schemas in a fresh DB Service instance
//                 2. Seed empty globals for unit testing
//                 3. Document the authoritative column layout
//
//              DEPLOYMENT
//              ──────────
//              Load once during DB Service initialisation via KDBX_INIT_SCRIPT
//              or include in the DAP startup configuration.
//              The SM will take ownership; do NOT modify tables after handoff.
//
// Version:     0.1.0
// Requires:    KDB-X 5.0
// Author:      kdb-ai-demo-agent
// ============================================================================

\d .rmagschema

// ── Internal log helpers ────────────────────────────────────────────────────

logI_:{-1 "[rmagschema][INFO]  ",string[.z.p]," ",x;}
logE_:{-2 "[rmagschema][ERROR] ",string[.z.p]," ",x;}

// ── Schema prototypes ────────────────────────────────────────────────────────

// @desc  Daily OHLCV price bars.
//        Primary time column: date (partition column in HDB).
//        Partitioned by date in HDB; appended intraday via RDB.
rmag_ohlcv:([]date:`date$();sym:`$();open:`float$();high:`float$();low:`float$();close:`float$();vol:`long$())

// @desc  Live quote snapshot from the feed poller.
//        Primary time column: ts (nanosecond timestamp).
//        Written to RDB via RT; flushed to IDB/HDB by SM.
rmag_quote:([]ts:`timestamp$();sym:`$();price:`float$();change:`float$();changePct:`float$();volume:`long$();high:`float$();low:`float$();open:`float$())

// @desc  1-minute intraday OHLCV bars derived from quote ticks.
//        Rolled up by the SM writedown process from rmag_quote.
rmag_intraday:([]ts:`timestamp$();sym:`$();open:`float$();high:`float$();low:`float$();close:`float$();vol:`long$())

// @desc  News articles with NLP sentiment scores.
//        Ingested from AlphaVantage News Sentiment API.
rmag_news:([]ts:`timestamp$();sym:`$();title:`$();url:`$();source:`$();published:`$();summary:`$();sentiment:`float$();sentLabel:`$())

// @desc  CEP event log.
//        Written by .cep.appendEvents_ during rule evaluation.
//        Read by .rmag.getEvents / .cep.getEvents.
rmag_events:([]evtId:`long$();ts:`timestamp$();sym:`$();evtType:`$();severity:`$();val:`float$();thrshVal:`float$();msg:`$())

// ── Column documentation ─────────────────────────────────────────────────────
//
// rmag_ohlcv:
//   date      (date)       partition column; also used for HDB directory
//   sym       (symbol)     ticker symbol e.g. `AAPL
//   open      (float)      opening price
//   high      (float)      session high
//   low       (float)      session low
//   close     (float)      closing price
//   vol       (long)       traded volume in shares
//
// rmag_quote:
//   ts        (timestamp)  nanosecond event time
//   sym       (symbol)     ticker symbol
//   price     (float)      last traded price
//   change    (float)      price change from previous close
//   changePct (float)      percent change from previous close
//   volume    (long)       cumulative day volume
//   high      (float)      session high at time of snapshot
//   low       (float)      session low at time of snapshot
//   open      (float)      session open
//
// rmag_intraday:
//   ts        (timestamp)  bar open time (nanosecond)
//   sym       (symbol)     ticker symbol
//   open/high/low/close (float) 1-minute OHLC
//   vol       (long)       volume in bar
//
// rmag_news:
//   ts        (timestamp)  article publication time (nanosecond)
//   sym       (symbol)     primary ticker symbol
//   title     (symbol)     article headline
//   url       (symbol)     source URL
//   source    (symbol)     news source name e.g. `Reuters
//   published (symbol)     ISO date string from provider
//   summary   (symbol)     article summary / lead paragraph
//   sentiment (float)      NLP sentiment score in [-1.0, 1.0]
//   sentLabel (symbol)     human-readable label: Positive | Negative | Neutral
//
// rmag_events:
//   evtId     (long)       sequential event ID (auto-assigned by appendEvents_)
//   ts        (timestamp)  event fire time (nanosecond)
//   sym       (symbol)     ticker that triggered the event
//   evtType   (symbol)     PRICE_ALERT | VOLUME_SPIKE | MOMENTUM_SIGNAL | DRAWDOWN_ALERT | NEWS_ALERT
//   severity  (symbol)     HIGH | MEDIUM | LOW
//   val       (float)      observed metric value (changePct, volume, drawdown, sentiment)
//   thrshVal  (float)      threshold that was breached
//   msg       (symbol)     human-readable event description

// ── Registration helper ───────────────────────────────────────────────────────

// @desc  Register all RM-agent table schemas globally.
//        Call once from the DAP init script so the SM can bind the tables.
//        Idempotent: skips tables that already exist.
// @example .rmagschema.register[]
register:{[]
    tbls:`rmag_ohlcv`rmag_quote`rmag_intraday`rmag_news`rmag_events;
    protos:(rmag_ohlcv;rmag_quote;rmag_intraday;rmag_news;rmag_events);
    {[tbl;proto]
        if[tbl in tables[];
            logI_ string[tbl]," already registered - skipping";
            :()
            ];
        tbl set proto;
        logI_ "registered schema: ",string tbl
        } ./: flip(tbls;protos);
    logI_ "register: done - ",string[count tbls]," table schemas ready"
    }

// ── Module load banner ───────────────────────────────────────────────────────

\d .
-1 "[rmagschema] v0.1.0 loaded - RM-agent DB schema definitions";
-1 "[rmagschema] Tables: rmag_ohlcv | rmag_quote | rmag_intraday | rmag_news | rmag_events";
-1 "[rmagschema] Call .rmagschema.register[] to bind schemas into the SM namespace";

