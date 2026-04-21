// =============================================================================
/ Module:      tca
/ Namespace:   .tca
/ Description: T+1 Transaction Cost Analysis (TCA) -- computes fill rate,
/              trader hold time, and execution hold time at equity parent order
/              level from the HDB order, trade, and instrument tables.
/ Version:     0.1.0
/ Requires:    KDB-X 5.0+; HDB tables: order, trade, instrument
/ Author:      kdb-developer
/ Created:     2026-04-20
/ Updated:     2026-04-20
/ Jira:        GEP-1123
// =============================================================================

\d .tca

// =============================================================================
// Internal Log Helpers
// =============================================================================
/ Trailing underscore marks these as private (internal) helpers.
/ fd -1 = stdout (info/warn), fd -2 = stderr (errors).
/ Separator "  " (two spaces) avoids single-char scalar type -10h issue.

logI_:{ -1 "[tca][INFO]   ", string[.z.p], "  ", x }
logW_:{ -1 "[tca][WARN]   ", string[.z.p], "  ", x }
logE_:{ -2 "[tca][ERROR]  ", string[.z.p], "  ", x }

// =============================================================================
// Input Guard
// =============================================================================
/ @desc  Raise a descriptive signal when a precondition is violated.
/ @param cond  {boolean}  Condition that must be true to continue.
/ @param msg   {string}   Error message to surface on violation.
require_:{[cond;msg]
    if[not cond; logE_ msg; '"[tca] ", msg]
    }

// =============================================================================
// Private Core Implementation
// =============================================================================

/ @desc  Core TCA computation -- accepts table values directly for testability.
/        Used by calcDaily and unit tests alike.
/ .
/ @param oTbl  {table}   Order table (parent + child rows in same table).
/                        Required columns: date, sym, orderId, parentOrderId,
/                        time, qty, fillQty, status.
/                        Parent rows: orderId = parentOrderId (self-referential).
/                        Child rows:  orderId <> parentOrderId.
/ @param tTbl  {table}   Trade/fill table.
/                        Required columns: date, sym, orderId, time, size.
/ @param iTbl  {table}   Instrument reference table.
/                        Required columns: sym, assetClass.
/ @param d     {date}    Reporting date (T+1 batch date).
/ .
/ @return {table}  One row per equity parent order with columns:
/                  date, sym, parentOrderId, fillRate,
/                  traderHoldTimeSecs, execHoldTimeSecs.
/ .
/ @throws  "[tca] no data for date: <d>"  when no parent order rows exist for d.
/ .
/ @note  KDB-X behaviour: `float` keyword is unavailable -- use `"f"$` cast.
/        Multi-column `by` in qSQL raises 'length on this KDB-X instance;
/        workaround: group by single key column, add date column after.

calcWith_:{[oTbl;tTbl;iTbl;d]
    logI_ "calcWith_: entry  |  date=", string[d];

    / --- guard: date must have parent order data ---
    pCount: count select from oTbl where date=d, orderId=parentOrderId;
    require_[0 < pCount; "no data for date: ", string d];

    / --- equity symbol list ---
    eqSyms: exec sym from iTbl where assetClass=`equity;

    / --- parent orders (equity only) for date d ---
    / Rename time->pTime to avoid column-name shadowing in later joins.
    pOrders: select date, sym, parentOrderId:orderId, pTime:time, qty
        from oTbl where date=d, orderId=parentOrderId, sym in eqSyms;
    logI_ "calcWith_: parents found  |  count=", string[count pOrders];

    / --- child order rows for date d ---
    / Filter: rows whose orderId differs from parentOrderId.
    / Note: combined multi-column where + not-equal can raise 'length on some
    / KDB-X builds -- pre-materialise child rows to avoid this.
    cRows: select orderId, parentOrderId, fillQty, cTime:time
        from oTbl where date=d, not orderId=parentOrderId;

    / --- aggregate child metrics per parent ---
    / totFill:   sum of child fillQty      (null input -> q propagates 0N; sum of all-null -> 0i)
    / firstCTime: earliest child order time (null when no children -> 0Np via min)
    / Note: single-column `by` used (multi-column `by` raises 'length on this KDB-X instance).
    cAgg: select totFill:sum fillQty, firstCTime:min cTime by parentOrderId from cRows;

    / --- trade fill aggregates: latest fill time per parent ---
    / Map child orderId -> parentOrderId, then join onto fills.
    cMap: `orderId xkey select orderId, parentOrderId from cRows;
    fRows: select orderId, fTime:time from tTbl where date=d;
    fRowsP: fRows lj cMap;
    / lastFTime: max fill timestamp across all child fills for the parent.
    / AC5: uses LAST (max) fill, not first.
    / Filter null parentOrderId to exclude fills that had no matching child.
    fAgg: select lastFTime:max fTime by parentOrderId
        from fRowsP where not null parentOrderId;

    / --- join all components onto parent orders ---
    base: pOrders lj cAgg;
    base: base lj fAgg;

    / --- compute TCA metrics ---
    / fillRate:            sum(child fillQty) / parent qty, float [0.0, 1.0].
    /                      Null (0n) when totFill = 0 (cancelled / no fills).
    /                      Null propagates naturally when totFill = 0N (no children).
    / traderHoldTimeSecs:  seconds from PM order creation (pTime) to first child
    /                      order slice.  Null when pTime or firstCTime is null.
    / execHoldTimeSecs:    seconds from first child order to last fill.
    /                      Null when no fills exist (lastFTime = 0Np).
    / Note: KDB-X `float` keyword unavailable -- cast with "f"$ instead.
    / Note: timestamp arithmetic produces nanoseconds; divide by 1e9 for seconds.
    base: update
        fillRate:           ?[0i = totFill; 0n; ("f"$totFill) % "f"$qty],
        traderHoldTimeSecs: ("f"$(firstCTime - pTime))   % 1e9,
        execHoldTimeSecs:   ("f"$(lastFTime  - firstCTime)) % 1e9
        from base;

    logI_ "calcWith_: exit  |  result rows=", string[count base];

    / --- return AC10 schema ---
    select date, sym, parentOrderId, fillRate, traderHoldTimeSecs, execHoldTimeSecs
        from base
    }

// =============================================================================
// Public API
// =============================================================================

/ @desc  Compute T+1 TCA metrics (fill rate, trader hold time, exec hold time)
/        for all equity parent orders on the given reporting date.
/ .
/        Reads directly from the live HDB tables `order`, `trade`, `instrument`
/        in the global namespace.  Run after T+1 batch ingestion is complete.
/ .
/ @param d  {date}  Reporting date.  Example: 2026.04.18
/ .
/ @return {table}  One row per equity parent order:
/           date               {date}    Reporting date.
/           sym                {symbol}  Instrument symbol.
/           parentOrderId      {symbol}  Parent order identifier.
/           fillRate           {float}   Proportion filled [0.0, 1.0]; 0n if no fills.
/           traderHoldTimeSecs {float}   Seconds from PM order to first child slice; 0n if unavailable.
/           execHoldTimeSecs   {float}   Seconds from first child slice to last fill; 0n if no fills.
/ .
/ @throws  "[tca] no data for date: <d>"  when no parent order rows exist for d.
/ .
/ @example
/   .tca.calcDaily[2026.04.18]
calcDaily:{[d]
    logI_ "calcDaily: entry  |  date=", string[d];
    require_[-14h = type d; "d must be a date scalar"];
    result: .tca.calcWith_[order; trade; instrument; d];
    logI_ "calcDaily: exit   |  rows=", string[count result];
    result
    }

// =============================================================================
// Module Load Banner
// =============================================================================
\d .
-1 "[tca] module loaded -- namespace .tca";
