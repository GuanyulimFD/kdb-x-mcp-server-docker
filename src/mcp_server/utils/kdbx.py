import logging
from functools import lru_cache
import pykx as kx
import httpx
from typing import Any, Optional
from mcp_server.settings import KDBConfig
from mcp_server.server import app_settings

db_config = app_settings.db
logger = logging.getLogger(__name__)


# ── DB Service Gateway REST client ─────────────────────────────────────────────

class DbServiceGatewayClient:
    """REST client for KxSystems DB Service Gateway REST API.

    Calls POST /api/v0/query/q to execute q expressions via HTTP
    instead of PyKX IPC — used by the rm-agent analytics MCP tools.
    """

    def __init__(self, base_url: str | None = None, timeout: float = 30.0):
        self._base_url = (base_url or db_config.service_url).rstrip("/")
        self._timeout = timeout

    def query(self, q_expr: str) -> Any:
        """POST a q expression to the DB Service Gateway and return the result."""
        url = f"{self._base_url}/api/v0/query/q"
        try:
            resp = httpx.post(url, json={"expression": q_expr}, timeout=self._timeout)
            resp.raise_for_status()
            body = resp.json()
            return body.get("result", body)
        except httpx.HTTPStatusError as exc:
            raise RuntimeError(
                f"DB Service query failed [{exc.response.status_code}]: {q_expr[:80]!r}"
            ) from exc
        except Exception as exc:
            raise RuntimeError(f"DB Service query error: {q_expr[:80]!r} — {exc}") from exc


@lru_cache()
def get_gateway_client() -> DbServiceGatewayClient:
    return DbServiceGatewayClient()


def _q_syms(symbols: list[str]) -> str:
    """Build a q symbol-list literal, e.g. `AAPL`MSFT`TSM."""
    upper = [s.upper() for s in symbols]
    if not upper:
        return "`$()"
    return "`" + "`".join(upper)


def _q_rest(expr: str) -> Any:
    """Execute a q expression via DB Service Gateway REST API."""
    return get_gateway_client().query(expr)


def _to_rows(result: Any) -> list:
    """Normalise a DB Service query result to a list of row dicts."""
    if isinstance(result, list):
        return result
    if isinstance(result, dict):
        # Columnar format: {"col1": [v1, v2], "col2": [v1, v2]}
        vals = list(result.values())
        if vals and all(isinstance(v, list) for v in vals):
            cols = list(result.keys())
            n = len(vals[0])
            return [{c: result[c][i] for c in cols} for i in range(n)]
        return [result]
    return []

def get_kdb_connection() -> kx.QConnection:

    try:
        conn = kdb_sync_connection(db_config)
        conn('') # check if conn is live for existing connection from cache
        return conn
    except Exception as e:
        if "Attempted to use a closed IPC connection" in str(e):
            logger.warning("KDB-X connection was closed. Reinitializing...")
            cleanup_kdb_connection()
            conn = kdb_sync_connection(db_config)
            conn('')
            return conn
        else:
            logger.error(f"Error in creating KDBX connection: {e}")
            raise

@lru_cache()
def kdb_sync_connection(config: Optional[KDBConfig] = None) -> kx.QConnection:
    if config is None:
        config = db_config

    logger.debug(f"KDBConfig: {config=}")
    logger.info(f"Connecting to KDB at {config.host}:{config.port}")
    retry = config.retry

    for attempt in range(1, retry + 1):
        try:
            conn = kx.SyncQConnection(
                host=config.host,
                port=config.port,
                username=config.username,
                password=config.password.get_secret_value(),
                timeout=config.timeout,
                reconnection_attempts=config.retry,
                tls=config.tls,
            )
            logger.info("Connected to Q/KDB-X")
            return conn
        except Exception as e:
            logger.warning(f"KDB-X connectivity attempt {attempt}/{retry} failed: {str(e)}")

    logger.error(f"Failed to connect to KDB")
    raise

def cleanup_kdb_connection():
    kdb_sync_connection.cache_clear()
    logger.info("KDBX connection cache cleared")
