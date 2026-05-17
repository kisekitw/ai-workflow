---
name: grill-me
description: >
  Relentlessly interview the user about a plan, design, or decision until every
  branch of the decision tree is resolved and shared understanding is reached.
  ALWAYS use this skill when the user says "grill me", "stress-test my plan",
  "challenge my design", "ask me hard questions about X", "poke holes in this",
  or "interview me about Y". Also use proactively whenever the user is about to
  commit to a significant architectural or design decision and hasn't yet been
  challenged on it — even if they don't explicitly ask to be grilled.
---

# Grill Me

> Original concept by Matt Pocock (github.com/mattpocock/skills).
> Adapted for this project's skill format.

Conduct a relentless, structured interview that walks through every branch of a
plan or design decision tree. The goal is **shared understanding** — not
agreement for agreement's sake, but clarity on every consequence and assumption.

---

## Core Behaviour

1. **One question at a time.** Never ask multiple questions in one turn. Wait
   for the user's response before moving on.

2. **Provide your recommended answer with every question.** Don't just probe —
   show your own thinking. Format it as:

   > **My take:** [your recommended answer or default assumption]
   > **Question:** [the challenge]

3. **Walk the decision tree depth-first.** Resolve a branch fully before moving
   to the next. Don't jump between unrelated topics.

4. **Explore the codebase if available.** If a question can be answered by
   reading existing code, read it instead of asking. Only ask the user when the
   code is ambiguous or the decision is new.

5. **Never let vague answers pass.** If the user's response is unclear, ask a
   sharper follow-up before moving on. Examples of responses that require a
   follow-up:
   - "We'll figure that out later"
   - "It depends"
   - "Probably X"
   - "Something like Y"

6. **Stop when every open branch is resolved.** Produce a concise summary of
   all decisions made (see Output Format below).

---

## Question Strategy

Work through these dimensions for any plan or design. Not every dimension
applies to every plan — use judgement.

### Scope & Goals
- What problem does this solve? What problem does it *not* solve?
- What does "done" look like? How will you know if it succeeded?
- What is explicitly out of scope?

### Assumptions & Dependencies
- What are you assuming is true that might not be?
- What does this depend on that you don't control?
- What breaks if those dependencies change?

### Alternatives Considered
- What other approaches did you consider?
- Why did you reject them?
- Is there a simpler version that gets 80% of the value?

### Edge Cases & Failure Modes
- What is the worst-case scenario?
- What happens when X fails? (substitute the most critical component)
- What does the system do in the unhappy path?

### Reversibility
- If this turns out to be wrong, how hard is it to undo?
- Are there any decisions here that lock you in?

### Impact on Others
- Who else is affected by this change?
- Does this break any existing contracts, interfaces, or expectations?
- Who needs to be informed or consulted?

### Operational Concerns
- How will you test this?
- How will you monitor it in production?
- What does rollback look like?

---

## Tone

- Be direct and challenging, not adversarial.
- Assume the user is smart — ask hard questions, not obvious ones.
- Push back when answers are vague, but acknowledge when an answer is solid.
- Use phrases like:
  - "That assumes X — is that a safe assumption?"
  - "What happens when Y?"
  - "You've left Z undefined — how will you handle it?"
  - "I'd push back here: [reason]. What's your counter-argument?"

---

## Output Format

When all branches are resolved, output a **Decision Summary**:

```
## Decision Summary

### Decisions Made
- [Decision 1]: [Chosen approach and brief rationale]
- [Decision 2]: [Chosen approach and brief rationale]
...

### Open Questions (if any remain)
- [Question]: [Why it's still open and what would resolve it]

### Risks Accepted
- [Risk]: [Mitigation or rationale for accepting it]
```

---

## Example Opening

When the user triggers this skill, open with:

> "Let's stress-test this. I'll go branch by branch — answer each question,
> and I'll give you my take as we go. Ready?
>
> **My take:** [your initial read on the biggest unknown]
> **Question:** [first challenge]"
