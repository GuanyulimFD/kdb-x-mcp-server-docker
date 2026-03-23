// =============================================================================
// Module      : cron
// Namespace   : .cron
// Description : Timer-driven cron job scheduler for KDB/q.
//
//   Jobs are stored in an in-memory table.  A `.z.ts` timer hook fires on a
//   configurable interval and evaluates every non-disabled job whose current
//   wall-clock time falls within its [startTime, endTime] window and whose
//   inter-execution period has elapsed.
//
//   Public API
//   ----------
//   add             Register a new cron job
//   remove          Remove a job by name
//   enable          Clear the disabled flag on a job
//   disable         Set the disabled flag on a job
//   list            Return the jobs table (snapshot)
//   setPeriod       Set the minimum inter-execution period (ms) for a job
//   setTimerMs      Set the system timer interval (wraps system "\t N")
//   start           Activate the timer and wire .z.ts to the cron tick
//   stop            Deactivate the timer and unwire .z.ts
//
//   Jobs table schema
//   -----------------
//   name       {symbol}     Unique job identifier
//   startTime  {time}       Earliest wall-clock time job may run each day
//   endTime    {time}       Latest wall-clock time; 0Nt = no upper bound
//   fn         {lambda}     Zero- or multi-arg function to invoke
//   args       {list}       Arguments applied via fn . args; () = call fn[]
//   period     {long}       Minimum ms between executions; 0 = every tick
//   disabled   {boolean}    1b = skip this job in every tick
//   lastRun    {timestamp}  Timestamp of most recent execution; 0Np = never
//
// Version  : 0.1.0
// Requires : KDB/q 4.x+ (compatible with KDB-X 5.0)
// Author   : kdb-x-mcp-server
// =============================================================================

\d .cron

// ---------------------------------------------------------------------------
// Internal logging helpers
// ---------------------------------------------------------------------------
/ All messages prefixed with [cron] for easy grep in mixed logs.

logI_: {if[0 < count x; -1 "[cron][INFO]  ", string[.z.p], "  ", x]}
logW_: {if[0 < count x; -1 "[cron][WARN]  ", string[.z.p], "  ", x]}
logE_: {if[0 < count x; -2 "[cron][ERROR] ", string[.z.p], "  ", x]}

// ---------------------------------------------------------------------------
// Internal guard helper
// ---------------------------------------------------------------------------

/ @desc Raise a descriptive error when a precondition is violated.
require_:{[cond;msg]
    if[not cond;
        .cron.logE_ msg;
        '"[cron] ", msg
    ]
 }

// ---------------------------------------------------------------------------
// Module state
// ---------------------------------------------------------------------------

/ Jobs table — columns match the schema above.
/ fn and args use generic (type 0) columns to accommodate any callable/value.
jobs:([]
    name      : `symbol$();
    startTime : `time$();
    endTime   : `time$();
    fn        : ();
    args      : ();
    period    : `long$();
    disabled  : `boolean$();
    lastRun   : `timestamp$()
    )

/ System timer interval in milliseconds (default 1 000 ms).
INTERVAL_: 1000

/ Saved copy of any .z.ts hook that existed before start[] was called.
/ Allows chaining with other timer users.
prevTs_: (::)

/ Flag indicating whether the cron scheduler is currently running.
running: 0b

// ---------------------------------------------------------------------------
// add  — register a new cron job
// ---------------------------------------------------------------------------

/ @desc   Insert a new job into the jobs table.  The job is active immediately
/         if disabled is 0b and the scheduler has been started.
/ @param  name      {symbol}   Unique job name.  Errors if already registered.
/ @param  startTime {time}     Earliest time to run each day.
/ @param  endTime   {time}     Latest time to run; pass 0Nt for no upper bound.
/ @param  fn        {lambda}   Function to call.  Must accept 0 args if args=().
/ @param  args      {list}     Argument list applied via fn . args; () = fn[].
/ @param  disabled  {boolean}  Start disabled (1b) or active (0b).
/ @return {symbol}             The job name (echo of input).
/ @throws if name is already registered.
/ @example
/   .cron.add[`heartbeat; 09:00:00.000; 17:30:00.000; {-1 "ping"}; (); 0b]
add:{[jname;startTime;endTime;fn;args;disabled]
    .cron.logI_["add: name=", string[jname], " start=", string[startTime],
        " end=", string[endTime], " disabled=", string[disabled]];
    .cron.require_[not jname in .cron.jobs`name;
        "add: job '", (string jname), "' already registered"];
    .cron.require_[-11h = type jname;       "add: name must be a symbol scalar"];
    .cron.require_[-19h = type startTime;  "add: startTime must be a time scalar"];
    .cron.require_[-1h = type disabled;    "add: disabled must be a boolean scalar"];
    newRow:([] name:enlist jname; startTime:enlist startTime;
        endTime:enlist endTime; fn:enlist fn; args:enlist args;
        period:enlist 0j; disabled:enlist disabled; lastRun:enlist 0Np);
    `.cron.jobs upsert newRow;
    .cron.logI_["add: registered job '", string[jname], "'"];
    jname
 }

// ---------------------------------------------------------------------------
// remove  — delete a job by name
// ---------------------------------------------------------------------------

/ @desc   Remove the named job from the scheduler.  No-op if not found.
/ @param  name {symbol}  Job name to remove.
/ @return {symbol}       The job name.
/ @example
/   .cron.remove[`heartbeat]
remove:{[jname]
    .cron.logI_["remove: name=", string jname];
    delete from `.cron.jobs where name = jname;
    .cron.logI_["remove: job '", string[jname], "' removed (or was not present)"];
    jname
 }

// ---------------------------------------------------------------------------
// enable / disable  — toggle job active state
// ---------------------------------------------------------------------------

/ @desc   Clear the disabled flag so the job participates in tick evaluation.
/ @param  name {symbol}  Job name.
/ @return {symbol}       The job name.
/ @throws if the job does not exist.
/ @example
/   .cron.enable[`heartbeat]
enable:{[jname]
    .cron.require_[jname in .cron.jobs`name;
        "enable: job '", (string jname), "' not found"];
    update disabled:0b from `.cron.jobs where name = jname;
    .cron.logI_["enable: job '", string[jname], "' enabled"];
    jname
 }

/ @desc   Set the disabled flag so the job is skipped during tick evaluation.
/ @param  name {symbol}  Job name.
/ @return {symbol}       The job name.
/ @throws if the job does not exist.
/ @example
/   .cron.disable[`heartbeat]
disable:{[jname]
    .cron.require_[jname in .cron.jobs`name;
        "disable: job '", (string jname), "' not found"];
    update disabled:1b from `.cron.jobs where name = jname;
    .cron.logI_["disable: job '", string[jname], "' disabled"];
    jname
 }

// ---------------------------------------------------------------------------
// list  — return a snapshot of the jobs table
// ---------------------------------------------------------------------------

/ @desc   Return a copy of the current jobs table.
/ @return {table}  Snapshot of all registered jobs.
/ @example
/   .cron.list[]
list:{[] .cron.jobs}

// ---------------------------------------------------------------------------
// setPeriod  — set minimum inter-execution period
// ---------------------------------------------------------------------------

/ @desc   Override the period (minimum ms between executions) for a job.
/         period=0 means the job runs on every timer tick within its window.
/ @param  name   {symbol}  Job name.
/ @param  millis {long}    Period in milliseconds; must be >= 0.
/ @return {symbol}         The job name.
/ @throws if job not found or millis < 0.
/ @example
/   .cron.setPeriod[`heartbeat; 5000]   / run at most every 5 s
setPeriod:{[jname;millis]
    .cron.require_[jname in .cron.jobs`name;
        "setPeriod: job '", (string jname), "' not found"];
    .cron.require_[millis >= 0;
        "setPeriod: millis must be >= 0"];
    update period:millis from `.cron.jobs where name = jname;
    .cron.logI_["setPeriod: job '", string[jname], "' period=", string[millis], " ms"];
    jname
 }

// ---------------------------------------------------------------------------
// setTimerMs  — configure the system timer interval
// ---------------------------------------------------------------------------

/ @desc   Set the KDB system timer to fire every N milliseconds.
/         This calls `system "\t N"` and records the value in INTERVAL_.
/         If N <= 0 the timer is stopped (system "\t 0").
/ @param  millis {long}    Timer interval in ms; 0 to stop.
/ @return {long}           The value that was applied.
/ @example
/   .cron.setTimerMs[500]    / fire every 0.5 s
setTimerMs:{[millis]
    .cron.logI_["setTimerMs: ", string[millis], " ms"];
    .cron.INTERVAL_:: millis;
    system "t ", string millis;
    millis
 }

// ---------------------------------------------------------------------------
// processRow_  — execute one job row (internal)
// ---------------------------------------------------------------------------

/ @desc   Protected invocation of a single job's fn with its args.
/         Updates lastRun on success.  Logs but does not re-throw on error.
/ @param  row {dict}  A single row from the jobs table (symbol-keyed dict).
processRow_:{[row]
    nm: row`name;
    fn: row`fn;
    a:  row`args;
    .cron.logI_["processRow_: executing job '", string[nm], "'"];
    .[
        {[fn;a] $[0 = count a; fn[]; fn . a]};
        (fn; a);
        {[nm;err]
            .cron.logE_["processRow_: job '", string[nm], "' error: ", err]
         }[nm]
    ];
    update lastRun:.z.p from `.cron.jobs where name = nm;
    .cron.logI_["processRow_: job '", string[nm], "' done"]
 }

// ---------------------------------------------------------------------------
// tick_  — main timer callback (internal)
// ---------------------------------------------------------------------------

/ @desc   Fired by .z.ts on every timer tick.
/         Selects all non-disabled jobs whose time window and period criteria
/         are satisfied, then executes each via processRow_.
tick_:{[]
    now: .z.t;
    ts:  .z.p;
    / Select jobs within their time window
    inWindow: select from .cron.jobs where
        not disabled,
        startTime <= now,
        (null endTime) or endTime >= now;
    / Further filter by period: run if period=0, or never run, or elapsed >= period
    due: select from inWindow where
        (period = 0) or
        (null lastRun) or
        (`long$(ts - lastRun)) >= period * 1000000;
    if[0 < count due;
        .cron.logI_["tick_: ", string[count due], " job(s) due at ", string now];
        .cron.processRow_ each due
    ]
 }

// ---------------------------------------------------------------------------
// start  — activate the cron scheduler
// ---------------------------------------------------------------------------

/ @desc   Wire .z.ts to the cron tick function and start the system timer.
/         Any pre-existing .z.ts hook is saved and chained so other timer
/         users are not disrupted.
/ @param  millis {long}  Timer interval in ms (0 uses existing INTERVAL_).
/ @return {boolean}      1b on success.
/ @example
/   .cron.start[1000]
start:{[millis]
    if[.cron.running;
        .cron.logW_["start: scheduler already running"];
        :(::)
    ];
    / Save existing .z.ts if any
    if[not (::) ~ .z.ts; .cron.prevTs_:: .z.ts];
    / Wire tick — chain previous hook if one existed
    .z.ts:{[]
        .cron.tick_[];
        if[not (::) ~ .cron.prevTs_; .cron.prevTs_[]]
     };
    / Set interval
    interval: $[millis > 0; millis; .cron.INTERVAL_];
    .cron.INTERVAL_:: interval;
    system "t ", string interval;
    .cron.running:: 1b;
    .cron.logI_["start: cron scheduler started, interval=", string[interval], " ms"];
    1b
 }

// ---------------------------------------------------------------------------
// stop  — deactivate the cron scheduler
// ---------------------------------------------------------------------------

/ @desc   Stop the system timer and restore any previously chained .z.ts.
/ @return {boolean}  1b on success.
/ @example
/   .cron.stop[]
stop:{[]
    if[not .cron.running;
        .cron.logW_["stop: scheduler is not running"];
        :(::)
    ];
    system "t 0";
    / Restore previous .z.ts or clear it.
    / NOTE: .[`.z;`ts;:;(::)] is rejected by KDB-X 5.0 — use direct assignment.
    $[(::) ~ .cron.prevTs_;
        [.z.ts::(::)];
        [.z.ts: .cron.prevTs_; .cron.prevTs_:: (::)]
    ];
    .cron.running:: 0b;
    .cron.logI_["stop: cron scheduler stopped"];
    1b
 }

// ---------------------------------------------------------------------------
// Module load confirmation
// ---------------------------------------------------------------------------

\d .
-1 "[cron] module loaded — namespace .cron";
-1 "[cron] public API: add remove enable disable list setPeriod setTimerMs start stop";
