---
name: zoom-out
description: >
  Tell the agent to zoom out and give broader context or a higher-level
  perspective on an unfamiliar section of code. Use when you are deep in
  a file or function and need to understand how it fits into the bigger
  picture, mentions "zoom out", "where does this fit", "what calls this",
  "explain the system around this", or "I'm lost in this code".
---

# Zoom Out

> Source: mattpocock/skills (MIT License)

When invoked, stop looking at the current narrow scope and zoom out to
explain the broader context.

## What To Do

1. **Identify the current scope** — what file, class, or function the
   user is looking at.

2. **Trace upward** — who calls this? What module owns it? What system
   does it belong to?

3. **Trace sideways** — what are the sibling modules? What do they do
   compared to this one?

4. **Explain the role** — in plain language, explain what role this code
   plays in the overall system. Use the language from `CONTEXT.md` if
   it exists.

5. **Point to the entry points** — where does a developer start if they
   want to change behaviour in this area?

## Output Format

```
## [ModuleName] — System Context

### What It Does
[One paragraph, plain language]

### Who Calls It
[List of callers with file paths]

### What It Depends On
[List of upstream dependencies]

### Where To Start
[The most important file/method to read first if you want to change this]

### Related Modules
[Sibling modules and how they differ]
```

## Notes for C# Legacy Codebases

- Check `.csproj` `<ProjectReference>` to find who depends on this module
- Check `using` statements at the top of `.cs` files to find upstream deps
- Designer.cs files are auto-generated — zoom out from the Form class instead
- If the module has an `Ex.csproj` variant, note it but focus on the main one
