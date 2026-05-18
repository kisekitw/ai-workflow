# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This repository is an **AI workflow toolkit** for analyzing and refactoring large legacy C# WinForms codebases. It contains agent skills designed for VS Code GitHub Copilot (`.github/skills/`) and HTML report templates (`docs/reports/`).

## Skills Architecture

Skills live in `.github/skills/<skill-name>/SKILL.md`. Each SKILL.md has a YAML front-matter `description` field that controls when the skill auto-activates. VS Code Copilot loads them on demand via the `/` command.

| Skill | Purpose |
|-------|---------|
| `/csharp-archaeology` | Phase 0 analysis — builds dependency maps, git stability scores, dead-code candidates; produces HTML reports |
| `/grill-me` | Decision stress-test — one question at a time, depth-first through a decision tree |
| `/grill-with-docs` | Like `/grill-me` but reads `CONTEXT.md` / `docs/adr/` first, updates them after each decision |
| `/zoom-out` | Explains how a narrow piece of code fits the broader system |
| `/handoff` | Writes a session handoff document to `docs/archaeology/handoff-[YYYYMMDD-HHmm].md` |

## csharp-archaeology Workflow

The skill executes in two layers against a **target** C# codebase (not this repo itself):

**Layer 1 — Global scan** (run once per project):
1. Write then execute `docs/archaeology/tmp/step1-dependency-map.ps1` → `dependency-map.json`
2. Write then execute `docs/archaeology/tmp/step2-git-stability.ps1` → `git-stability.csv`
3. Write then execute `docs/archaeology/tmp/step3-dead-scan.ps1` → `dead-candidates.csv`
4. AI reads the three output files and produces `docs/archaeology/00-global-map.html`

**Layer 2 — Module deep-dive** (per target module):
1. Write then execute `docs/archaeology/tmp/layer2-step1-api.ps1 -ModuleName "<Name>"` → `<Name>-api.json`
2. Write then execute `docs/archaeology/tmp/layer2-step2-usage.ps1 -ModuleName "<Name>"` → `<Name>-usage.csv`
3. AI produces `docs/archaeology/<ModuleName>-report.html`

**Critical rule:** Always write the `.ps1` file first and confirm it exists before executing it. Never inline scripts into the terminal.

## Boundary Rules (csharp-archaeology)

- Only process `.csproj`; skip `.vcxproj` (C++ projects)
- Skip analysis of `*Ex.csproj` internals, but keep them as dependency targets
- Dead-code candidates: `private`/`internal` only — never mark `public` (may be referenced by external DLLs)

## Report Templates

`docs/reports/` contains HTML infographic templates used as reference when generating new archaeology reports. They use IBM Plex Mono + Noto Sans TC and a fixed CSS variable palette (defined in each file's `:root`).

## Phase 0 Recommended Sequence

```
/grill-with-docs   → establish CONTEXT.md and shared vocabulary
/csharp-archaeology layer1  → global scan
/grill-me          → decide which modules to deep-dive
/csharp-archaeology layer2  → per-module deep-dive
/zoom-out          → when lost in a module, get system-level context
/handoff           → at session end
```
