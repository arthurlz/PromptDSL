# Phase 1 Findings

**Corpus:** 25 agents across finance, health, advice, knowledge, and misc one-offs.
All pass `promptc check` (legal DSL — friction means "can't express it," never a
syntax error). Ranking is by the number of agents that hit each gap, taken
mechanically from the inline `// FRICTION [category:slug]` tags
(`grep -rohE 'FRICTION \[[^]]*\]' corpus | sort | uniq -c | sort -rn`).

## Ranked gaps

| Gap (slug) | Category | Hits (N / 25) | Example file(s) | Possible feature (named, not designed) |
| --- | --- | --- | --- | --- |
| `input-params` | missing | 16 | `finance/earnings-analyst` (ticker), `advice/apology-writer` (tone) | a typed `input { ... }` block |
| `template` | repeated | 9 | `knowledge/pet-care-qa` + `plant-care-qa`, all `finance/*` | reusable agent template / shared skeleton |
| `long-text-input` | missing | 7 | `misc/legal-clause-explainer`, `health/nutrition-label-reader` | a named long-text/document input |
| `import` | repeated | 6 | `finance/dividend-safety`, `health/symptom-triage` (disclaimers) | `import` for shared disclaimers/rubrics |
| `multi-input` | missing | 4 | `misc/translation-quality-checker` (3 inputs), `advice/career-decision` | multiple named inputs |
| `float-type` | missing | 4 | `finance/valuation-screener`, `advice/budgeting-coach` | a `float`/`number` schema type |
| `verb-fit` | awkward | 4 | `advice/conflict-deescalation`, `misc/code-reviewer` | a generation verb (or just lean on `instruct`) |
| `conditional` | missing | 3 | `finance/options-strategy-advisor`, `health/symptom-triage` | conditional / branching steps |
| `range-constraint` | awkward | 2 | `finance/earnings-analyst` (score 0-100), `misc/translation-quality-checker` | field min/max constraints |
| `multi-output` | missing | 1 | `health/sleep-coach` | allow prose + json in one run |
| `interpolation` | missing | 1 | `finance/macro-brief` | `{{param}}` interpolation in goal/steps |
| `static-schema` | awkward | 1 | `misc/data-extractor` | caller-supplied output schema |

## Theme rollup

- **Inputs / parameters** (`input-params` + `long-text-input` + `multi-input` +
  `interpolation`): **25 / 25 agents.** Every single agent wanted to pass
  something in at run time. The single hardcoded `{{input}}` user message, plus
  baking specifics into the `goal` string, was the dominant pain across all
  domains.
- **Reuse** (`template` + `import`): **13 / 25 agents.** Structural repetition
  (role/goal/output skeleton) *and* content repetition (per-domain disclaimers
  and rubrics).

## Top-N for Phase 2

1. **Inputs / parameters (25/25).** A typed `input { ticker: string; tone: enum(...) }`
   block with `{{name}}` interpolation into `goal`/`step` text. Must cover single
   params, long-text bodies, and multiple inputs. This is the foundational missing
   piece — and it is also the precondition for Phase 4 (`promptc run` has to bind
   inputs to something).
2. **Reuse: `template` + `import` (13/25).** A reusable agent skeleton plus an
   `import` for shared disclaimers/rubrics. This is exactly the Phase 2 hint, now
   with evidence.
3. **Richer schema (small, high value):** a `float`/`number` type (4) and field
   range/min-max constraints (2). Cheap additions to the existing schema system.
4. **Lower priority / judgment calls:** conditional steps (3), a generation verb
   (4 — but `instruct` already works, so possibly a non-issue), `multi-output` (1),
   caller-supplied output schema (1).

## Notes / surprises

- **Hypothesis confirmed, emphatically.** The spec predicted typed inputs would be
  the #1 finding. 16/25 hit `input-params` directly and **25/25** want some input
  capability. Not a close call.
- **`import` ranked higher than expected (6).** Reuse isn't only structural —
  every finance/health/legal agent repeated a domain disclaimer ("not financial /
  medical / legal advice") and a shared output rubric. Content reuse deserves a
  first-class mechanism, not just `template`.
- **`float-type` (4) was unanticipated** by the spec but is real for finance and
  budgeting (ratios, money). Worth folding into the schema work.
- **`verb-fit` may be a false gap.** Generative tasks (draft/rewrite/review) don't
  have a named verb, but `instruct "..."` expresses them fine. Recommend *not*
  rushing a `generate` verb; revisit only if it keeps recurring.
- **`interpolation` is undercounted as a standalone slug (1)** — it is really
  implied by `input-params` (you must reference an input somewhere). Treat it as
  part of the inputs work, not a separate feature.
