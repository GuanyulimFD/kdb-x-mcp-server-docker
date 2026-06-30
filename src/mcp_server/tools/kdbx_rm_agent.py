"""MCP tools for the AI Relationship Manager agent.

Exposes .rmag.* q functions as named MCP tools via the KxSystems DB Service
Gateway REST API (POST /api/v0/query/q on port 8080).

Data ingestion (OHLCV, news) is performed directly by the feeds and the
agent's data_fetch_node via the DB Service imports API — NOT through these
MCP tools.

Tools registered (7)
--------------------
kdbx_rm_compute_metrics      - Compute Sharpe, CAGR, drawdown, vol for a symbol basket
kdbx_rm_equity_curve_data    - Return cumulative return series (charting data)
kdbx_rm_search_news          - Retrieve ranked news from KDB-X for a portfolio
kdbx_rm_query_ohlcv          - Query raw OHLCV bars for a date range
kdbx_rm_query_news           - Query recent news articles (unranked)
kdbx_rm_run_cep              - Run CEP rules against current table state
kdbx_rm_get_alerts           - Return open CEP alerts from the event log

All financial computation is delegated to .rmag.* q functions.
Python here handles only MCP serialisation and error wrapping.
"""
import logging
from typing import Any, Dict, List

from mcp_server.utils.kdbx import _q_rest, _q_syms, _to_rows

logger = logging.getLogger(__name__)


# ── Helpers ──────────────────────────────────────────────────────────────────

def _ok(data: Any, message: str = "") -> Dict[str, Any]:
    r: Dict[str, Any] = {"status": "success", "data": data}
    if message:
        r["message"] = message
    return r


def _err(message: str, details: str = "") -> Dict[str, Any]:
    r: Dict[str, Any] = {"status": "error", "message": message}
    if details:
        r["technical_details"] = details
    return r


# ── Tool implementations ──────────────────────────────────────────────────────

async def _rm_compute_metrics_impl(
    symbols: List[str],
    lookback_days: int,
) -> Dict[str, Any]:
    syms_q = _q_syms(symbols)
    expr = f".rmag.computeMetrics[{syms_q};{lookback_days}]"
    try:
        result = _q_rest(expr)
        logger.info("kdbx_rm_compute_metrics: computed metrics for %s", symbols)
        return _ok(result)
    except Exception as exc:
        logger.error("kdbx_rm_compute_metrics: failed — %s", exc)
        return _err("Metrics computation failed", str(exc))


async def _rm_equity_curve_impl(
    symbols: List[str],
    lookback_days: int,
) -> Dict[str, Any]:
    syms_q = _q_syms(symbols)
    expr = f".rmag.equityCurveData[{syms_q};{lookback_days}]"
    try:
        result = _q_rest(expr)
        rows = _to_rows(result)
        logger.info("kdbx_rm_equity_curve_data: returned %d curve points", len(rows))
        return _ok(rows)
    except Exception as exc:
        logger.error("kdbx_rm_equity_curve_data: failed — %s", exc)
        return _err("Equity curve computation failed", str(exc))


async def _rm_search_news_impl(
    symbols: List[str],
    query: str,
    limit: int,
) -> Dict[str, Any]:
    syms_q = _q_syms(symbols)
    safe_query = query.replace('"', '\\"')
    expr = f'.rmag.searchNews[{syms_q};"{safe_query}";{limit}]'
    try:
        result = _q_rest(expr)
        rows = _to_rows(result)
        logger.info("kdbx_rm_search_news: returned %d articles", len(rows))
        return _ok(rows)
    except Exception as exc:
        logger.error("kdbx_rm_search_news: failed — %s", exc)
        return _err("News search failed", str(exc))


# ── MCP tool registration ─────────────────────────────────────────────────────

def register_tools(mcp_server):
    """Register all RM agent MCP tools with the FastMCP server."""

    @mcp_server.tool()
    async def kdbx_rm_compute_metrics(
        symbols: List[str],
        lookback_days: int = 90,
    ) -> Dict[str, Any]:
        """Compute portfolio performance metrics for a basket of symbols using q analytics.

        Delegates entirely to .rmag.computeMetrics in q — no Python computation.
        Reads from rmag_ohlcv table populated by the feed ingestion pipeline.

        Args:
            symbols:       Ticker symbols to analyse, e.g. ["AAPL", "MSFT", "TSM"]
            lookback_days: Calendar days of history (default 90)

        Returns:
            {status, data: {symbol: {cumulative_return, sharpe_ratio, max_drawdown,
                                     cagr, annualised_volatility}}}
        """
        return await _rm_compute_metrics_impl(symbols, lookback_days)

    @mcp_server.tool()
    async def kdbx_rm_equity_curve_data(
        symbols: List[str],
        lookback_days: int = 90,
    ) -> Dict[str, Any]:
        """Return cumulative return series computed in q for equity curve charting.

        The Python agent renders a chart from these q-computed values.
        All return calculations use .rmag.equityCurveData (q formula).

        Args:
            symbols:       Ticker symbols
            lookback_days: Calendar days

        Returns:
            {status, data: [{date, sym, cum_return_pct}]}
            cum_return_pct: cumulative return (%) rebased to 0 at start of window
        """
        return await _rm_equity_curve_impl(symbols, lookback_days)

    @mcp_server.tool()
    async def kdbx_rm_search_news(
        symbols: List[str],
        query: str = "",
        limit: int = 10,
    ) -> Dict[str, Any]:
        """Retrieve ranked news articles from KDB-X for a portfolio.

        Calls .rmag.searchNews — q applies composite relevance scoring
        (symbol match + recency + sentiment magnitude).

        Args:
            symbols: Ticker symbols to match news against
            query:   Natural language query string
            limit:   Maximum articles to return (default 10)

        Returns:
            {status, data: [{title, url, source, published, summary,
                             sentiment, sent_label, syms}]}
        """
        return await _rm_search_news_impl(symbols, query, limit)

    @mcp_server.tool()
    async def kdbx_rm_query_ohlcv(
        symbols: List[str],
        start_date: str,
        end_date: str,
    ) -> Dict[str, Any]:
        """Query OHLCV bars from KDB-X for a symbol basket over a date range.

        Returns raw price data for the requested symbols and date window.

        Args:
            symbols:    Tickers to include, e.g. ["AAPL", "MSFT"]. Empty = all symbols.
            start_date: Start date inclusive, ISO format "YYYY-MM-DD"
            end_date:   End date inclusive, ISO format "YYYY-MM-DD"

        Returns:
            {status, data: [{date, sym, open, high, low, close, vol}]}
        """
        syms_q = _q_syms(symbols)
        expr = f'.rmag.queryOhlcv[{syms_q};"{start_date}";"{end_date}"]'
        try:
            result = _q_rest(expr)
            rows = _to_rows(result)
            logger.info("kdbx_rm_query_ohlcv: returned %d rows", len(rows))
            return _ok(rows)
        except Exception as exc:
            logger.error("kdbx_rm_query_ohlcv: failed — %s", exc)
            return _err("OHLCV query failed", str(exc))

    @mcp_server.tool()
    async def kdbx_rm_query_news(
        symbols: List[str],
        limit: int = 20,
    ) -> Dict[str, Any]:
        """Query recent news articles from KDB-X for a symbol basket.

        Returns structured news data — newest first, no ranking applied.
        For LLM-relevant ranked results use kdbx_rm_search_news instead.

        Args:
            symbols: Tickers to filter, e.g. ["AAPL"]. Empty = all symbols.
            limit:   Maximum articles to return (default 20)

        Returns:
            {status, data: [{ts, sym, title, url, source, sentiment, sentLabel}]}
        """
        syms_q = _q_syms(symbols)
        expr = f".rmag.queryNews[{syms_q};{limit}]"
        try:
            result = _q_rest(expr)
            rows = _to_rows(result)
            logger.info("kdbx_rm_query_news: returned %d articles", len(rows))
            return _ok(rows)
        except Exception as exc:
            logger.error("kdbx_rm_query_news: failed — %s", exc)
            return _err("News query failed", str(exc))

    @mcp_server.tool()
    async def kdbx_rm_run_cep() -> Dict[str, Any]:
        """Run all CEP rules against current in-memory table state.

        Evaluates all 5 rules (PRICE_ALERT, VOLUME_SPIKE, MOMENTUM_SIGNAL,
        DRAWDOWN_ALERT, NEWS_ALERT) and appends any new alerts to the event log.

        Call this after an ingestion cycle to trigger alert detection.
        New alerts are retrievable via kdbx_rm_get_alerts.

        Returns:
            {status, data: {events_fired: N}}
        """
        try:
            result = _q_rest(".rmag.runCep[]")
            n = result if isinstance(result, int) else 0
            logger.info("kdbx_rm_run_cep: %s new events fired", n)
            return _ok({"events_fired": n})
        except Exception as exc:
            logger.error("kdbx_rm_run_cep: failed — %s", exc)
            return _err("CEP evaluation failed", str(exc))

    @mcp_server.tool()
    async def kdbx_rm_get_alerts(
        symbols: List[str],
        window_minutes: int = 60,
    ) -> Dict[str, Any]:
        """Return open CEP alerts fired within the last N minutes.

        Use this to check for recent market events after a CEP run.
        In the trigger flow: ingest → kdbx_rm_run_cep → kdbx_rm_get_alerts
        → if alerts exist, spawn agent research run.

        Args:
            symbols:        Filter by ticker. Empty = all symbols.
            window_minutes: Lookback window in minutes (default 60)

        Returns:
            {status, data: [{evtId, ts, sym, evtType, severity, val, thrshVal, msg}]}
        """
        syms_q = _q_syms(symbols)
        expr = f".rmag.getOpenAlerts[{syms_q};{window_minutes}]"
        try:
            result = _q_rest(expr)
            rows = _to_rows(result)
            logger.info("kdbx_rm_get_alerts: returned %d open alerts", len(rows))
            return _ok(rows)
        except Exception as exc:
            logger.error("kdbx_rm_get_alerts: failed — %s", exc)
            return _err("Alert query failed", str(exc))

    logger.info("kdbx_rm_agent: registered 7 RM agent tools")
    return [
        "kdbx_rm_compute_metrics",
        "kdbx_rm_equity_curve_data",
        "kdbx_rm_search_news",
        "kdbx_rm_query_ohlcv",
        "kdbx_rm_query_news",
        "kdbx_rm_run_cep",
        "kdbx_rm_get_alerts",
    ]
