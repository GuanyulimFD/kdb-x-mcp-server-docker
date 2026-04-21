# q-modules — KDB-X Module Library

This directory contains reusable q/KDB-X modules intended to accelerate
day-to-day KDB development.  Each module is a self-contained sub-directory
with the following layout:

```
q-modules/
    <module-name>/
        <module-name>.q       ← module implementation (namespace .module-name.*)
        <module-name>.quke    ← qcumber unit tests
        README.md             ← (optional) module-specific documentation
```

## Conventions

| Convention | Detail |
|-----------|--------|
| Namespace | `.modulename.*` (lowercase, no hyphens) |
| Public API | lowerCamelCase, documented with `/ @` comment tags |
| Private helpers | leading-underscore prefix: `_helperName` |
| Logging | define `.log.info`/`.log.warn`/`.log.error` helpers once per module |
| Unit tests | authored in `.quke` DSL and run via `kdbx_q_unit_test` MCP tool |
| Type annotations | `/ @param name {type} description` on every public function |

## Loading a module

### On-demand (interactive development)
Use the `kdbx_q_eval` tool with `\\l q-modules/<name>/<name>.q`.

### At KDB-X startup
`kdbx_init.q` auto-loads all `q-modules/**/*.q` files that exist at startup.
Set `KDBX_SKIP_Q_MODULES=1` to disable auto-loading.

## Running unit tests

Use the `kdbx_q_unit_test` MCP tool and point `quke_content` at the
`.quke` file contents, or use the helper scripts:

```bash
# Example: test the finstat module
bash scripts/test_q_analytics.sh
```

## Available modules

| Module | Namespace | Description |
|--------|-----------|-------------|
| `finstat` | `.finstat` | Common financial statistics: VWAP, returns, volatility, SMA/EMA, Sharpe, max drawdown |
| `dataprofile` | `.dataprofile` | CSV/data-file profiling: peek, type inference, schema proposal, ingestion recommendations |
| `cron` | `.cron` | Timer-driven cron job scheduler: register jobs with time windows, periods, and args; driven by `.z.ts` |
| `tca` | `.tca` | T+1 TCA at equity parent order level: fill rate, trader hold time, exec hold time (GEP-1123) |
