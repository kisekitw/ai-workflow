---
name: handoff
description: >
  Compact the current conversation into a handoff document so another agent
  or team member can continue the work without losing context. Use when the
  user says "handoff", "write a handoff", "I need to switch sessions",
  "summarise this for the next person", or when a long session is ending
  and work is not yet complete.
---

# Handoff

> Source: mattpocock/skills (MIT License)

Write a handoff document summarising the current conversation so a fresh
agent can continue the work.

## Instructions

1. Save the document to a path produced by:
   ```
   mktemp -t handoff-XXXXXX.md
   ```
   Read the file before you write to it.

2. **Do not duplicate** content already captured in other artifacts
   (PRDs, plans, ADRs, issues, commits, diffs). Reference them by path
   or URL instead.

3. Suggest the skills to be used, if any, by the next session.

## Handoff Document Structure

```markdown
# Handoff — [short description of work]
Date: [ISO date]

## What We Were Doing
[1-3 sentences on the goal]

## Where We Got To
[Current state — what's done, what's in progress]

## Open Decisions
[List of unresolved questions or decisions, with context]

## Next Steps
[Ordered list of what to do next]

## Relevant Files / References
[Paths, URLs, or artifact references — no duplication of content]

## Suggested Skills for Next Session
[e.g. /grill-me, /csharp-archaeology, /characterize]
```
