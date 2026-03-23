import logging
import os
from datetime import datetime


def setup_logging(
    log_level: str = "INFO",
    log_dir: str = "logs",
    log_file: str = "",
) -> str:
    """Configure logging for the MCP server.

    Writes to two sinks simultaneously:
      1. stderr  - always, so stdio-transport clients and terminal runs see output
      2. A persistent log file (see below)

    Log file resolution order:
      1. ``log_file`` argument (explicit path) — use as-is, append mode
      2. ``KDBX_LOG_FILE`` environment variable — same semantics
      3. Auto-create ``<log_dir>/mcp_server_<YYYYMMDD_HHMMSS>.log``

    Passing an explicit path (from start_all.sh or KDBX_LOG_FILE) is how the
    Python MCP server and the KDB-X q process both end up writing to a single
    unified log file.

    Args:
        log_level: One of DEBUG / INFO / WARNING / ERROR / CRITICAL.
        log_dir:   Directory used when auto-creating the log file.
        log_file:  Explicit path to append to.  Empty string = auto-create.

    Returns:
        Absolute path to the log file that was opened.
    """
    level = getattr(logging, log_level.upper(), logging.INFO)
    fmt = "%(asctime)s - %(name)s - %(levelname)s - %(message)s"
    formatter = logging.Formatter(fmt)

    root = logging.getLogger()
    root.setLevel(level)

    # Avoid duplicate handlers when setup_logging is called more than once
    if root.handlers:
        root.handlers.clear()

    # 1. Stderr handler - always present
    stderr_handler = logging.StreamHandler()
    stderr_handler.setFormatter(formatter)
    root.addHandler(stderr_handler)

    # 2. File handler
    resolved_path = ""
    try:
        # Resolution order: argument > env var > auto-create
        if log_file:
            resolved_path = os.path.abspath(log_file)
        elif os.environ.get("KDBX_LOG_FILE"):
            resolved_path = os.path.abspath(os.environ["KDBX_LOG_FILE"])
        else:
            os.makedirs(log_dir, exist_ok=True)
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            resolved_path = os.path.abspath(
                os.path.join(log_dir, f"mcp_server_{timestamp}.log")
            )

        os.makedirs(os.path.dirname(resolved_path) or ".", exist_ok=True)
        file_handler = logging.FileHandler(resolved_path, mode="a", encoding="utf-8")
        file_handler.setFormatter(formatter)
        root.addHandler(file_handler)
        # Announce the log path on stderr so it is trivial to locate
        logging.getLogger(__name__).info(
            f"MCP server log file: {resolved_path}"
        )
    except Exception as e:
        logging.getLogger(__name__).warning(
            f"Could not open log file {resolved_path!r}: {e}"
        )

    return resolved_path
