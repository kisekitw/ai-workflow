---
name: grill-with-docs
description: >
  Grilling session that challenges your plan against the existing domain model,
  sharpens terminology, and updates CONTEXT.md and ADRs inline as decisions
  crystallise. Use when user wants to stress-test a plan against their project's
  language and documented decisions, mentions "grill with docs", "interview me
  about this plan", or is about to make a significant architectural decision
  in an existing codebase.
---

# Grill With Docs

> Source: mattpocock/skills (MIT License)

Interview the user relentlessly about every aspect of this plan until reaching
shared understanding. Walk down each branch of the design tree, resolving
dependencies between decisions one-by-one. For each question, provide your
recommended answer. Ask the questions one at a time, waiting for feedback on
each question before continuing.

If a question can be answered by exploring the codebase, explore the codebase
instead of asking.

---

## Before Grilling — Read the Docs

During codebase exploration, look for existing documentation:

```
/
├── CONTEXT.md
├── docs/
│   └── adr/
│       ├── 0001-*.md
│       └── 0002-*.md
└── src/
```

If a `CONTEXT-MAP.md` exists at the root, the repo has multiple contexts:

```
/
├── CONTEXT-MAP.md
├── docs/
│   └── adr/          ← system-wide decisions
└── src/
    ├── ordering/
    │   ├── CONTEXT.md
    │   └── docs/adr/ ← context-specific decisions
    └── billing/
        ├── CONTEXT.md
        └── docs/adr/
```

---

## During Grilling — Maintain the Language

When the user uses a term that **conflicts** with the existing language in
`CONTEXT.md`, call it out immediately:

> "Your glossary defines 'cancellation' as X, but you seem to mean Y —
> which is it?"

When the user uses **vague or overloaded terms**, propose a precise canonical
term:

> "You're saying 'account' — do you mean the Customer or the User?
> Those are different things."

When **domain relationships** are being discussed, stress-test them with
specific scenarios.

---

## After Each Decision — Update the Docs Inline

Create files lazily — only when you have something to write.

- If no `CONTEXT.md` exists, create one when the first term is resolved.
- If no `docs/adr/` exists, create it when the first ADR is needed.

Use the format in `ADR-FORMAT.md` and `CONTEXT-FORMAT.md` if they exist.

**Do NOT write any code.** Do NOT implement anything. Do NOT start building
after the grilling ends. Your job is to resolve decisions and update docs only.

---

## Output

When all branches are resolved, produce:

1. Updated `CONTEXT.md` with new/refined terms
2. Any new ADRs in `docs/adr/`
3. A short **Decision Summary** listing what was decided and what remains open
