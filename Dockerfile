# ---------------------------------------------------------------------------
# Dockerfile - KDB-X MCP Server (Linux x86_64 / arm64)
#
# Everything is installed at BUILD TIME - no volume mounts needed for binaries,
# licenses, or tools.  At runtime docker-compose bind-mounts two host directories:
#   ./logs      → /app/logs       (tail / rotate logs from the host)
#   ./q-modules → /app/q-modules  (live-edit q modules without rebuilding)
#
# Build (BuildKit - default since Docker 23):
#
#   docker build \
#     --secret id=kx_bearer,env=KX_BEARER_TOKEN \
#     --build-arg KX_B64LIC="<base64-license>" \
#     -t kdbx-mcp-server .
#
# Or via: docker compose build  (reads .env automatically)
#
# Required build inputs:
#   KX_BEARER_TOKEN  env var   - OAuth2 bearer token (passed as BuildKit secret)
#   KX_B64LIC        build-arg - base64-encoded KDB-X license key
#
# ax-libraries (qcumber) are installed from the local zip:
#   developer-1.5.4-osx/ax-libraries.zip  (whitelisted in .dockerignore)
#   The zip contains libs for ALL platforms: ubuntu16_arm64, ubuntu{16,18,20}_x64,
#   rhel{6,7,8}_x64.  install_ax_libraries.sh auto-selects the correct set.
#
# Optional:
#   KX_ARCH          build-arg - l64 (x86_64, default) | l64arm (aarch64)
#                    KDB-X binary arch; install_kdb.sh also auto-detects this.
# ---------------------------------------------------------------------------

# ── Stage 1: KDB-X + ax-libraries install ─────────────────────────────────
FROM debian:12-slim AS kdbx-installer

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
        bash \
        unzip \
        rsync \
        ncurses-bin \
    && rm -rf /var/lib/apt/lists/*

# Bring in the ax-libraries installer script
COPY scripts/install_ax_libraries.sh /tmp/install_ax_libraries.sh
RUN chmod +x /tmp/install_ax_libraries.sh

# Architecture: l64 (x86_64) or l64arm (aarch64 / AWS Graviton)
ARG KX_ARCH=l64

# Base64 license - required
ARG KX_B64LIC
RUN test -n "$KX_B64LIC" || \
    (echo 'ERROR: --build-arg KX_B64LIC=<base64-license> is required' >&2 && exit 1)

# ── Step 1: Install KDB-X binary + license ──────────────────────────────
# Bearer token is a BuildKit secret - never written to any image layer.
# TERM=xterm-256color is required: install_kdb.sh uses `tput` for color output;
# without a TERM value tput returns empty strings → `printf $NC` → infinite
# "printf: usage" error loop inside the Docker build layer.
RUN --mount=type=secret,id=kx_bearer,required=true \
    export TERM=linux && \
    KX_BEARER="$(cat /run/secrets/kx_bearer)" && \
    curl -fsSL --oauth2-bearer "$KX_BEARER" \
        https://portal.dl.kx.com/assets/raw/kdb-x/install_kdb/~latest~/install_kdb.sh \
        -o /tmp/install_kdb.sh && \
    bash /tmp/install_kdb.sh -y --b64lic "$KX_B64LIC" && \
    rm /tmp/install_kdb.sh

RUN test -x "$HOME/.kx/bin/q" || \
    (echo 'ERROR: q binary not found at ~/.kx/bin/q after KDB-X install' >&2 && exit 1)

# ── Step 2: Install ax-libraries (qcumber, qlint, profiler, ...) ────────
# The zip ships alongside this repo at developer-1.5.4-osx/ax-libraries.zip
# (allowed through .dockerignore via the !developer-1.5.4-osx/ax-libraries.zip rule).
COPY developer-1.5.4-osx/ax-libraries.zip /tmp/ax-libraries.zip
RUN /tmp/install_ax_libraries.sh --dest /root/.kx/ax-libraries /tmp/ax-libraries.zip && \
    rm /tmp/ax-libraries.zip

RUN test -f "/root/.kx/ax-libraries/ws/qcumber.q_" || \
    (echo 'ERROR: qcumber.q_ not found - ax-libraries install failed' >&2 && exit 1)

# ── Step 3: Publish ax-library native .so files into q's arch lib dir ───
# When q resolves `2: (`libname; ...) it searches $QHOME/<arch>/ (e.g.
# /root/.kx/l64arm/ on aarch64).  The .so files in ax-libraries/ws/lib/
# are NOT in that search path, so pcre/fs/util extensions fail to dlopen.
# Detect the arch and copy the correct platform .so files to the q lib dir.
RUN ARCH="$(uname -m)"; \
    case "${ARCH}" in \
        aarch64|arm64) PLATFORM="ubuntu16_arm64"; QARCH="l64arm" ;; \
        x86_64)        PLATFORM="ubuntu20_x64";   QARCH="l64"    ;; \
        *)             PLATFORM="ubuntu20_x64";   QARCH="l64"    ;; \
    esac; \
    SRC="/root/.kx/ax-libraries/ws/lib/${PLATFORM}"; \
    DST="/root/.kx/${QARCH}"; \
    echo "Copying ax-libs ${PLATFORM} → ${DST}"; \
    mkdir -p "${DST}"; \
    cp -v "${SRC}"/*.so* "${DST}/"

# ── Stage 2: Python dependency builder ────────────────────────────────────
FROM python:3.12-slim AS py-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
        build-essential \
    && rm -rf /var/lib/apt/lists/*

RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:$PATH"

WORKDIR /app
COPY pyproject.toml uv.lock README.md ./
COPY src/ ./src/
RUN uv sync --no-dev --frozen

# ── Stage 3: runtime image ─────────────────────────────────────────────────
FROM python:3.12-slim AS runtime

# Runtime packages:
#   lsof    - start_kdbx.sh / stop_kdbx.sh port checks
#   procps  - kill / ps used in stop_kdbx.sh
#   bash    - all scripts require bash
RUN apt-get update && apt-get install -y --no-install-recommends \
        lsof \
        procps \
        bash \
    && rm -rf /var/lib/apt/lists/*

# KDB-X binary, license, AND ax-libraries (qcumber) all come from stage 1
COPY --from=kdbx-installer /root/.kx /root/.kx

WORKDIR /app

COPY --from=py-builder /app/.venv /app/.venv

COPY pyproject.toml uv.lock ./
COPY src/       ./src/
COPY scripts/   ./scripts/
COPY q-modules/ ./q-modules/
COPY docker/entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh scripts/*.sh
# /app/logs is the mount point for the unified log volume
RUN mkdir -p /app/logs

# ── PATH ────────────────────────────────────────────────────────────────
ENV VIRTUAL_ENV=/app/.venv
ENV PATH="/app/.venv/bin:/root/.kx/bin:$PATH"

# ── pykx / KDB-X ────────────────────────────────────────────────────────
ENV PYKX_LICENSED=true
ENV QLIC=/root/.kx

# ── KDB-X connection defaults ────────────────────────────────────────────
ENV KDBX_DB_HOST=127.0.0.1
ENV KDBX_DB_PORT=5001

# ── qcumber - baked-in, always available ─────────────────────────────────
ENV KDBX_DB_QCUMBER_PATH=/root/.kx/ax-libraries/ws/qcumber.q_

# ── MCP server defaults ──────────────────────────────────────────────────
ENV KDBX_MCP_HOST=0.0.0.0
ENV KDBX_MCP_PORT=8000
ENV KDBX_MCP_TRANSPORT=streamable-http

# ── Ports ────────────────────────────────────────────────────────────────
# 8000 - MCP HTTP endpoint
# 5001 - KDB-X IPC (internal; expose only for external q access)
EXPOSE 8000

# Healthcheck: both q and MCP must be up
HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=3 \
    CMD bash -c 'lsof -iTCP:${KDBX_MCP_PORT:-8000} -sTCP:LISTEN -t >/dev/null 2>&1 && \
                 lsof -iTCP:${KDBX_DB_PORT:-5001}  -sTCP:LISTEN -t >/dev/null 2>&1' || exit 1

ENTRYPOINT ["/entrypoint.sh"]
