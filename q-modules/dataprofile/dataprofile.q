// =============================================================================
// Module      : dataprofile
// Namespace   : .dataprofile
// Description : CSV / delimited-file profiling for KDB/q.
//
//   Peek at raw data, infer KDB column types from string samples,
//   generate a schema proposal, and recommend an ingestion strategy
//   suited to KDB time-series tables.
//
//   Public API
//   ----------
//   peek            Load first N rows as an all-string table
//   inferSchema     Infer KDB type-char map from an all-string table
//   cast            Apply an inferred type-map to coerce column types
//   profile         Column-level statistics (nulls, distinct, min, max)
//   proposeSchema   One-shot: peek -> infer -> return schema proposal dict
//   suggestIngestion Recommend partitioning, attributes, and load pattern
//
// Version  : 0.1.0
// Requires : KDB/q 4.x+ (compatible with KDB-X 5.0)
// Author   : kdb-x-mcp-server
// =============================================================================

\d .dataprofile

// ---------------------------------------------------------------------------
// Internal logging
// ---------------------------------------------------------------------------

logI_: {if[0 < count x; -1 "[dataprofile][INFO]  ", string[.z.p], " ", x]}
logW_: {if[0 < count x; -1 "[dataprofile][WARN]  ", string[.z.p], " ", x]}
logE_: {if[0 < count x; -2 "[dataprofile][ERROR] ", string[.z.p], " ", x]}

// ---------------------------------------------------------------------------
// Internal guard
// ---------------------------------------------------------------------------

/ @desc Raise a descriptive error when a precondition is violated.
require_: {[cond; msg]
    if[not cond;
        .dataprofile.logE_ msg;
        '"[dataprofile] ", msg
    ]
 }

// ---------------------------------------------------------------------------
// TYPE_CHARS_ / TYPE_SIZES_  --  approximate byte size per KDB type char
// ---------------------------------------------------------------------------

/ String of all recognised type chars (one char per KDB type).
TYPE_CHARS_: "bxhijefcs*dpmnuvtg "

/ Corresponding per-value byte sizes (int vector, same order as TYPE_CHARS_).
TYPE_SIZES_: 1 1 2 4 8 4 8 1 8 8 4 8 4 8 8 4 4 4 16 16i

/ @desc Return byte size for a type char; defaults to 16 for unknowns.
/       Uses string-find (?), which handles both char scalars and 1-char strings.
bytesForType_: {[tc]
    idx: .dataprofile.TYPE_CHARS_ ? tc;
    $[idx < count .dataprofile.TYPE_CHARS_; .dataprofile.TYPE_SIZES_[idx]; 16i]
 }

// ---------------------------------------------------------------------------
// Internal: type inference
// ---------------------------------------------------------------------------

/ @desc  Infer the KDB type char for a single string column using q value[].
/        Valid q literals (dates, timestamps, times, numbers) are identified
/        by their parsed type.  Anything that fails or parses as char/string
/        falls back to " " (varchar).
/ @param vals  {string list}  Column values (char vectors).
/ @return      {char}         One of: d p t j f m n u v or " " (varchar).
inferColType_: {[vals]
    nne: vals where {not x~""} each vals;
    if[0 = count nne; :" "];
    sample: 50 sublist nne;
    parsed: @[{value each x}; sample; {()}];
    if[0 = count parsed; :" "];
    baseType: abs type first parsed;
    typeChar: .Q.t baseType;
    if[typeChar in " cs"; :" "];
    typeChar
 }

/ @desc  Classify a column: return its inferred type, but promote low-
/        cardinality varchar columns to symbol (*) when distinctCount <= symThresh.
/ @param vals       {string list}  Column values.
/ @param symThresh  {long}         Max distinct count for symbol promotion.
/ @return           {char}         KDB type char.
classifyCol_: {[vals; symThresh]
    base: .dataprofile.inferColType_ vals;
    if[not base~" "; :base];
    nne: vals where {not x~""} each vals;
    dc: count distinct nne;
    / Return varchar for empty columns -- no basis for type promotion.
    if[0 = dc; :" "];
    $[dc <= symThresh; "*"; " "]
 }

// ---------------------------------------------------------------------------
// peek  --  Read first N rows as an all-string table
// ---------------------------------------------------------------------------

/ @desc  Read the first n data rows (plus header) from a delimited text file.
/        All columns are returned as char-vector (string) lists so that
/        subsequent profiling sees raw values before any type coercion.
/        Only n+1 lines are read -- efficient for large files.
/ @param path   {string}  Absolute file path (e.g. "/data/trades.csv").
/ @param delim  {char}    Field delimiter (e.g. ",").
/ @param n      {long}    Maximum number of data rows to read.
/ @return       {table}   All-string table; column names from first line.
/ @throws       if file does not exist or has no data rows.
/ @example
/   .dataprofile.peek["/data/trades.csv"; ","; 100]
peek: {[path; delim; n]
    .dataprofile.logI_["peek: path=", path, " delim=", enlist[delim],
                       " n=", string n];
    .dataprofile.require_[0 < count path; "peek: path must not be empty"];
    .dataprofile.require_[n >= 1; "peek: n must be >= 1"];
    hsymPath: hsym `$path;
    fileOk: @[{hcount x; 1b}; hsymPath; {0b}];
    .dataprofile.require_[fileOk; "peek: file not found: ", path];
    lines: (n + 1) sublist read0 hsymPath;
    .dataprofile.require_[1 < count lines;
        "peek: file has no data rows (only header or empty)"];
    / Ensure delimiter is a 1-char string; accept both char scalar and char vector.
    delimStr: $[-10h = type delim; enlist delim; delim];
    hdr: `$delimStr vs first lines;
    dat: delimStr vs/: 1_ lines;
    tbl: flip hdr!flip dat;
    .dataprofile.logI_["peek: loaded ", string[count tbl], " rows x ",
                       string[count cols tbl], " cols"];
    tbl
 }

// ---------------------------------------------------------------------------
// inferSchema  --  Infer KDB type chars for every column
// ---------------------------------------------------------------------------

/ @desc  Infer a KDB type char for every column in an all-string table.
/        Returns a symbol->char dictionary (the type map) suitable for
/        passing to cast[] or building the (typeStr;delim) 0: load form.
/ @param tbl        {table}  All-string table (e.g. from peek[]).
/ @param symThresh  {long}   Distinct-count threshold for symbol promotion.
/ @return           {dict}   col -> type char, e.g. `date`sym`price!("d*f").
/ @throws           if tbl is not a table.
/ @example
/   .dataprofile.inferSchema[raw; 100]
inferSchema: {[tbl; symThresh]
    .dataprofile.logI_["inferSchema: cols=", string[count cols tbl],
                       " rows=", string[count tbl],
                       " symThresh=", string symThresh];
    .dataprofile.require_[98h = type tbl; "inferSchema: tbl must be a table"];
    .dataprofile.require_[0 < count cols tbl;
        "inferSchema: table has no columns"];
    colNames: cols tbl;
    / Pass tbl and symThresh explicitly -- q lambdas do not close over outer locals.
    typeMap: colNames!{.dataprofile.classifyCol_[y x; z]}[; tbl; symThresh] each colNames;
    .dataprofile.logI_["inferSchema: types: ",
                       " " sv {(string x), ":", enlist y}'[colNames; typeMap colNames]];
    typeMap
 }

// ---------------------------------------------------------------------------
// cast  --  Apply type map to coerce table columns
// ---------------------------------------------------------------------------

/ @desc  Apply an inferred or custom type map to cast each column from string
/        to its target type.  Protected evaluation ensures a failure in one
/        column falls back to original string values without aborting.
/        Symbol columns ("*") use backtick-cast; others use type-char cast;
/        varchar (" ") columns are left unchanged.
/ @param tbl     {table}  Input table (all-string from peek[]).
/ @param typeMap {dict}   col -> type char (from inferSchema[] or custom).
/ @return        {table}  Table with columns cast to target types.
/ @throws        if tbl is not a table.
/ @example
/   casted: .dataprofile.cast[raw; .dataprofile.inferSchema[raw; 100]]
cast: {[tbl; typeMap]
    .dataprofile.logI_["cast: ", string[count typeMap], " mappings"];
    .dataprofile.require_[98h = type tbl; "cast: tbl must be a table"];
    valid: (key typeMap) where (key typeMap) in cols tbl;
    / Use value-based parsing: q's value[] handles dates, times, timestamps,
    / longs, floats etc. from their string representations.  Empty strings are
    / left unchanged (suitable for downstream null handling).
    castOne_: {[acc; col; mp]
        typ: mp col;
        if[typ~" "; :acc];
        orig: acc col;
        if[typ~"*"; :@[acc; col; :; `$/:orig]];   / symbol: each-right backtick
        parsed: {$[x~""; x; @[value; x; {x}]]} each orig;
        @[acc; col; :; parsed]
    }[;; typeMap];
    result: castOne_/[tbl; valid];
    .dataprofile.logI_["cast: ", string[count valid], " columns cast"];
    result
 }

// ---------------------------------------------------------------------------
// Internal: per-column statistics row
// ---------------------------------------------------------------------------

/ @desc  Compute statistics for a single string column; returns a row dict.
colStats_: {[colName; vals; symThresh]
    total: count vals;
    nullCount: count vals where {x~""} each vals;
    nne: vals where {not x~""} each vals;
    dc: count distinct nne;
    inferredType: .dataprofile.classifyCol_[vals; symThresh];
    minVal: $[0 < count nne; first asc nne; ""];
    maxVal: $[0 < count nne; last  asc nne; ""];
    samples: ", " sv 5 sublist distinct nne;
    `col`type`total`nullCount`fillPct`distinctCount`minVal`maxVal`sampleVals!
        (colName;
         inferredType;
         total;
         nullCount;
         $[total > 0; 1.0 - (`float$nullCount) % `float$total; 0f];
         dc;
         minVal;
         maxVal;
         samples)
 }

// ---------------------------------------------------------------------------
// profile  --  Column-level statistics table
// ---------------------------------------------------------------------------

/ @desc  Produce a per-column statistics table for an all-string input table.
/        Use this to assess data quality, cardinality, and type fit before
/        committing to a schema.
/ @param tbl        {table}  All-string table (typically from peek[]).
/ @param symThresh  {long}   Distinct-count threshold for symbol inference.
/ @return           {table}  One row per column:
/                              col, type, total, nullCount, fillPct,
/                              distinctCount, minVal, maxVal, sampleVals.
/ @throws           if tbl is not a table.
/ @example
/   .dataprofile.profile[raw; 100]
profile: {[tbl; symThresh]
    .dataprofile.logI_["profile: ", string[count cols tbl], " cols, ",
                       string[count tbl], " rows"];
    .dataprofile.require_[98h = type tbl; "profile: tbl must be a table"];
    .dataprofile.require_[0 < count cols tbl;
        "profile: table has no columns"];
    colNames: cols tbl;
    / Pass tbl and symThresh explicitly -- q lambdas do not close over outer locals.
    rows: {.dataprofile.colStats_[x; z x; y]}[; symThresh; tbl] each colNames;
    k: key first rows;
    result: flip k!(flip {value x} each rows);
    .dataprofile.logI_["profile: done - ", string[count result], " columns"];
    result
 }

// ---------------------------------------------------------------------------
// proposeSchema  --  One-shot schema proposal
// ---------------------------------------------------------------------------

/ @desc  Read a delimited file, infer column types, and return a schema
/        proposal dictionary:
/          tableName    - as provided
/          rowsSampled  - number of data rows read
/          colCount     - number of columns detected
/          profile      - per-column stats table (from profile[])
/          typeMap      - inferred col -> type char dict
/          typeStr      - type char string for (typeStr;delim) 0: load form
/          loadExpr     - q expression to load the full file with inferred types
/ @param path       {string}  Absolute file path.
/ @param delim      {char}    Field delimiter.
/ @param n          {long}    Rows to sample for inference.
/ @param tableName  {string}  Logical table name.
/ @param symThresh  {long}    Symbol-promotion threshold.
/ @return           {dict}    Schema proposal.
/ @throws           if file not found or empty.
/ @example
/   .dataprofile.proposeSchema["/data/trades.csv"; ","; 500; "trades"; 100]
proposeSchema: {[path; delim; n; tableName; symThresh]
    .dataprofile.logI_["proposeSchema: path=", path,
                       " table=", tableName, " n=", string n];
    raw: .dataprofile.peek[path; delim; n];
    prof: .dataprofile.profile[raw; symThresh];
    typeMap: .dataprofile.inferSchema[raw; symThresh];
    typeStr: typeMap cols raw;
    delimLit: "\"", enlist[delim], "\"";   / e.g. "," -> "\",\""
    loadExpr: "tbl: (\"", typeStr, "\"; ", delimLit, ") 0: hsym `$\"", path, "\"";
    .dataprofile.logI_["proposeSchema: done typeStr=", typeStr];
    `tableName`rowsSampled`colCount`profile`typeMap`typeStr`loadExpr!
        (tableName; count raw; count cols raw; prof; typeMap; typeStr; loadExpr)
 }

// ---------------------------------------------------------------------------
// suggestIngestion  --  KDB ingestion strategy recommendations
// ---------------------------------------------------------------------------

/ @desc  Analyse a schema proposal and recommend a KDB-idiomatic ingestion
/        strategy.  Output dict keys:
/          tableName      - from proposal
/          storageMode    - "partitioned HDB (ts->date)" / "partitioned HDB
/                           (date col)" / "in-memory"
/          partitionCol   - detected partition column (null sym if none)
/          sortCols       - recommended sort columns
/          attributes     - col -> "`g#" or "`s#" string suggestions
/          rowBytes       - approximate per-row byte size
/          recommendations - human-readable string list
/          ingestCode     - template q ingest function string
/ @param proposal  {dict}  Output of proposeSchema[].
/ @return          {dict}  Ingestion strategy.
/ @example
/   p: .dataprofile.proposeSchema["/data/t.csv";",";500;"trades";100];
/   .dataprofile.suggestIngestion[p]
suggestIngestion: {[proposal]
    .dataprofile.logI_["suggestIngestion: ", proposal`tableName];
    typeMap: proposal`typeMap;

    dateCols: (key typeMap) where "d" = value typeMap;
    tsCols:   (key typeMap) where "p" = value typeMap;
    timeCols: (key typeMap) where "t" = value typeMap;
    symCols:  (key typeMap) where "*" = value typeMap;
    strCols:  (key typeMap) where " " = value typeMap;

    partitionCol: $[0 < count tsCols; first tsCols;
                   0 < count dateCols; first dateCols;
                   `];

    timelikeCols: $[0 < count tsCols; tsCols; timeCols];
    sortCols: distinct symCols, timelikeCols;

    attrMap: ()!();
    if[0 < count symCols;
        attrMap: attrMap, symCols!count[symCols]#enlist "`g#"
    ];
    if[0 < count timelikeCols;
        attrMap: attrMap, timelikeCols!count[timelikeCols]#enlist "`s#"
    ];

    storageMode: $[0 < count tsCols; "partitioned HDB (ts->date)";
                   0 < count dateCols; "partitioned HDB (date col)";
                   "in-memory"];

    rowBytes: sum .dataprofile.bytesForType_ each value typeMap;

    tname: proposal`tableName;
    recs: enlist "=== Schema proposal: ", tname, " ===";
    recs,: enlist "  Columns   : ", string proposal`colCount;
    recs,: enlist "  Rows read : ", string proposal`rowsSampled;
    recs,: enlist "  ~row bytes: ", string rowBytes;
    recs,: enlist "  Load expr : ", proposal`loadExpr;
    recs,: enlist "";
    recs,: enlist "--- Ingestion recommendations ---";
    recs,: enlist "  Storage   : ", storageMode;
    $[`~partitionCol;
        recs,: enlist "  [!] No date/timestamp column - recommend in-memory or splayed.";
        recs,: enlist "  [+] Partition by: `", string partitionCol
    ];
    if[not `~partitionCol;
        recs,: enlist "      .Q.dpfts[hsym`$hdbPath; date; `",
               string[partitionCol], "; tbl]"
    ];
    if[0 < count sortCols;
        recs,: enlist "  [+] Sort within partition: `",
               "` `" sv string sortCols
    ];
    if[0 < count symCols;
        recs,: enlist "  [+] Apply `g# to sym col(s): `",
               "` `" sv string symCols
    ];
    if[0 < count timelikeCols;
        recs,: enlist "  [+] Apply `s# to time/ts col(s): `",
               "` `" sv string timelikeCols
    ];
    if[0 < count strCols;
        recs,: enlist "  [~] String col(s) - lower symThresh to promote: `",
               "` `" sv string strCols
    ];
    recs,: enlist "";
    recs,: enlist "--- Column types ---";
    recs,: {"  ", string[x], "  (", enlist[y], ")"}'[key typeMap; value typeMap];

    partStr: $[`~partitionCol; ""; string partitionCol];
    loadExpr_: proposal`loadExpr;                / pre-assign to avoid dict-lookup-in-chain bug
    attrLine: $[0 < count symCols;
                 "  // xasc on: `", string[first symCols], "\n";
                 ""];
    ingestCode: "";
    if[`~partitionCol;
        ingestCode: "// Ingestion template: ", tname, "\n",
            "hdbPath: \"/path/to/hdb\";\n",
            "ingest", tname, ":{[path]\n",
            "  ", loadExpr_, ";\n",
            "  // No partition key - splayed:\n",
            "  hsym[`$hdbPath,\"/", tname, "/\"] set tbl;\n",
            "  }\n"
    ];
    if[not `~partitionCol;
        ingestCode: "// Ingestion template: ", tname, "\n",
            "hdbPath: \"/path/to/hdb\";\n",
            "ingest", tname, ":{[path]\n",
            "  ", loadExpr_, ";\n",
            "  date: first `date$tbl[`", partStr, "];\n",
            "  .Q.dpfts[hsym`$hdbPath; date; `", partStr, "; tbl];\n",
            attrLine,
            "  }\n"
    ];

    .dataprofile.logI_["suggestIngestion: done mode=", storageMode];
    `tableName`storageMode`partitionCol`sortCols`attributes`rowBytes`recommendations`ingestCode!
        (tname; storageMode; partitionCol; sortCols; attrMap; rowBytes; recs; ingestCode)
 }

// ---------------------------------------------------------------------------
// Module load confirmation
// ---------------------------------------------------------------------------

\d .
-1 "[dataprofile] module loaded - namespace .dataprofile";
-1 "[dataprofile] public API: peek inferSchema cast profile proposeSchema suggestIngestion";
