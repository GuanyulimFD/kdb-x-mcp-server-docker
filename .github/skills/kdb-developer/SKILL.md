---
name: kdb-developer
description: "Use when: implementing a new q/KDB module; developing or extending q functions for the HDB tick data platform; testing q syntax against a live KDB-X instance via kdbx_q_eval; writing qcumber (.quke) test suites from BDD specifications. CORE RULES: always scan kdb-knowhow.md first; never write q code to a file without first proving it works via kdbx_q_eval; design qcumber tests in a SEPARATE new session from module development."
argument-hint: "Paste the BDD spec and/or describe the q module to implement"
---

# KDB Developer

## When to Use
- Implementing a new `q-modules/<name>/<name>.q` module from a BDD specification
- Writing or debugging q functions interactively via `kdbx_q_eval`
- Designing qcumber test suites (`<name>.quke`) that map to BDD acceptance criteria
- Extending or refactoring an existing q module
- Debugging q errors surfaced during development

---

## Non-Negotiable Rules

1. **Scan kdb-knowhow.md first** — read `.github/kdb-knowhow.md` before writing any code; relevant entries save significant debug time
2. **Test before file** — every q expression must be verified via `kdbx_q_eval` before being written to a `.q` file; no exceptions
3. **JIT learning at code.kx** — when uncertain about q syntax, operator precedence, or KDB-X v5 behaviour, consult `https://code.kx.com/kdb-x/learn/q4m/` before guessing
4. **Isolated test session** — after the module is complete, start a **new conversation** to write qcumber tests; load only the BDD spec, not the module code, to ensure tests are specification-driven not implementation-driven

---

## Procedure

### Phase 0 — Pre-Development Orientation

1. Read `.github/kdb-knowhow.md` — filter for categories: `q-language`, `kdb-x-behaviour`, `module-dev`
2. Read the BDD specification thoroughly — map each acceptance criterion to a function responsibility
3. Review `q-modules/README.md` — identify existing modules to reuse (avoid reimplementing finstat, lookback, cron)
4. Check the [Module Template](./references/module-template.md) for the required file structure

---

### Phase 1 — Iterative Development via kdbx_q_eval

For every function, follow this strict loop:

```
DRAFT → kdbx_q_eval (isolate expression) → VERIFY → kdbx_q_eval (full function) → VERIFY → kdbx_q_eval (representative input) → PASS → write to file
```

#### 1a. Isolate the core expression first
Test the key computation in isolation — minimal input, no side effects:
```q
/ Example: test VWAP core formula before wrapping in a function
t:([]sym:`AAPL`AAPL`AAPL; price:100 102 101f; size:100 200 150)
(sum t[`price] * t[`size]) % sum t[`size]
```

#### 1b. Wrap in a function and verify signature
```q
calcVwap:{[t] (sum t[`price] * t[`size]) % sum t[`size]}
calcVwap[t]
```

#### 1c. Test edge cases via kdbx_q_eval before writing to file
```q
/ Empty table edge case
calcVwap[([]sym:`symbol$(); price:`float$(); size:`long$())]
```

#### 1d. Test HDB integration
Test against real partitioned data in the live HDB where applicable. Use the smallest date range that exercises the logic.

**Never transcribe code to a file until all three checks (1a, 1b, 1c) pass.**

---

### Phase 2 — Module Assembly

Assemble verified functions into the module file using the structure in [Module Template](./references/module-template.md).

Mandatory elements (see §9.2 of `copilot-instructions.md`):

| Element | Detail |
|---------|--------|
| File header block | Module name, Namespace, Description, Version, Requires, Author |
| `\d .<modulename>` | Namespace entry at top of module body |
| `logI_`, `logW_`, `logE_` | Internal log helpers with `[<module>]` prefix, using fd `-1`/`-2` |
| `require_` | Input guard — raises descriptive signal on any precondition violation |
| `/ @desc`, `/ @param`, `/ @return`, `/ @throws`, `/ @example` | Per-function doc tags |
| Entry/exit logging | `logI_` at function entry (key params) and exit (result summary) |
| `\d .` | Namespace exit at bottom |
| Load banner | `-1 "[<module>] module loaded — namespace .<module>"` |

**Naming conventions** (from §3.1 of `copilot-instructions.md`):
- Public functions: `lowerCamelCase`
- Private/internal: trailing underscore — `parseResult_`, `validateArgs_`
- Do NOT use leading-underscore prefix — `_name` is the q `drop` operator, not a prefix

---

### Phase 3 — Final Module Verification

Before handing off, run these checks via `kdbx_q_eval`:

```q
/ 1. Load the complete module cleanly
system "l q-modules/<name>/<name>.q"

/ 2. Verify the namespace is populated
key `.<name>

/ 3. Run each public function with representative inputs
.<name>.myFunction[<representative args>]

/ 4. Verify log output appears correctly (check fd -1 output)
/ 5. Verify error guard triggers on bad input
@[.<name>.myFunction; <bad args>; {show "error caught: ", x; 1b}]
```

---

### Phase 4 — Test Suite (MUST be a NEW Session)

> **CRITICAL**: Do not write the `.quke` file in the same session used to develop the module. The test session must be started fresh so that test scenarios are derived exclusively from the BDD spec, not from knowledge of the implementation.

**In the new session:**
1. Load only the BDD specification (paste the Gherkin scenarios)
2. Load `q-modules/README.md` for module context (but NOT the module source code)
3. Design `.quke` scenarios that map 1-to-1 to BDD acceptance criteria — each `Scenario:` in the BDD must produce at least one `should` block
4. Use `kdbx_q_unit_test` to run each scenario as you write it — fix and iterate
5. Save the passing test suite as `q-modules/<name>/<name>.quke`

**Required quke coverage per function:**
- Happy path — expected inputs produce the correct output value
- Edge case — empty table, single-row, boundary date, null value, n=1 window
- Error path — invalid arguments raise a signal: `@[fn; wrongArgs; {1b}]`

See example patterns in [Dev Workflow](./references/dev-workflow.md).

---

### Phase 5 — Record Insights

If you encountered any non-obvious KDB-X behaviour, q gotcha, or useful debugging approach during this session, append an entry to `.github/kdb-knowhow.md` following the format in §10.2 of `copilot-instructions.md`.

---

### Phase 6 — Update JIRA Memory File (MANDATORY)

> **Non-negotiable**: Every developer session MUST end by updating `.memory/jira/<TICKET-ID>.md`.
> This is the single source of truth for ticket progress across all agent sessions.
> Without it, the next agent (reviewer, tester, or developer continuing the work) must
> re-read the entire codebase to understand what has been done.

At the end of every session, update two sections of `.memory/jira/<TICKET-ID>.md`:

**1. Update `## Handover State`** — replace the current phase/next-action block:
```
**Current phase**: <phase name and brief status>
**Blocked by**: <blocker or "nothing">
**Next action**: <exact instruction for the next agent — be specific>
```

**2. Tick completed checklist items** in `### What is done`:
```
- [x] q-module implemented (`q-modules/<name>/<name>.q`)
- [ ] qcumber tests passing (`q-modules/<name>/<name>.quke`)   <- tick when done
```

**3. Append a new dated entry to `## Work Log`**:
```
### <YYYY-MM-DD> — Developer Session
**Agent / Author**: KDB Developer skill
**Summary**:
- Functions implemented: [list public + private functions]
- All expressions verified via kdbx_q_eval before writing to file: [yes/no]
- Acceptance criteria verified: [list ACs passed, e.g. AC1-AC10]
- Edge cases tested: [list]
- Key technical decisions: [e.g. workaround for multi-column `by` bug]
- kdb-knowhow.md updated: [yes/no — list entry titles if yes]

**Handed off to**: qcumber test session (NEW conversation) | Blocked on <reason>
```

#### What counts as a complete Developer session Work Log entry

- Every public and private function name that was implemented
- Which ACs from the JIRA ticket were verified (by number)
- Any workarounds or non-obvious implementation choices (so the reviewer does not flag them as bugs)
- Whether kdb-knowhow.md was updated and what was added
- The exact next action phrased as an instruction (e.g. "Start NEW session, load BDD spec only, write tca.quke")

---

## Functional Programming Guidelines (Summary)

From §3.2 of `copilot-instructions.md` — key rules:
- Prefer **projections** over thunks: `f[;constArg]` not `{[x] f[x;constArg]}`
- Reach for **iterators** before loops: `each`, `over`, `scan`, `peach`; use `while`/`do` only when iteration count is genuinely data-dependent
- Use **each-right / each-left** (`/:`, `\:`) for broadcasting
- Keep lambdas under ~10 lines; extract named helpers beyond that
- **No global mutation** inside lambdas

## Performance Rules (Summary)

From §3.5 of `copilot-instructions.md`:
1. Filter on partition column (`date`) first in every select/`?[]`
2. Project only needed columns before joins or aggregations
3. Apply `` `p# `` on primary grouping column of splayed tables
4. Replace `each` with `peach` for CPU-bound per-partition work
5. Profile with `\ts:n` before optimising — never guess
