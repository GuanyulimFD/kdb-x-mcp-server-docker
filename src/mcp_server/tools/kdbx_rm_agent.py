"""MCP tools for the AI Relationship Manager agent.

These tools expose the q/.rmag.* functions as named MCP tools,
callable by the kdb-ai-demo-agent via pykx IPC.

Tools registered
----------------
kdbx_rm_ingest_ohlcv         - Bulk-insert OHLCV records into KDB-X
kdbx_rm_ingest_news          - Store news articles in KDB-X (+ KDB.AI embeddings)
kdbx_rm_compute_metrics      - Compute Sharpe, CAGR, drawdown, vol for a symbol basket
kdbx_rm_equity_curve_data    - Return cumulative return series (charting data)
kdbx_rm_search_news          - Retrieve ranked news from KDB-X for a portfolio

All financial computation is delegated to .rmag.* q functions.
Python here handles only MCP serialisation and error wrapping.
"""
import logging
from typing import Any, Dict, List

from mcp_server.utils.kdbx import get_kdb_connection

logger = logging.getLogger(__name__)


# ── Helpers ──────────────────────────────────────────────────────────────────

def _q(expr: str, *args):
    """Execute a q expression and return the Python-converted result."""
    conn = get_kdb_connection()
    try:
        result = conn(expr, *args) if args else conn(expr)
        return result.py() if hasattr(result, "py") else result
    except Exception as exc:
        raise RuntimeError(f"q call failed: {expr[:80]!r} — {exc}") from exc


def _ok(data: Any, message: str = "") -> Dict[str, Any]:
    r = {"status": "success", "data": data}
    if message:
        r["message"] = message
    return r


def _err(message: str, details: str = "") -> Dict[str, Any]:
    r = {"status": "error", "message": message}
    if details:
        r["technical_details"] = details
    return r


# ── Tool implementations ──────────────────────────────────────────────────────

async def _rm_ingest_ohlcv_impl(records: List[Dict[str, Any]]) -> Dict[str, Any]:
    """Core logic for kdbx_rm_ingest_ohlcv."""
    if not records:
        return _ok({"inserted_count": 0}, "No records provided")

    dates   = [r["date"]   for r in records]
    syms    = [r["sym"]    for r in records]
    opens   = [r["open"]   for r in records]
    highs   = [r["high"]   for r in records]
    lows    = [r["low"]    for r in records]
    closes  = [r["close"]  for r in records]
    volumes = [r["volume"] for r in records]

    try:
        n = _q(".rmag.ingestOhlcv", dates, syms, opens, highs, lows, closes, volumes)
        logger.info("kdbx_rm_ingest_ohlcv: inserted %d records", n)
        return _ok({"inserted_count": int(n)})
    except Exception as exc:
        logger.error("kdbx_rm_ingest_ohlcv: failed — %s", exc)
        return _err("OHLCV ingestion failed", str(exc))


async def _rm_ingest_news_impl(articles: List[Dict[str, Any]]) -> Dict[str, Any]:
    """Core logic for kdbx_rm_ingest_news."""
    if not articles:
        return _ok({"inserted_count": 0}, "No articles provided")

    titles    = [a.get("title", "")    for a in articles]
    urls      = [a.get("url", "")      for a in articles]
    sources   = [a.get("source", "")   for a in articles]
    published = [a.get("time_published", "") for a in articles]
    summaries = [a.get("summary", "")  for a in articles]
    scores    = [float(a.get("sentiment_score", 0)) for a in articles]
    labels    = [a.get("sentiment_label", "Neutral") for a in articles]
    sym_strs  = ["|".join(a.get("relevant_symbols") or []) for a in articles]

    try:
        n = _q(".rmag.ingestNews", titles, urls, sources, published,
               summaries, scores, labels, sym_strs)
        logger.info("kdbx_rm_ingest_news: stored %d articles", n)
        return _ok({"inserted_count": int(n)})
    except Exception as exc:
        logger.error("kdbx_rm_ingest_news: failed — %s", exc)
        return _err("News ingestion failed", str(exc))


async def _rm_compute_metrics_impl(
    symbols: List[str],
    lookback_days: int,
) -> Dict[str, Any]:
    """Core logic for kdbx_rm_compute_metrics."""
    try:
        result = _q(".rmag.computeMetrics", [s.upper() for s in symbols], lookback_days)
        logger.info("kdbx_rm_compute_metrics: computed metrics for %s", symbols)
        return _ok(result)
    except Exception as exc:
        logger.error("kdbx_rm_compute_metrics: failed — %s", exc)
        return _err("Metrics computation failed", str(exc))


async def _rm_equity_curve_impl(
    symbols: List[str],
    lookback_days: int,
) -> Dict[str, Any]:
    """Core logic for kdbx_rm_equity_curve_data."""
    try:
        result = _q(".rmag.equityCurveData", [s.upper() for s in symbols], lookback_days)
        # Convert table rows to list of dicts for JSON serialisation
        if hasattr(result, "__iter__") and not isinstance(result, (dict, list, str)):
            rows = [dict(row) for row in result]
        elif isinstance(result, list):
            rows = result
        else:
            rows = []
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
    """Core logic for kdbx_rm_search_news."""
    try:
        result = _q(".rmag.searchNews",
                    [s.upper() for s in symbols],
                    query,
                    limit)
        if hasattr(result, "__iter__") and not isinstance(result, (dict, list, str)):
            rows = [dict(row) for row in result]
        elif isinstance(result, list):
            rows = result
        else:
            rows = []
        logger.info("kdbx_rm_search_news: returned %d articles", len(rows))
        return _ok(rows)
    except Exception as exc:
        logger.error("kdbx_rm_search_news: failed — %s", exc)
        return _err("News search failed", str(exc))


# ── MCP tool registration ─────────────────────────────────────────────────────

def register_tools(mcp_server):
    """Register all RM agent MCP tools with the FastMCP server."""

    @mcp_server.tool()
    async def kdbx_rm_ingest_ohlcv(records: List[Dict[str, Any]]) -> Dict[str, Any]:
        """Store daily OHLCV records from AlphaVantage into KDB-X.

        Called by the kdb-ai-demo-agent data_fetch_node immediately after
        fetching from AlphaVantage. All downstream analytics read from KDB-X.

        Args:
            records: list of {date, sym, open, high, low, close, volume}
                     as returned by AlphaVantageClient.get_daily_ohlcv().

        Returns:
            {status, data: {inserted_count}}
        """
        return await _rm_ingest_ohlcv_impl(records)

    @mcp_server.tool()
    async def kdbx_rm_ingest_news(articles: List[Dict[str, Any]]) -> Dict[str, Any]:
        """Store news articles from AlphaVantage into KDB-X.

        Stores news metadata in rmag_news table. When KDB.AI is enabled,
        triggers vector embedding for semantic search via .rmag.ingestNews.

        Args:
            articles: list of {title, url, source, time_published, summary,
                               sentiment_score, sentiment_label, relevant_symbols}

        Returns:
            {status, data: {inserted_count}}
        """
        return await _rm_ingest_news_impl(articles)

    @mcp_server.tool()
    async def kdbx_rm_compute_metrics(
        symbols: List[str],
        lookback_days: int = 90,
    ) -> Dict[str, Any]:
        """Compute portfolio performance metrics for a basket of symbols using q analytics.

        Delegates entirely to .rmag.computeMetrics in q — no Python computation.
        Reads from rmag_ohlcv table ingested by kdbx_rm_ingest_ohlcv.

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
        (symbol match + recency + sentiment magnitude). When KDB.AI is
        enabled, enhances with hybrid BM25 + vector ANN search.

        Args:
            symbols: Ticker symbols to match news against
            query:   Natural language query (used for KDB.AI semantic path)
            limit:   Maximum articles to return (default 10)

        Returns:
            {status, data: [{title, url, source, published, summary,
                             sentiment, sent_label, syms}]}
        """
        return await _rm_search_news_impl(symbols, query, limit)

    logger.info("kdbx_rm_agent: registered 5 RM agent tools")
    return [
        "kdbx_rm_ingest_ohlcv",
        "kdbx_rm_ingest_news",
        "kdbx_rm_compute_metrics",
        "kdbx_rm_equity_curve_data",
        "kdbx_rm_search_news",
    ]
