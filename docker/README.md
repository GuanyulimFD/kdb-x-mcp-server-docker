# Docker - KDB-X MCP Server

The `Dockerfile` and `docker-compose.yml` at the project root produce a fully
self-contained image.  Everything needed to run is **baked in at build time**:

| Component | How it gets in |
|-----------|---------------|
| KDB-X binary (`q`) | KX installer (`install_kdb.sh --b64lic`) |
| KDB-X license (`kc.lic`) | KX installer (via `--b64lic` build-arg) |
| ax-libraries (qcumber, qlint, profiler, ...) | Local `developer-1.5.4-osx/ax-libraries.zip` + `install_ax_libraries.sh` |
| Python MCP server | `uv sync` from `pyproject.toml` |
| q-modules | `COPY q-modules/` |

At runtime, **only the log directory is mounted** (`/app/logs`) so you can
tail and rotate logs from the host without entering the container.

---

## Quick start

```bash
# 1. Clone
git clone https://github.com/GuanyulimFD/kdb-x-mcp-server-docker.git
cd kdb-x-mcp-server

# 2. Fill in credentials
cp .env.example .env
# Edit .env - set KX_BEARER_TOKEN and KX_B64LIC
# (Both values come from the KX developer portal installer command)

# IMPORTANT: KX_BEARER_TOKEN is consumed as a BuildKit secret from the HOST SHELL
# environment. Docker Compose does NOT promote .env values into the shell, so you
# must export it explicitly before running docker compose build:
export KX_BEARER_TOKEN="<your-bearer-token>"

# The ax-libraries.zip is read directly from developer-1.5.4-osx/ (already in repo)
# No extra copy step needed - it is whitelisted in .dockerignore

# 3. Build (installs KDB-X + ax-libraries inside the image)
docker compose build

# 4. Run
docker compose up -d

# 5. Follow the unified real-time log (q process + MCP server, one stream)
tail -f logs/kdbx_mcp_*.log

# Or via docker:
docker compose logs -f
```

The MCP HTTP endpoint is available at `http://localhost:8000/mcp`.

---

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| Docker >= 24 + Docker Compose v2 | `docker compose version` |
| `KX_BEARER_TOKEN` | OAuth2 bearer from your KX portal download URL |
| `KX_B64LIC` | Base64 license key (`--b64lic` value in the KX installer command) |
| `developer-1.5.4-osx/ax-libraries.zip` | Already present in the repo from your KX developer download |

---

## Finding your build credentials

### Bearer token
Look at the `curl` command shown on your KX developer portal downloads page:
```
curl -sLO --oauth2-bearer <THIS_IS_YOUR_TOKEN> https://portal.dl.kx.com/...
```

### `KX_B64LIC`
This is the value after `--b64lic` in the installer command the portal shows:
```
bash install_kdb.sh --b64lic <THIS_IS_YOUR_LICENSE>
```

> **Security**: `KX_BEARER_TOKEN` is passed as a **BuildKit secret** and is
> never written to any image layer or visible in `docker history`.
> `KX_B64LIC` ends up in the license file inside the image, which is expected.
>
> **Important**: Docker Compose resolves `secrets.kx_bearer.environment` from the
> **host shell environment**, not from `.env`. Always `export KX_BEARER_TOKEN=<token>`
> in your shell before running `docker compose build`. Failure to do so causes `curl`
> to receive an empty bearer token, which the KX portal rejects with HTTP 401/403
> (exit code 22).

---

## Stand-alone build (without docker compose)

```bash
export KX_BEARER_TOKEN="MDAwMS..."
export KX_B64LIC="lUD61TYk..."

docker build \
  --secret id=kx_bearer,env=KX_BEARER_TOKEN \
  --build-arg KX_B64LIC="$KX_B64LIC" \
  --build-arg KX_ARCH=l64 \
  -t kdbx-mcp-server .
```

Make sure `developer-1.5.4-osx/ax-libraries.zip` is present in the repository
root before running the build — it is whitelisted in `.dockerignore` so Docker
will include it in the build context automatically.

For aarch64 / AWS Graviton, set `KX_ARCH=l64arm`.

---

## Logging

Both the KDB-X `q` process and the Python MCP server write to a **single
unified log file** created at container startup:

```
/app/logs/kdbx_mcp_<YYYYMMDD_HHMMSS>.log
```

This file is inside the `/app/logs` volume mount, so it appears on the host at
the path configured by `LOG_DIR_HOST` in `.env` (default: `./logs`).

```bash
# Real-time tail from the host (recommended)
tail -f ./logs/kdbx_mcp_*.log

# Or from Docker
docker compose logs -f
```

Log entries are prefixed so you can grep by source:
- `[kdbx][QUERY]` / `[kdbx][RESULT]` — KDB-X IPC logging (from `kdbx_init.q`)
- `[kdbx_init]` — q startup / module loading
- Python `INFO` / `DEBUG` lines — MCP server tool calls, connection events
- `[entrypoint]` — container lifecycle markers

---

## Runtime environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `KDBX_DB_PORT` | `5001` | KDB-X q process port (internal) |
| `KDBX_MCP_PORT` | `8000` | MCP HTTP endpoint port |
| `KDBX_MCP_TRANSPORT` | `streamable-http` | `stdio` or `streamable-http` |
| `KDBX_MCP_LOG_LEVEL` | `INFO` | `DEBUG`, `INFO`, `WARNING`, `ERROR` |
| `KDBX_DB_QCUMBER_PATH` | `/root/.kx/ax-libraries/ws/qcumber.q_` | Baked in - no need to change |
| `KDBX_SKIP_Q_MODULES` | `0` | Set `1` to skip auto-loading `q-modules/` |

---

## Connecting an AI client

### VS Code GitHub Copilot

`.vscode/mcp.json`:
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
See [mcp-clients/claude-desktop.md](../mcp-clients/claude-desktop.md).

---

## Stopping

```bash
docker compose down
# KDB-X receives SIGTERM from the container stop signal and shuts down cleanly.
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `ERROR: --build-arg KX_B64LIC is required` | Missing `.env` entry | Add `KX_B64LIC=...` to `.env` |
| `Error: secret not found: kx_bearer` | `KX_BEARER_TOKEN` not in shell env | Run `export KX_BEARER_TOKEN=<token>` before `docker compose build` — putting it only in `.env` is not sufficient; BuildKit secrets require an exported shell variable |
| `COPY failed: developer-1.5.4-osx/ax-libraries.zip not found` | Zip missing from repo | Confirm `developer-1.5.4-osx/ax-libraries.zip` exists at repo root |
| `ERROR: qcumber.q_ not found` | ax-libraries zip corrupt or wrong layout | Inspect `docker build` output; verify zip with `unzip -l developer-1.5.4-osx/ax-libraries.zip` |
| `q binary not found` in startup banner | Build succeeded but PATH issue | Should not happen; file a bug |
| MCP not reachable on 8000 | Container still starting | Wait for `healthy` status: `docker compose ps` |
| `connection refused` from pykx tool calls | KDB-X crashed post-start | Check log: `tail -f ./logs/kdbx_mcp_*.log` |
