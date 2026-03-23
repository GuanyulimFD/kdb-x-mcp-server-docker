# KDB-X MCP Server — Dockerised Edition

A fully self-contained, Docker-first deployment of the [KX Systems KDB-X MCP Server](https://github.com/KxSystems/kdb-x-mcp-server), extended with two tools that close the **q developer SDLC loop** directly inside an AI conversation.

---

## What is this?

This repository wraps the upstream KX KDB-X MCP Server in a production-ready Docker image and adds two SDLC-focused MCP tools on top of the standard SQL and search tools:

| Tool | Purpose |
|------|---------|
| `kdbx_q_eval` | Execute any q expression interactively against the live KDB-X process |
| `kdbx_q_unit_test` | Run [qCumber](https://code.kx.com/developer/qcumber/) `.quke` unit tests against KDB-X |

Together they let a q developer **prototype → test → iterate** entirely within the AI conversation, without leaving the editor or opening a separate q terminal.

---

## SDLC Loop

```
┌─────────────────────────────────────────────────────────┐
│                  AI Conversation (Copilot / Claude)      │
│                                                          │
│  1. Prototype    kdbx_q_eval       ──▶  run q code live  │
│  2. Iterate      kdbx_q_eval       ──▶  refine logic     │
│  3. Test         kdbx_q_unit_test  ──▶  run .quke suite  │
│  4. Commit       save to q-modules/<name>/<name>.q        │
└─────────────────────────────────────────────────────────┘
```

The `q-modules/` directory is **bind-mounted** at runtime — modules can be edited and reloaded without rebuilding the image.

---

## Architecture

Everything is **baked into the image at build time**. No volume mounts are needed for binaries or licenses.

| Component | How it gets in |
|-----------|---------------|
| KDB-X binary (`q`) | Downloaded via KX bearer token at build time |
| KDB-X license (`kc.lic`) | Decoded from `KX_B64LIC` build-arg |
| ax-libraries (qcumber, qlint, profiler) | Installed from bundled `developer-1.5.4-osx/ax-libraries.zip` |
| Python MCP server | `uv sync` from `pyproject.toml` |
| q-modules library | `COPY q-modules/` (also bind-mounted for live edits) |

At runtime, two host paths are mounted:

| Mount | Purpose |
|-------|---------|
| `./logs → /app/logs` | Unified real-time log stream (KDB-X q process + MCP server) |
| `./q-modules → /app/q-modules` | Live-reloadable q modules — no rebuild needed |

---

## Quickstart

### Prerequisites

| Requirement | Notes |
|-------------|-------|
| Docker >= 24 + Compose v2 | `docker compose version` |
| `KX_BEARER_TOKEN` | OAuth2 bearer from your KX portal download page |
| `KX_B64LIC` | Base64 license key from the KX portal installer command |
| `developer-1.5.4-osx/ax-libraries.zip` | Already present in the repo |

**Finding your credentials** — look at the `curl` and `bash install_kdb.sh` commands shown on the KX developer portal:

```bash
# Bearer token — the value after --oauth2-bearer
curl -sLO --oauth2-bearer <KX_BEARER_TOKEN> https://portal.dl.kx.com/...

# License key — the value after --b64lic
bash install_kdb.sh --b64lic <KX_B64LIC>
```

> `KX_BEARER_TOKEN` is passed as a **BuildKit secret** — it is never written to any image layer or visible in `docker history`.

### Build and run

```bash
# 1. Clone
git clone https://github.com/GuanyulimFD/kdb-x-mcp-server-docker.git
cd kdb-x-mcp-server-docker

# 2. Set credentials
cp .env.example .env
# Edit .env — fill in KX_BEARER_TOKEN and KX_B64LIC

# 3. Build (installs KDB-X + ax-libraries inside the image)
docker compose build

# 4. Start
docker compose up -d

# 5. Follow the unified log (KDB-X q process + Python MCP server)
tail -f logs/kdbx_mcp_*.log
```

The MCP HTTP endpoint is available at `http://localhost:8000/mcp`.

---

## Connecting an MCP Client

### GitHub Copilot (VS Code)

Add to `.vscode/mcp.json`:

```json
{
  "servers": {
    "kdbx-mcp": {
      "type": "http",
      "url": "http://localhost:8000/mcp"
    }
  }
}
```

### Claude Desktop

```json
{
  "mcpServers": {
    "kdbx-mcp": {
      "command": "npx",
      "args": ["mcp-remote", "http://localhost:8000/mcp"]
    }
  }
}
```

See [mcp-clients/](mcp-clients/) for full configuration guides.

---

## SDLC Tools

### `kdbx_q_eval`

Executes any q expression against the live KDB-X process and returns the result as structured JSON.

```
Params:  code  (string)  — any valid q expression
Returns: { status: "ok"|"error", result: <json> | message: <string> }
```

**Example:** the agent calls `kdbx_q_eval` to define a function, then calls it again to validate the output — all within the same conversation turn.

---

### `kdbx_q_unit_test`

Runs a [qCumber](https://code.kx.com/developer/qcumber/) `.quke` test suite against the KDB-X process.

```
Params:
  quke_content  (string)  — full .quke test file content
  setup_code    (string)  — optional q code to define functions before tests run
  qcumber_path  (string)  — optional override for qcumber.q_ path

Returns: { status, summary, passed, failed, total, tests: [...] }
```

**Example `.quke` block:**

```q
feature VWAP calculation

    before
        trade :: ([]sym:`AAPL`GOOG`AAPL; price:100 200 110f; size:100 50 200)

    should compute correct AAPL vwap
        expect weighted average
            t: select vwap:size wavg price by sym from trade;
            r: exec vwap from t where sym=`AAPL;
            .qu.compare[first r; (100*100f + 200*110f) % 300f]
```

---

## q-Modules Library

Reusable q analytics are stored in `q-modules/` and **auto-loaded at KDB-X startup**.

```
q-modules/
    finstat/      ← financial statistics (Sharpe, drawdown, Sortino, …)
    lookback/     ← rolling window analytics
    dataprofile/  ← table profiling and data quality
    cron/         ← scheduled q job runner
```

Each module has a matching `.quke` test file. Add your own by following the layout:

```
q-modules/<name>/
    <name>.q      ← implementation (namespace .<name>.*)
    <name>.quke   ← qcumber unit tests (mandatory)
```

---

## Deploying to Another Host (Air-Gapped)

For environments with no registry access, the image ships as a self-contained tarball:

```bash
# On dev machine — export image + runtime env file
./scripts/export_image.sh

# Transfer to target host
scp kdbx-mcp-server.tar.gz kdbx-mcp-server.env user@target:~/

# On target host — import and run
bash import_and_run.sh
```

No KX credentials are needed on the target host — they are baked in at build time.

---

## Cross-Platform Notes

| Target | `.env` setting | Build command |
|--------|---------------|---------------|
| `linux/amd64` — default, WSL2 | `KX_ARCH=l64` | `docker compose build` |
| `linux/arm64` — AWS Graviton | `KX_ARCH=l64arm` | `docker compose build` |
| Cross-compile `amd64` from Apple Silicon | `KX_ARCH=l64` | `docker buildx build --platform linux/amd64 ...` |

> Images built on Apple Silicon produce `linux/arm64` containers by default. WSL2 is `x86_64` only — use the cross-compile option above or build natively on the WSL2 machine.

---

## Configuration Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `KX_BEARER_TOKEN` | — | Build-time only: KX portal bearer token |
| `KX_B64LIC` | — | Build-time only: base64 license key |
| `KX_ARCH` | `l64` | KDB-X binary arch (`l64` = x86_64, `l64arm` = aarch64) |
| `KDBX_DB_PORT` | `5001` | Internal KDB-X q process port |
| `KDBX_MCP_PORT` | `8000` | MCP HTTP server port |
| `KDBX_MCP_LOG_LEVEL` | `INFO` | Log verbosity (`DEBUG`/`INFO`/`WARNING`/`ERROR`) |
| `MCP_HOST_PORT` | `8000` | Host-side port exposed by Docker |
| `LOG_DIR_HOST` | `./logs` | Host directory bind-mounted to `/app/logs` |

---

## All Available Tools, Resources & Prompts

### Tools

| Tool | Category | Description |
|------|----------|-------------|
| `kdbx_q_eval` | SDLC | Execute q expressions interactively |
| `kdbx_q_unit_test` | SDLC | Run qCumber `.quke` unit tests |
| `kdbx_run_sql_query` | Data | Execute SQL SELECT against KDB-X |
| `kdbx_similarity_search` | Search | Vector similarity search on a KDB-X table |
| `kdbx_hybrid_search` | Search | Combined vector + sparse text search |

### Resources

| Resource | URI | Description |
|----------|-----|-------------|
| `kdbx_describe_tables` | `kdbx://tables` | Full schema overview with sample data |
| `kdbx_sql_query_guidance` | `file://guidance/kdbx-sql-queries` | SQL syntax guide for LLM context |

### Prompts

| Prompt | Description |
|--------|-------------|
| `kdbx_table_analysis` | Generate a detailed analysis prompt for a specific table |

---

## Useful Resources

- [KDB-X documentation](https://docs.kx.com/public-preview/kdb-x/home.htm)
- [qCumber test framework](https://code.kx.com/developer/qcumber/)
- [Q for Mortals 4.1](https://code.kx.com/kdb-x/learn/q4m/index.html)
- [KX Forum](https://forum.kx.com/)
