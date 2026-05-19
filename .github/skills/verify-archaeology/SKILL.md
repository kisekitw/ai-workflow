---
name: verify-archaeology
description: >
  Inline evaluator and standalone auditor for /csharp-archaeology workflow.
  Simulates the /goal executor/evaluator loop: reads conversation claims,
  runs verify-outputs.ps1 for structural ground truth, cross-checks numbers,
  and returns PASS or GAPS with actionable fix instructions.
  ALWAYS use this skill when csharp-archaeology says "call /verify-archaeology",
  or when the user asks to "verify", "audit", or "check archaeology outputs".
---

# Verify Archaeology — Evaluator Skill

## Purpose

This skill acts as an **independent evaluator** in the `/csharp-archaeology` workflow.
It simulates the `/goal` executor/evaluator loop used in Claude Code:

- After each layer, `/csharp-archaeology` surfaces key facts in chat and calls this skill.
- This skill checks structural ground truth (via script) **and** cross-checks conversation claims against actual file contents.
- Returns `PASS` (advance to next phase) or `GAPS` (executor must fix before proceeding).

The loop repeats until `PASS`. Phase 0 is complete only when the final synthesis checkpoint returns `PASS`.

---

## Mode Detection (Auto)

**Mode A — Inline Evaluator** (default when called mid-session by csharp-archaeology):
- Conversation history shows `/csharp-archaeology` was running recently
- Has access to what the executor claimed in chat
- Runs targeted checks for the current layer only
- Does NOT write `verification-report.md`
- Returns compact verdict in chat

**Mode B — Standalone Audit** (when user calls `/verify-archaeology` directly with no prior csharp-archaeology context):
- No prior conversation assumed
- Runs full checks across all layers
- Writes `.analysis/verification-report.md` with full verdict
- Applies all semantic rules (SEM-1 through SEM-6)

---

## Step 0: Determine Target Workspace

Ask the user for `$TargetWorkspace` if not already known from context.
This is the root folder of the C# codebase being analysed (where `.analysis/` lives).

---

## Mode A — Inline Evaluator Protocol

### 1. Identify Current Layer

Read the most recent executor summary in the conversation.
Determine which layer just completed:
- Mentions "Layer 1 complete" or "global-map" → `layer1`
- Mentions a specific module Decision (e.g. "HMIWaferMap: Decision=Extract") → `layer2`
- Mentions "Phase 0 Synthesis complete" or "copilot-instructions-draft" → `synthesis`

### 2. Run Structural Check

Execute:
```powershell
.\.github\skills\csharp-archaeology\scripts\verify-outputs.ps1 `
    -TargetWorkspace "<TargetWorkspace>" `
    -Layer "<current_layer>"
```

Parse the JSON output. Note all `FAIL` and `WARN` results.

### 3. Cross-Check Conversation Claims vs Disk

Read the executor's most recent summary statement in chat. Extract claimed values and compare against `extractedFacts` from the script output:

| Claimed fact | Check against |
|---|---|
| "Found {N} projects" | `extractedFacts.dependencyMapTotalProjects` |
| "{N} islands" | `extractedFacts.islandCount` |
| "{N} dead candidates" | `extractedFacts.deadCandidateCount` |
| "Top hub: {Name} (score={S})" | `extractedFacts.topHubName` + `extractedFacts.topHubScore` |
| "Git: {A} ACTIVE / {S} STALE / {F} FROZEN" | `extractedFacts.gitActiveCount/Stale/Frozen` |
| "{ModuleName}: Decision={D}, Confidence={C}" | `extractedFacts.layer2Modules.{ModuleName}.extractedDecision/Confidence` |

Any discrepancy between claimed and actual = **MISMATCH gap**.

### 4. Return Verdict

**If all structural checks PASS and no MISMATCHes:**

```
## Verification Checkpoint: Layer {N}

**Structural check:** PASS ({n} checks)
**Conversation vs. disk cross-check:** PASS

### Result: PASS — Proceed to next phase
```

**If any FAIL or MISMATCH:**

```
## Verification Checkpoint: Layer {N}

**Structural check:** {n} FAIL, {n} WARN
**Conversation vs. disk cross-check:** {n} MISMATCH

### Result: GAPS — Do not advance yet

**Gaps found:**
1. [FAIL] {check-id} — {description}: {detail}
2. [MISMATCH] Conversation claimed "{claim}" but disk shows {actual}
3. ...

**Next action:** Fix all gaps above, then call `/verify-archaeology` again.
```

**If the same gap persists after 2 consecutive re-verify cycles, escalate:**

```
### ESCALATION: Same gap persists after 2 attempts

Gap: {description}
This gap has been flagged twice without resolution. Please check manually:
- {specific guidance for the gap}
User input required before proceeding.
```

---

## Mode B — Standalone Audit Protocol

### 1. Run Full Structural Check

Execute:
```powershell
.\.github\skills\csharp-archaeology\scripts\verify-outputs.ps1 `
    -TargetWorkspace "<TargetWorkspace>" `
    -Layer all
```

### 2. Apply Semantic Rules

For each Layer 2 module in `extractedFacts.layer2Modules`, apply semantic anomaly rules:

| Rule | Trigger condition | Anomaly message |
|---|---|---|
| SEM-1 | Decision=Delete AND (zeroCallerCount < 80% of apiCount OR testCallerCount > 0 OR git=ACTIVE) | "Delete recommended but safety conditions not met" |
| SEM-3 | Decision=Delete AND testCallerCount > 0 | "Delete but safety net exists (testCallerCount={n})" |
| SEM-6 | Confidence=HIGH AND Decision=Delete AND zeroCallerCount < 20% of apiCount | "HIGH confidence Delete but significant callers remain" |

> Note: SEM-2, SEM-4, SEM-5 require hubScore and namespace data not yet extracted by the script.
> Apply them manually by reading the relevant HTML/JSON if the user requests deep semantic audit.
> SEM rules referencing coupling-in.csv are downgraded to WARN due to the known inversion bug.

### 3. Determine Verdict

- **PASS**: all checks PASS, zero anomalies
- **PARTIAL**: some layers not yet present (files missing = not yet run), all completed layers pass
- **FAIL**: any check FAIL or any SEM anomaly

### 4. Write `.analysis/verification-report.md`

```markdown
---
verified_at: YYYY-MM-DD HH:mm
verdict: PASS | PARTIAL | FAIL
mode: standalone
---
# Verification Report — {DATE}

## Verdict: {PASS | PARTIAL | FAIL}

## Layer 0.5 — Preflight
| Check ID | Description | Result | Detail |
|---|---|---|---|
{preflight check rows}

## Layer 1 — Global Scan
| Check ID | Description | Result | Detail |
|---|---|---|---|
{layer1 check rows}

## Layer 2 — Modules
{for each discovered module:}
### {ModuleName}
| Check ID | Description | Result | Detail |
|---|---|---|---|
{module check rows}

**Semantic Anomalies:**
{list or "None"}

## Phase 0 Synthesis
| Check ID | Description | Result | Detail |
|---|---|---|---|
{synthesis check rows}

## Action Items
{Priority-ordered FAIL then WARN items, each with fix instructions}
```

Then summarize the verdict in chat.

---

## Edge Cases

| Situation | Handling |
|---|---|
| `.analysis/` missing entirely | Report fatalError; tell executor to re-run `step0-preflight.ps1` from the beginning |
| Truncated/corrupted JSON | Script reports FAIL with parse error; gap = "re-run the step that produced this file" |
| `coupling-in.csv` inverted bug | All coupling-in checks are WARN not FAIL; noted in output |
| No Layer 2 modules found | `layer2DiscoveredModules` empty; if Layer = layer2, report WARN "no module folders found under .analysis/" |
| Executor claimed facts but no script output (e.g., script failed) | Skip cross-check; only report structural FAIL from script |
| User calls this skill with no context | Default to Mode B (standalone audit) |
