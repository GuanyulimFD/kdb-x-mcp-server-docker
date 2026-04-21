---
name: kdb-doc-review
description: "Use when: reviewing a q module or quke test file for documentation completeness or code quality; auditing alignment between BDD specs, q module implementation, quke tests, and README (knowledge drift check); performing expert KDB code review against standards of documentation, verbose coding, good use of overloads/iterations, and performance considerations; preparing or updating Confluence documentation for a module."
argument-hint: "Provide the module name to review, or paste the artefacts (BDD spec + .q module + .quke tests)"
---

# KDB Documentation & Review

## When to Use
- After a q module is implemented and tested — pre-merge review
- Periodic audit of the `q-modules/` library for documentation gaps
- Checking that a BDD spec, module code, quke tests, and README are telling the same story
- Preparing or structuring a Confluence page for a delivered module
- Reviewing a pull request / code change for KDB quality standards

---

## Procedure

### Step 1 — Gather Artefacts

Collect all of the following for the module under review. If any is missing, flag it immediately as a **Missing Artefact** gap:

| Artefact | Path | Required? |
|---------|------|----------|
| BDD specification | JIRA ticket or `.md` file from business analyst | Yes |
| Module implementation | `q-modules/<name>/<name>.q` | Yes |
| quke test suite | `q-modules/<name>/<name>.quke` | Yes |
| Module README | `q-modules/<name>/README.md` | Recommended |
| Module catalogue entry | `q-modules/README.md` — available modules table | Yes |

---

### Step 2 — Documentation Completeness Audit

For the `.q` file, verify every mandatory element from §9.2 of `copilot-instructions.md`.
Use the [Doc Standards Checklist](./references/doc-standards.md).

Produce a table:

| Element | Required | Present | Finding |
|---------|----------|---------|---------|
| File header block | Yes | ✅/❌ | |
| Namespace declaration (`\d .<name>`) | Yes | ✅/❌ | |
| Internal log helpers (`logI_`, `logW_`, `logE_`) | Yes | ✅/❌ | |
| Input guard helper (`require_`) | Yes | ✅/❌ | |
| Per-function `@desc` tag | Yes | ✅/❌ | |
| Per-function `@param` tags (one per param) | Yes | ✅/❌ | |
| Per-function `@return` tag | Yes | ✅/❌ | |
| Per-function `@throws` tag | Yes | ✅/❌ | |
| Per-function `@example` tag | Yes | ✅/❌ | |
| Entry/exit logging in each public function | Yes | ✅/❌ | |
| Load banner (last line before `\d .`) | Yes | ✅/❌ | |

**Result**: PASS (all required = ✅) | PARTIAL (some ❌) | FAIL (critical ❌)

---

### Step 3 — Sync Audit (Knowledge Drift Check)

Check consistency across all artefacts. A mismatch is a **Knowledge Drift Warning**.

#### 3a. BDD Scenarios → quke Tests
For each BDD `Scenario:` block, there must be at least one corresponding `should` block in the `.quke` file covering the same condition.

| BDD Scenario | Mapped quke `should` | Status |
|--------------|---------------------|--------|
| <scenario title> | <should title> | ✅ Covered / ❌ Missing |

#### 3b. quke Tests → Module Functions
Every function called in the `.quke` file must exist in the `.q` file with the matching signature.

| quke calls | Exists in module | Signature match |
|-----------|-----------------|----------------|
| `.<name>.fn[args]` | ✅/❌ | ✅/❌ |

#### 3c. Module Public API → README
Every public function in the `.q` file must appear in the module catalogue (`q-modules/README.md`) or the module's own `README.md`.

| Function | In `q-modules/README.md` | In module README |
|----------|--------------------------|-----------------|
| `.<name>.fn` | ✅/❌ | ✅/❌ |

#### 3d. Module Description → BDD Business Context
The purpose described in the `.q` file header must align with the business intent stated in the BDD specification. Flag any drift.

---

### Step 4 — Expert KDB Code Review

Apply the [Expert Review Checklist](./references/review-checklist.md). Rate each dimension:

| Dimension | Rating | Findings |
|-----------|--------|---------|
| Documentation accuracy | PASS / NEEDS WORK / FAIL | |
| Verbose coding (naming, intermediate vars) | PASS / NEEDS WORK / FAIL | |
| q idiom usage (iterators, projections, overloads) | PASS / NEEDS WORK / FAIL | |
| Error handling (protected eval, descriptive signals) | PASS / NEEDS WORK / FAIL | |
| Performance (partition pruning, attributes, `\ts` evidence) | PASS / NEEDS WORK / FAIL | |
| Logging discipline (entry/exit, no payload dumps) | PASS / NEEDS WORK / FAIL | |

For each **NEEDS WORK** or **FAIL** finding, provide:
- The exact code with the issue (quote the relevant lines)
- The specific principle being violated (cite §3.x of `copilot-instructions.md`)
- A concrete corrected version

---

### Step 5 — Confluence Page Draft

If Confluence access is available, post the page to the KDB Platform space.
If not, produce a Markdown draft suitable for manual upload.

Structure ([Doc Standards](./references/doc-standards.md) provides the full template):

```
# <Module Name>

## Purpose
<Business context — what problem does this module solve>

## Public API
| Function | Parameters | Returns | Description |
|----------|-----------|---------|-------------|

## Data Flow
<ASCII or Mermaid diagram showing inputs → processing → outputs>

## Usage Examples
<q code examples with expected output>

## Known Limitations
<edge cases not handled, performance caveats, FX/corporate action gaps>

## Changelog
| Version | Date | Author | Change |
```

---

### Step 6 — Review Report

Produce a structured review report as the final output:

```
## Review Report: <module-name>
Generated: <date>

### 1. Artefact Inventory
<list with ✅/❌ for each required artefact>

### 2. Documentation Completeness: PASS | PARTIAL | FAIL
<table from Step 2 with findings>

### 3. Knowledge Drift Audit: PASS | WARNINGS | FAIL
<findings from Step 3 — list each Knowledge Drift Warning>

### 4. Code Quality Review
<per-dimension ratings and findings from Step 4>

### 5. Recommended Changes
Priority: CRITICAL | HIGH | MEDIUM | LOW
1. [CRITICAL] <change> — <rationale referencing the violated principle>
2. [HIGH] ...

### 6. Confluence Draft
<Markdown page content, or "Posted to Confluence: <URL>">
```

---

### Step 7 — Update JIRA Memory File (MANDATORY)

> **Non-negotiable**: Every doc & review session MUST end by updating `.memory/jira/<TICKET-ID>.md`.
> The review report is only useful if it is traceable — future agents and contributors
> must be able to see what was reviewed, what was found, and what was fixed.

At the end of every session, update two sections of `.memory/jira/<TICKET-ID>.md`:

**1. Update `## Handover State`** — reflect review outcome:
```
**Current phase**: Doc & Review complete | Review in progress — <blocker>
**Blocked by**: <blocker or "nothing">
**Next action**: <e.g. "Developer to address CRITICAL findings before merge" or "Ready for merge">
```

**2. Tick the code review checklist item** in `### What is done`:
```
- [x] Code review complete
- [x] Docs / README updated   <- only if you made the fixes yourself
```

**3. Append a new dated entry to `## Work Log`**:
```
### <YYYY-MM-DD> — Doc & Review Session
**Agent / Author**: KDB Doc & Review skill
**Summary**:
- Artefacts reviewed: [list: .q module, .quke, README, BDD spec]
- Documentation completeness: [PASS | PARTIAL | FAIL] — [key findings]
- Knowledge drift: [PASS | WARNINGS | FAIL] — [key findings]
- Code quality: [overall rating] — [critical/high findings]
- Recommended changes: [count] — [CRITICAL: N, HIGH: N, MEDIUM: N, LOW: N]
- Changes made directly in this session: [list files edited, or "none — findings reported only"]
- Confluence draft: [produced / not applicable]

**Handed off to**: Developer to resolve findings | Ready for merge | Needs human decision on <topic>
```

---

## Scope

This skill reviews **existing artefacts** — it does not write new module code. For implementation, use the `kdb-developer` skill.
