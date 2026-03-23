// KDB-X initialisation script
// Loaded automatically by start_kdbx.sh at service startup

// Load the AI module (KDB-X only - requires kx.ai)
.ai:use`kx.ai

// Initialise the SQL interface
.s.init[]

// ---------------------------------------------------------------------------
// Auto-load q-modules library
// ---------------------------------------------------------------------------
// All *.q files found directly inside the first-level sub-directories of the
// q-modules/ folder are loaded in alphabetical order.
// Set the environment variable KDBX_SKIP_Q_MODULES=1 to disable auto-loading
// (useful when starting a bare session for testing or debugging).
//
// The module root is resolved relative to this init script's own path so it
// works regardless of where KDB-X is started from.

if[not "1" ~ getenv `KDBX_SKIP_Q_MODULES;
    / Derive project root: strip "scripts/kdbx_init.q" from the full script path
    scriptPath: 1_ string hsym .z.f;
    projectRoot: "/" sv -2 _ "/" vs scriptPath;
    moduleRootStr: projectRoot, "/q-modules";
    -1 "[kdbx_init] scanning module root: ", moduleRootStr;
    moduleFiles: key hsym `$moduleRootStr;
    if[0 < count moduleFiles;
        {[mroot; subdir]
            sname: string subdir;
            mpath: mroot, "/", sname, "/", sname, ".q";
            if[count key hsym `$mpath;
                -1 "[kdbx_init] loading module: ", mpath;
                @[system; "l ", mpath;
                  {[p;e] -2 "[kdbx_init][ERROR] failed to load: ", p, " | ", e}[mpath]
                ]
            ]
        }[moduleRootStr] each moduleFiles
    ];
    -1 "[kdbx_init] q-modules scan complete"
 ];

// ---------------------------------------------------------------------------
// IPC query logging  (.z.pg / .z.ps)
// ---------------------------------------------------------------------------
// Log every incoming query from the MCP server (or any IPC client) so that
// both the Python-side log line and the q-side execution record land in the
// same unified log file.
//
// Format (stdout, fd -1):
//   [kdbx][QUERY]  <ts> h=<handle> ip=<client-ip> | <query-preview>
//   [kdbx][RESULT] <ts> h=<handle> elapsed=<ms>ms | ok | <type-char>
//   [kdbx][RESULT] <ts> h=<handle> elapsed=<ms>ms | error | <message>
//
// .z.pg — synchronous IPC (pykx SyncQConnection — the channel used by the MCP server)
// .z.ps — asynchronous IPC  (one-way messages)

/ Build a log-safe preview (up to 160 chars) of a raw q value
.mcp.previewRaw_:{[x] s:$[10h=type x;x;.Q.s1 x]; $[160<count s;(160#s),"...";s]}

/ Classify an incoming pykx IPC message and extract the meaningful payload.
/ pykx serialises tool calls over IPC as mixed lists of (func_str; arg...):
/   type 0h, count 2, x[0]=10h, x[1]=10h  =>  q_eval   (x[1] = user q code)
/   type 0h, count 3, x[0]=10h, x[1]=10h  =>  sql_query (x[1] = SQL string)
/   type 0h, count 2, x[0]=10h, x[1]=99h  =>  vector_search (x[1] = params dict)
/   type 10h                               =>  q_raw    (bare char-vector eval)
/   other mixed lists                      =>  pykx_init (internal pykx calls)
/ Returns dict: `tool`payload
/ Inner helper - handles count=2 wrappers (q_eval, vector_search, or pykx_init)
.mcp.c2_:{[x] arg:x 1; $[(2=count x)and 10h=type arg;`tool`payload!(`q_eval;.mcp.previewRaw_ arg);(2=count x)and 99h=type arg;`tool`payload!(`vector_search;$[`table in key arg;"table=",string arg[`table];"?"]);`tool`payload!(`pykx_init;.mcp.previewRaw_ x)]}
/ Main classifier
.mcp.classify_:{[x] $[10h=type x;`tool`payload!(`q_raw;.mcp.previewRaw_ x);(0h=type x)and(1<count x)and(10h=type first x);$[(3=count x)and 10h=type x 1;`tool`payload!(`sql_query;.mcp.previewRaw_ x 1);.mcp.c2_ x];`tool`payload!(`unknown;.mcp.previewRaw_ x)]}

/ Entry log line - shows tool type and the actual user payload
.mcp.logEntry_:{[ch;x] c:.mcp.classify_ x; -1 "[kdbx][QUERY] ",string[.z.p]," h=",string[.z.w]," ip=",("." sv string each `int$ 0x0 vs .z.a)," ",ch," tool=",string[c`tool]," | ",c`payload}

/ Synchronous handler — log entry, execute, log result, re-signal on error
.z.pg:{[x]
    .mcp.logEntry_["sync";x];
    t0:.z.p;
    / Protected eval: on error, store (1b; error_string); on ok (0b; result)
    r:@[{(0b;value x)};x;{[e](1b;e)}];
    ms:`int$1e-6*`long$.z.p-t0;
    $[first r;
        [
         -2 "[kdbx][RESULT] ",string[.z.p]," h=",string[.z.w],
            " elapsed=",string[ms],"ms | error | ",last r;
         'last r
        ];
        -1 "[kdbx][RESULT] ",string[.z.p]," h=",string[.z.w],
           " elapsed=",string[ms],"ms | ok | type=",string[type last r]
     ];
    last r
    }

/ Asynchronous handler — log and execute; errors go to stderr only
.z.ps:{[x]
    .mcp.logEntry_["async";x];
    t0:.z.p;
    @[value;x;{[e] -2 "[kdbx][ERROR] async h=",string[.z.w]," | ",e}];
    ms:`int$1e-6*`long$.z.p-t0;
    -1 "[kdbx][ASYNC] ",string[.z.p]," h=",string[.z.w],
       " elapsed=",string[ms],"ms | done";
    }

-1 "[kdbx_init] IPC query logging enabled (.z.pg / .z.ps)";

-1 "KDB-X service ready on port ", string system "p";
