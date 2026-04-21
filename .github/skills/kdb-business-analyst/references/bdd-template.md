# BDD Specification Template

Use [Gherkin syntax](https://cucumber.io/docs/gherkin/reference/) for all scenarios. Every scenario block must be traceable to a user-provided requirement.

---

## File Header

```gherkin
# Feature: <feature-name>
# Jira: <TICKET-ID>
# Author: <name>
# Date: <YYYY-MM-DD>
# Platform: KDB T+1 HDB Tick Data Platform
# Modules: <comma-separated list of relevant q-modules>
```

---

## Feature Block Structure

```gherkin
Feature: <One-line description of the feature being specified>

  Background:
    # Data conditions that apply to ALL scenarios in this feature
    Given the HDB contains trade data for dates <start_date> to <end_date>
    And the instrument universe is <all | filtered by: ...>
    And the <module_name> q-module is loaded

  # ── Happy Path ────────────────────────────────────────────────────────────
  # Requirement: <cite the user-stated requirement>
  Scenario: <verb phrase describing normal behaviour>
    Given <precondition — data state or system state>
    When  <action — what the user/system does>
    Then  <outcome — what the result should be>
    And   <additional assertion>

  # ── Edge Case ─────────────────────────────────────────────────────────────
  # Requirement: <cite the user-stated requirement>
  Scenario: <edge case label>
    Given <degenerate data condition — e.g. no trades on requested date>
    When  <same action>
    Then  <graceful outcome — e.g. empty table returned, not an error>

  # ── Error / Boundary ──────────────────────────────────────────────────────
  # Requirement: <cite the user-stated requirement>
  Scenario: <error or invalid input label>
    Given <invalid precondition>
    When  <action with invalid input>
    Then  a descriptive error is raised
    And   the error message contains "<key phrase>"
```

---

## Data Shape Annotation Convention

Annotate expected column types in comments immediately below the `Then` line:

```gherkin
  Then the result is a table with columns:
    # sym   {symbol}  — instrument symbol
    # date  {date}    — trading date
    # vwap  {float}   — volume-weighted average price
    # vol   {long}    — total traded volume (shares)
```

---

## Worked Example — Trade VWAP by Symbol

```gherkin
# Feature: daily-vwap-by-symbol
# Jira: KDBP-42
# Author: Business Analyst
# Date: 2026-04-20
# Platform: KDB T+1 HDB Tick Data Platform
# Modules: finstat

Feature: Daily VWAP calculation for a single symbol over a date range

  Background:
    Given the HDB contains trade data for dates 2026-01-01 to 2026-01-31
    And the finstat q-module is loaded

  # Requirement: Traders need the VWAP per symbol per day to benchmark fill quality
  Scenario: Compute VWAP for a single symbol across a full month
    Given trades exist for symbol AAPL on every trading day in January 2026
    When  the user queries VWAP for AAPL from 2026-01-01 to 2026-01-31
    Then  a table is returned with one row per trading day
    And   each row contains columns date {date}, sym {symbol}, vwap {float}, volume {long}
    And   the vwap values satisfy: vwap = sum(price * size) % sum(size) per day

  # Requirement: behaviour on days with no trades must be defined
  Scenario: No trades exist for the requested symbol on a given date
    Given no trades exist for symbol XYZ on 2026-01-15
    When  the user queries VWAP for XYZ from 2026-01-15 to 2026-01-15
    Then  an empty table is returned (0 rows)
    And   no error is raised

  # Requirement: invalid date range must surface a clear error
  Scenario: End date is earlier than start date
    Given the HDB is available
    When  the user queries VWAP for AAPL from 2026-01-31 to 2026-01-01
    Then  an error is raised
    And   the error message contains "end date must not precede start date"
```

---

## ⚠ Open Question Marker

When a business rule is unclear or not yet confirmed by the user, mark it explicitly rather than filling it in:

```gherkin
  Then  ⚠ OPEN QUESTION: should zero-size trades be excluded from VWAP?
```

Never silently make an assumption. Every open question must be resolved before the ticket is marked ready.
