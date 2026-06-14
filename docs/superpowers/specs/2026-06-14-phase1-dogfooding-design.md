# Phase 1 — Dogfooding Sprint (Design)

**Date:** 2026-06-14
**Status:** Design — awaiting review

## Context

The `promptc` MVP (a Prompt DSL → prose + OpenAI JSON compiler) is built and on
`main`. The owner laid out a 5-phase roadmap for what comes next:

1. **Dogfood** — write 20–30 real agents in the DSL; let real usage reveal what
   is awkward, what repeats, and what is missing. *(This spec.)*
2. **Find repeated patterns** — introduce `template` / `import` etc., driven by
   what Phase 1 surfaces, not by compiler-author speculation.
3. **Multi-model backends** — Anthropic / Gemini, only after the DSL has proven
   its value.
4. **Run** — `promptc run agent.prompt` (Compiler → Compiler + Runtime).
5. **Workflow** — `workflow { ... }`. Deliberately last; it is where the project
   most easily explodes.

Each phase is its own sub-project with its own spec. This document covers **only
Phase 1**, whose output (a ranked findings report) is the input to Phase 2.

**Guiding principle (the owner's):** *user needs drive language design, not
compiler-author self-indulgence.* Phase 1 exists to replace guessing with
evidence.

## Goal / outcome

Write 20–30 real agents against the **current** DSL and produce
`FINDINGS.md` — a frequency-ranked list of language gaps that directly feeds
Phase 2 brainstorming.

## Hard rules

1. **`lib/` is frozen for the entire sprint.** No grammar/semantics changes. Any
   "let me just add inputs real quick" impulse is deferred to Phase 2. This is
   the core discipline; violating it defeats the purpose.
2. **Intent first, then translate.** Each agent file begins with a short comment
   stating what it is *supposed* to express. Only then is it written in the
   current DSL. Wherever the DSL forces a compromise, a `// FRICTION:` note is
   recorded **at that spot, as it happens** (not reconstructed afterward).

## Current DSL capability boundary

Anything a real agent wants that falls outside this is friction:

- `agent "name" { ... }` — exactly one agent per file.
- `goal "..."` — required.
- `step { <verb> ["arg"] }` — verbs: `search`, `summarize`, `extract`,
  `translate`, `classify`, plus `instruct "..."`.
- `output text | markdown | json [ { typed schema } ]` — schema field types
  `string`/`int`/`bool`/`enum(...)`/`list<T>`, optional `?`.
- **Not available:** input parameters/variables, templates, imports,
  conditionals, multiple agents per file, model selection, anything dynamic. The
  compiled OpenAI request hardcodes the user message as `{{input}}`.

## Corpus structure

```
corpus/
  finance/      # cluster 1 (e.g. earnings analyst, valuation, dividend screen)
  health/       # cluster 2 (e.g. pollen/allergy advisor, symptom triage)
  advice/       # cluster 3 (e.g. relationship advice, life decisions)
  knowledge/    # cluster 4 (e.g. pet care Q&A, general explainer)
  misc/         # ~5 scattered one-offs (maximize "missing capability" signal)
FINDINGS.md
scripts/check-corpus.sh
```

- **Clusters (3–4 domains × ~5 agents)** surface *repetition* → the signal for
  Phase 2's `template`/`import`.
- **Scattered `misc/` one-offs** surface *missing capability* across breadth.
- Directory names are conventional; `corpus/` keeps the dogfooding set distinct
  from the canonical `examples/researcher.prompt`.

## Process (hybrid)

1. **Owner seeds 3–5 agents from scratch**, across a few different domains,
   *without* consulting `examples/` — written purely as the intent demands. Where
   the DSL won't express something, leave a TODO; Claude converts these to
   `// FRICTION:` notes.
2. **Claude expands** each seeded domain to ~5 agents and adds ~5 `misc/`
   one-offs, reaching 20–30 total. Every file follows the intent-first rule and
   records friction honestly.
3. **Aggregate** into `FINDINGS.md`.

## Friction capture

Inline, at the point of pain:

```
// intent: analyze a given ticker's latest earnings and rate it buy/hold/sell
// FRICTION: wanted a typed input `ticker: string`; DSL has no inputs, so the
//           ticker is baked into the goal text and can't be parameterized.
agent "earnings-analyst" { ... }
```

`FINDINGS.md`, sorted by hit count, one row per gap:

| Gap | Category (awkward / repeated / missing) | Hits (N / total) | Example(s) | Possible feature (named only, not designed) |

Closes with a "Top-N for Phase 2" starting point. Naming a possible feature is
allowed; *designing* it is Phase 2's job, not Phase 1's.

## The one piece of code

`scripts/check-corpus.sh` — runs `promptc check` over every `corpus/**/*.prompt`
and reports pass/fail counts, exiting non-zero if any file is invalid. This keeps
the corpus **legal DSL at all times** so that "friction" means "can't express
it," never "syntax typo." `// FRICTION:` uses the DSL's existing `//` line
comment, so annotated files still pass `check`.

## Success criteria

- 20–30 `.prompt` files, **all passing `promptc check`**.
- A frequency-ranked `FINDINGS.md` with real hit counts and concrete examples.
- Enough signal to open Phase 2 brainstorming immediately.

## Out of scope (later phases)

Grammar/semantics changes, `template`/`import`, multi-backend, `run`/runtime,
`workflow`. All deferred to their respective phases.

## A stated hypothesis (corpus decides, not this doc)

Because the user message is hardcoded to `{{input}}`, nearly every real agent
(finance wants a ticker, advice wants a situation, pet Q&A wants the question)
will likely want **typed input parameters** — predicted as the #1 finding. If the
corpus does *not* bear this out, that disconfirmation is itself useful signal.
The methodology, not this prediction, produces the ranking.
