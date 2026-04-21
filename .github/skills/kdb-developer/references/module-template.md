// ============================================================================
// Module Template — KDB-X 5.0
// Copy this template and replace all <PLACEHOLDER> values.
// Delete comment lines that start with // before saving the final module.
// ============================================================================

// ============================================================================
// File Header Block (MANDATORY)
// ============================================================================
/ Module:      <modulename>
/ Namespace:   .<modulename>
/ Description: <One-sentence description of what this module does>
/ Version:     0.1.0
/ Requires:    KDB-X 5.0+; <any other modules, e.g. finstat>
/ Author:      <your name or agent session ID>
/ Created:     <YYYY-MM-DD>
/ Updated:     <YYYY-MM-DD>

\d .<modulename>

// ============================================================================
// Internal Log Helpers (MANDATORY — define before any function that uses them)
// ============================================================================
/ Internal helpers — trailing underscore marks these as private
logI_:{ -1 "[<modulename>][INFO]  ", string[.z.p], " | ", x }
logW_:{ -1 "[<modulename>][WARN]  ", string[.z.p], " | ", x }
logE_:{ -2 "[<modulename>][ERROR] ", string[.z.p], " | ", x }

// ============================================================================
// Input Guard (MANDATORY)
// ============================================================================
/ @desc  Raise a descriptive signal when a precondition is violated.
/ @param cond  {boolean}  Condition that must be true to continue
/ @param msg   {string}   Error message to surface on violation
require_:{[cond; msg] if[not cond; logE_ msg; '"[<modulename>] ", msg]}

// ============================================================================
// Private Helpers (optional — add as needed)
// ============================================================================
/ @desc  <private helper description>
/ @param <name>  {<type>}  <description>
/ @return {<type>} <description>
privateHelper_:{[arg]
    / implementation
    arg
    }

// ============================================================================
// Public Functions
// ============================================================================

/ @desc  <One-sentence description of what this function does.>
/ @param <param1>  {<type>}  <description — e.g. sym {symbol} Instrument symbol>
/ @param <param2>  {<type>}  <description>
/ @return {<type>}  <description of return value and shape>
/ @throws if <describe the error condition that will be signalled>
/ @example
/   .<modulename>.myFunction[`AAPL; 2026-01-01; 2026-01-31]
myFunction:{[param1; param2]
    logI_ "myFunction: entry | param1=", string[param1], " param2=", string[param2];
    require_[0 < count param1; "param1 must not be empty"];
    / --- core logic ---
    result: param1;
    logI_ "myFunction: exit  | result rows=", string[count result];
    result
    }

// ============================================================================
// Module Load Banner (MANDATORY — must be last line before \d .)
// ============================================================================
\d .
-1 "[<modulename>] module loaded — namespace .<modulename>";
