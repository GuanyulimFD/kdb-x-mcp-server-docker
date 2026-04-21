# JIRA Ticket Template — KDB Platform Feature

Copy this template and fill in every section. Do not omit any section — write "N/A" and a brief reason if genuinely not applicable.

---

## Template

```
================================================================================
JIRA TICKET
================================================================================

Summary: [VERB] [subject] — one-line imperative description
  Example: "Implement daily VWAP calculation for symbol-level P&L benchmarking"

Issue Type:   Story | Bug | Task | Sub-task
Priority:     Critical | High | Medium | Low
Labels:       kdb-module | hdb | analytics | p&l | client-profile | behaviour | infra
Component:    q-modules | mcp-tools | hdb-pipeline | reporting
Sprint:       (leave blank — assigned by team lead)

--------------------------------------------------------------------------------
DESCRIPTION
--------------------------------------------------------------------------------

## Business Context
<One paragraph explaining WHY this feature is needed and how it fits the
 KDB T+1 HDB platform. Reference the business domain: P&L, client profile,
 or trading behaviour. Avoid technical implementation detail here.>

## User Story
As a <role>
I want <goal — what the system should do>
So that <value — what business outcome this enables>

--------------------------------------------------------------------------------
ACCEPTANCE CRITERIA
--------------------------------------------------------------------------------

Each criterion must be:
- Independently verifiable (can be checked without running other criteria)
- Testable by a quke `expect` assertion
- Specific about data types, null handling, and edge cases

AC1: <criterion>
AC2: <criterion>
AC3: <criterion>
...

--------------------------------------------------------------------------------
BDD SCENARIOS
--------------------------------------------------------------------------------

<Paste the full Gherkin from the BDD Specification artefact here>

--------------------------------------------------------------------------------
TECHNICAL NOTES
--------------------------------------------------------------------------------

## Candidate q-Modules
| Module | Namespace | Why Relevant |
|--------|-----------|-------------|
| <name> | .<name>   | <rationale> |

## HDB Tables Involved
| Table | Columns Used | Join Key |
|-------|-------------|---------|
| <table> | <cols> | <key> |

## Known Data Quality Constraints
- <any known nulls, gaps, or anomalies in the data>
- <FX / corporate action flags if relevant>

## Performance Considerations
- Estimated row count per partition: <N>
- Expected query latency SLA: <Xms / Xs>
- Partition pruning strategy: always filter on `date` first

--------------------------------------------------------------------------------
OUT OF SCOPE
--------------------------------------------------------------------------------

The following are explicitly NOT part of this ticket:
1. <item>
2. <item>

--------------------------------------------------------------------------------
OPEN QUESTIONS  (must be empty before handing off to developer)
--------------------------------------------------------------------------------

| # | Question | Owner | Status |
|---|----------|-------|--------|
| 1 | <question> | <name> | OPEN / RESOLVED |

================================================================================
```

---

## Acceptance Criteria Writing Rules

| Rule | Example |
|------|---------|
| Use active voice and present tense | "The function returns a table" not "A table will be returned" |
| Be numeric where possible | "VWAP is accurate to 8 decimal places" not "VWAP is accurate" |
| State null behaviour explicitly | "When no trades exist, an empty table (0 rows, correct schema) is returned" |
| State error behaviour explicitly | "Invalid date range raises an error with message containing 'end date'" |
| Avoid implementation terms | "The result groups by symbol" not "The result uses `by sym` in select" |

---

## Done Definition (DoD) for Developer Handover

A ticket is ready for developer handover when ALL of the following are true:

- [ ] Summary is a single imperative sentence
- [ ] User story has all three parts (role, goal, value)
- [ ] All acceptance criteria are written to the rules above
- [ ] BDD scenarios cover: happy path + at least one edge case + at least one error path
- [ ] Technical Notes section has at minimum: candidate modules and HDB tables
- [ ] Out of Scope section has at least one explicit entry
- [ ] Open Questions table is empty (all resolved)
