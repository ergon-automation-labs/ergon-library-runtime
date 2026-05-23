# Task Description Quality Guide

Factory_fixer and other autonomous systems succeed when task descriptions are clear, verifiable, and actionable. This guide helps create descriptions that enable reliable automation.

## Checklist: Task Quality Indicators

### 1. **Scope Clarity** ✓
- [ ] Task has a single, clear outcome (not "improve system")
- [ ] Title is imperative and specific (e.g., "Add NATS handler for X" not "Implement feature")
- [ ] No ambiguous terms ("polish", "enhance", "optimize" → define what that means)
- [ ] Scope is small enough for one person/system to complete in <1 day

**Good:** "Create NATS responder for bot_army.mcp.capabilities"
**Bad:** "Improve MCP system integration"

### 2. **Verification Block** ✓
Every task MUST have a ## Verification section with:
- [ ] **Acceptance Criteria** — what done looks like (testable conditions)
- [ ] **Test case** — concrete scenario (e.g., "Call endpoint with payload X, verify response Y")
- [ ] **Test command** — runnable command to verify (e.g., `nats request localhost:4222 bridge.mcp...`)

**Example:**
```
## Verification
Acceptance Criteria: NATS responder responds to queries with list of tools
Test case: Call bridge.mcp.capabilities with project_id, get array of {name, version, schema}
Test command: nats request localhost:4222 bridge.mcp.capabilities '{"project_id":"..."}'
```

### 3. **Dependencies & Context** ✓
- [ ] List what must exist first (parent task, other systems, configs)
- [ ] Don't assume domain knowledge (explain concepts briefly)
- [ ] Reference related tasks or docs (e.g., "See NATS subject schema in docs/...")
- [ ] Note any external APIs or services required

**Example:**
```
Depends on:
- bot_army_runtime >= 0.14.35 (for FactoryFixerQueue helper)
- NATS subject schema defined in docs/BRIDGE_SUBJECTS.md
```

### 4. **Actionable Requirements** ✓
- [ ] Use concrete, measurable language
- [ ] Break complex requirements into a checklist (helps factory_fixer decompose)
- [ ] Specify exact names/paths where relevant (not "create handler" but "create BotArmyMCP.Handler.Capabilities")

**Good:**
```
- [ ] Create handler module BotArmyMCP.Handlers.CapabilityRegistration
- [ ] Implement register_tool/2 function
- [ ] Add 12 unit tests covering success/failure paths
- [ ] Document schema in CLAUDE.md
```

**Bad:**
```
- [ ] Build capability registration
- [ ] Add tests
- [ ] Document it
```

### 5. **Test Approach** ✓
- [ ] Test command is runnable as-is (no environment setup needed)
- [ ] Test command doesn't require cleanup (idempotent)
- [ ] Includes both positive and negative cases
- [ ] Can be run in CI/automation context

**Good:** `mix test --only handlers --trace`
**Bad:** `run tests locally and check if it works`

### 6. **Outcome Clarity** ✓
- [ ] Result is mergeable code/PR OR deployed system OR documentation
- [ ] File paths/locations are exact
- [ ] Version bump plan is clear (if applicable)
- [ ] Success produces artifacts that can be checked (code, config, docs, NATS endpoint)

## Scoring: Task Description Quality

Use this rubric to rate a task (0-5):

| Aspect | 0 | 1 | 2 | 3 | 4 | 5 |
|--------|---|---|---|---|---|---|
| **Scope Clarity** | Vague | Broad | Somewhat clear | Clear | Very clear | Crystalline |
| **Verification** | None | Partial | Incomplete | Complete | Complete + examples | Complete + multiple scenarios |
| **Dependencies** | Hidden | Implied | Mentioned | Listed | Listed + versioned | Listed + linked |
| **Requirements** | Prose only | Mixed | Mostly checklist | Checklist | Checklist + details | Checklist + acceptance criteria |
| **Testability** | Manual only | Some automation | Mostly automated | Fully automated | Automated + idempotent | Automated + observable |

**Score:** Average of all aspects. Target: **4+** for factory_fixer pickup.

## Anti-Patterns

❌ **Too Vague:** "Improve performance" → Say "Reduce P95 NATS response latency from 500ms to <100ms"
❌ **No Test:** "Implement feature X" → Add `Test command: mix test --only feature_x --trace`
❌ **Hidden Dependencies:** Assumes reader knows about custom lib → "Requires bot_army_runtime >= 0.14.35 (see CHANGELOG)"
❌ **Ambiguous Scope:** "Polish the system" → "Fix 3 credo warnings and add 2 missing tests"
❌ **Manual-Only Testing:** "Check that it works" → Provide NATS request or CLI command

## Examples

### Example 1: High-Quality Task ✅

```
## Title
Add NATS responder for MCP capability discovery

## Description
Expose available tools/skills in an MCP project via NATS bridge façade.

### Requirements
- [ ] Create responder handler for bridge.mcp.capabilities request/reply
- [ ] Parse request payload: {project_id: uuid}
- [ ] Query capabilities from ProjectStore
- [ ] Return response: {tools: [{name, description, schema_version, status}], error?}
- [ ] Handle missing project gracefully (error response with reason)
- [ ] Add 15 unit tests (success, missing project, empty tools, pagination)

### Implementation Notes
- Use BotArmyRuntime.NATS.Publisher for responses
- Follow bridge subject contract in docs/BRIDGE_SUBJECTS.md
- Test with real NATS connection (@tag :nats_live)

## Verification
Acceptance Criteria: Clients can query project capabilities via NATS
Test case: Request bridge.mcp.capabilities with valid/invalid project_id
Test command: nats request localhost:4222 bridge.mcp.capabilities '{"project_id":"test-uuid"}'
Verification updated: 2026-05-23
```

### Example 2: Low-Quality Task ❌

```
## Title
Improve MCP system

## Description
Add more features to MCP and make it better. Should be faster and have better documentation.
```

**Problems:**
- Scope is unbounded
- No verification block
- No test command
- "Better" and "faster" undefined
- Would require retries by factory_fixer

## For Factory_Fixer Integration

Factory_fixer will:
1. **Score** incoming tasks on this rubric
2. **Reject** tasks with score < 3 (request description improvement)
3. **Attempt** tasks with score >= 4
4. **Log** success/failure ratios by score range (feedback loop)
5. **Suggest** description improvements based on failure patterns

This feedback loop helps the system learn what descriptions enable reliable automation.
