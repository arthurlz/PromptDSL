# Phase 1 — Dogfooding Sprint Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Write 20–30 real agents against the frozen MVP DSL and produce a frequency-ranked `FINDINGS.md` of language gaps that drives Phase 2.

**Architecture:** A `corpus/` of `.prompt` files grouped into domain clusters plus scattered one-offs. Every file is *intent-first*: a comment states what it should express, then the current DSL is used, and each forced compromise is recorded inline with a greppable `// FRICTION [category:slug]:` tag. A small `scripts/check-corpus.sh` keeps every file legal DSL. Findings are aggregated by grepping/tallying the tags — mechanical, not subjective.

**Tech Stack:** the existing `promptc` binary (`dune build` → `_build/default/bin/main.exe`), bash, Markdown.

**Spec:** `docs/superpowers/specs/2026-06-14-phase1-dogfooding-design.md`

---

## Hard rules (carry into every task)

- **`lib/` is frozen.** No grammar/semantics changes for the entire sprint. If an agent can't express something, that's a FRICTION note — never a code change.
- **Intent first.** Each file opens with `// intent:` (what it should do), then the DSL. Where the DSL falls short, add a FRICTION tag *at that spot*.
- Every `.prompt` must pass `promptc check` (it must be legal — a compromised-but-valid agent, never a syntax error).

## FRICTION tag convention (enables mechanical ranking)

```
// FRICTION [<category>:<slug>]: one-line explanation of what was wanted vs. possible
```
- `<category>` ∈ `missing` (no capability) | `repeated` (had to copy/paste structure) | `awkward` (expressible but clumsy).
- `<slug>` is a stable kebab name for the gap, e.g. `inputs`, `multi-input`, `range-constraint`, `template`, `import`, `model-select`, `tone-param`, `long-text-input`.
- Aggregation is then `grep -roh 'FRICTION \[[^]]*\]' corpus | sort | uniq -c | sort -rn` → hits per gap.

## DSL capability boundary (anything beyond this = friction)

`agent "name" { goal "..."; step { <verb> ["arg"] }*; output text|markdown|json [ {schema} ] }`, verbs `search|summarize|extract|translate|classify|instruct`, schema types `string|int|bool|enum(...)|list<T>` with optional `?`. No inputs/vars, templates, imports, conditionals, model choice, or multiple agents per file. User message is hardcoded `{{input}}`.

## File map

```
scripts/check-corpus.sh          # validate every corpus/**/*.prompt
corpus/finance/*.prompt          # cluster (~5)
corpus/health/*.prompt           # cluster (~5)
corpus/advice/*.prompt           # cluster (~5)
corpus/knowledge/*.prompt        # cluster (~5)
corpus/misc/*.prompt             # ~5 scattered one-offs
FINDINGS.md                      # ranked report
```

---

### Task 1: Scaffold + check-corpus.sh

**Files:**
- Create: `scripts/check-corpus.sh`
- Create: `corpus/.gitkeep` (so empty dirs are tracked until files land)

- [ ] **Step 1: Write the script**

`scripts/check-corpus.sh`:
```bash
#!/usr/bin/env bash
# Validate that every corpus/**/*.prompt is legal DSL (promptc check passes).
set -uo pipefail
cd "$(dirname "$0")/.."   # repo root

dune build bin/main.exe 2>/dev/null || { echo "build failed"; exit 1; }
BIN=_build/default/bin/main.exe

pass=0; fail=0; failed=()
while IFS= read -r f; do
  [ -z "$f" ] && continue
  if "$BIN" check "$f" >/dev/null 2>&1; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); failed+=("$f")
  fi
done < <(find corpus -name '*.prompt' 2>/dev/null)

echo "corpus check: $pass passed, $fail failed"
if (( fail > 0 )); then
  printf '  FAIL: %s\n' "${failed[@]}"
  exit 1
fi
```

- [ ] **Step 2: Make it executable and create the corpus dir**

Run:
```bash
chmod +x scripts/check-corpus.sh
mkdir -p corpus/finance corpus/health corpus/advice corpus/knowledge corpus/misc
touch corpus/.gitkeep
```

- [ ] **Step 3: Smoke-test both paths of the script**

Run:
```bash
printf 'agent "ok" { goal "g" }\n' > corpus/_smoke_ok.prompt
printf 'agent "bad" { step { summarize } }\n' > corpus/_smoke_bad.prompt   # missing goal
./scripts/check-corpus.sh; echo "exit=$?"
```
Expected: prints `corpus check: 1 passed, 1 failed`, lists the bad file, `exit=1`.

- [ ] **Step 4: Remove smoke files, confirm clean empty-corpus run**

Run:
```bash
rm corpus/_smoke_ok.prompt corpus/_smoke_bad.prompt
./scripts/check-corpus.sh; echo "exit=$?"
```
Expected: `corpus check: 0 passed, 0 failed`, `exit=0`.

- [ ] **Step 5: Commit**

```bash
git add scripts/check-corpus.sh corpus/.gitkeep
git commit -m "chore(corpus): add dogfooding corpus scaffold and check-corpus.sh"
```

---

### Task 2: Owner seeds 3–5 agents (HUMAN CHECKPOINT)

**This task is performed by the project owner, not the agent.** The executing agent/controller STOPS here and hands off.

- [ ] **Step 1: Owner writes 3–5 `.prompt` files from scratch**

Instructions to give the owner:
- Pick a few different domains you care about (finance, health, advice, knowledge, or anything).
- Write each agent **the way you actually want to express it.** Do NOT open `examples/researcher.prompt` first.
- Put files under the matching `corpus/<domain>/` (create a new domain dir if needed).
- Start each file with `// intent: <what it should do>`.
- Wherever the DSL won't let you say what you mean, just write `// TODO: <what you wanted>` inline and move on — the next task converts these to FRICTION tags.
- It's fine (expected) if a file can't be made to compile yet; leave the TODO.

- [ ] **Step 2: Owner signals done**

Owner says which files they wrote. Proceed to Task 3.

---

### Task 3: Normalize the seeds (intent → FRICTION, make them legal)

**Files:**
- Modify: the owner's seed files under `corpus/**/*.prompt`

- [ ] **Step 1: For each seed, convert TODOs to FRICTION tags and make it pass `check`**

For each owner file:
- Turn every `// TODO:` into a `// FRICTION [category:slug]:` line using the convention above (pick the category/slug that names the gap).
- If the file currently fails `promptc check` because the intent couldn't be expressed, rewrite the agent body into the closest **legal** approximation (a valid, if compromised, agent) and record the compromise as FRICTION. The file must end up legal; the loss is captured in the tag, not in a broken file.
- Do NOT invent capabilities or change `lib/`.

- [ ] **Step 2: Validate**

Run: `./scripts/check-corpus.sh`
Expected: all seed files counted in `passed`, `0 failed`, exit 0.

- [ ] **Step 3: Commit**

```bash
git add corpus
git commit -m "corpus(seeds): normalize owner seeds, tag friction"
```

---

### Task 4: Expand seeded clusters to ~5 each

**Files:**
- Create: additional `corpus/<domain>/*.prompt` in each domain the owner seeded, to reach ~5 per cluster.

Follow this **worked example** for format (intent comment → DSL → FRICTION tags). It is a complete, legal file:

`corpus/finance/earnings-analyst.prompt`:
```
// intent: given a ticker, fetch its latest earnings, analyze, and output a
//   buy/hold/sell rating with a 0-100 score and a short rationale.
// FRICTION [missing:inputs]: wanted a typed input `ticker: string`; the DSL has
//   no input params, so the ticker is baked into the goal text and the prompt
//   can't be reused for another ticker without editing the source.
// FRICTION [missing:range-constraint]: score should be 0-100; json int field
//   works but there's no way to constrain its range.
agent "earnings-analyst" {
  goal "Analyze the latest quarterly earnings for TSLA and rate the stock."

  step { search "TSLA latest quarterly earnings report" }
  step { extract "revenue, EPS, guidance, margins vs. expectations" }
  step { summarize }
  step { classify "buy / hold / sell" }

  output json {
    rating:    enum("buy", "hold", "sell")
    score:     int
    rationale: string
  }
}
```

- [ ] **Step 1: Write the remaining agents for each seeded cluster**

Use this concept pool (pick to complement what the owner already wrote; ~5 per seeded cluster). Each file = intent comment + legal DSL + honest FRICTION tags.

- **finance/**: `earnings-analyst` (above), `valuation-screener` (judge over/under-valued from metrics), `dividend-safety` (assess payout sustainability), `macro-brief` (summarize a macro event's market impact), `options-strategy-advisor` (suggest a strategy for a stated view).
- **health/**: `pollen-allergy-advisor` (advice from today's pollen + symptoms), `symptom-triage` (non-diagnostic urgency triage), `nutrition-label-reader` (interpret a label), `medication-interaction-checker` (informational interaction flags), `sleep-coach` (improve sleep habits).
- **advice/**: `relationship-advice` (balanced advice for a situation), `career-decision` (weigh a job offer), `conflict-deescalation` (draft a calm reply to a heated message), `budgeting-coach` (advice from income/expenses), `apology-writer` (draft a sincere apology).
- **knowledge/**: `pet-care-qa` (answer a dog/cat care question), `plant-care-qa` (houseplant care), `concept-explainer` (explain a concept at a chosen level), `recipe-adapter` (adapt a recipe to a dietary restriction), `travel-tip` (quick tips for a destination).

Watch for the recurring structure (role/goal/output shape repeating across a cluster) and tag it `// FRICTION [repeated:template]` when you copy it; that repetition IS the Phase 2 signal.

- [ ] **Step 2: Validate**

Run: `./scripts/check-corpus.sh`
Expected: every file in `passed`, `0 failed`, exit 0.

- [ ] **Step 3: Commit**

```bash
git add corpus
git commit -m "corpus(clusters): expand seeded domains to ~5 agents each"
```

---

### Task 5: Add ~5 scattered one-offs (`misc/`)

**Files:**
- Create: ~5 `corpus/misc/*.prompt`, each in a distinct domain, chosen to stress *missing capabilities* (especially inputs).

- [ ] **Step 1: Write the one-offs**

Concept pool (write 5, intent-first + FRICTION tags, all legal DSL):
- `code-reviewer` — review a code snippet (wants a code-text input + a `language` param).
- `email-rewriter` — rewrite an email in a chosen tone (wants the email text + a `tone` param).
- `legal-clause-explainer` — explain a contract clause (wants the clause text as input).
- `translation-quality-checker` — check a translation (wants *three* inputs: source text, target text, target language → stresses `multi-input`).
- `data-extractor` — pull structured fields from unstructured text (wants the text input; output schema is fixed at author time → tag `awkward:static-schema` if it feels constraining).

Expected friction these surface: `missing:inputs`, `missing:multi-input`, `missing:tone-param`/parameters generally, `missing:long-text-input`.

- [ ] **Step 2: Validate**

Run: `./scripts/check-corpus.sh`
Expected: all files `passed`, `0 failed`, exit 0.

- [ ] **Step 3: Confirm total count is 20–30**

Run: `find corpus -name '*.prompt' | wc -l`
Expected: a number in 20–30. If under 20, add more from the Task 4/5 pools; if over 30, that's fine but trim if redundant.

- [ ] **Step 4: Commit**

```bash
git add corpus
git commit -m "corpus(misc): add scattered one-offs to surface missing capabilities"
```

---

### Task 6: Aggregate FINDINGS.md

**Files:**
- Create: `FINDINGS.md`

- [ ] **Step 1: Tally the friction tags mechanically**

Run:
```bash
echo "total agents: $(find corpus -name '*.prompt' | wc -l)"
grep -rohE 'FRICTION \[[^]]*\]' corpus | sort | uniq -c | sort -rn
```
This gives the hit count per `[category:slug]` — the objective ranking.

- [ ] **Step 2: Write `FINDINGS.md`**

Structure (fill from the tally + real examples pulled from the files):
```markdown
# Phase 1 Findings

Corpus: <N> agents across <domains>. All pass `promptc check`.
Ranking is by number of agents that hit each gap (from the FRICTION tags).

## Ranked gaps

| Gap (slug) | Category | Hits (N / <total>) | Example file(s) | Possible feature (named, not designed) |
| --- | --- | --- | --- | --- |
| inputs | missing | .. | corpus/finance/earnings-analyst.prompt | typed input params + interpolation |
| ... | ... | ... | ... | ... |

## Top-N for Phase 2

1. <highest-hit gap> — <one line on why>
2. ...

## Notes / surprises

- <anything that disconfirmed expectations, e.g. a predicted gap that didn't show up>
```
- Every row's "Hits" must match the Step 1 tally (no inflating).
- "Possible feature" only NAMES a direction; do not design syntax here (that's Phase 2).
- In Notes, explicitly state whether the spec's hypothesis (inputs = #1) held.

- [ ] **Step 3: Final validation + commit**

Run: `./scripts/check-corpus.sh && find corpus -name '*.prompt' | wc -l`
Expected: `0 failed`, count 20–30.

```bash
git add FINDINGS.md
git commit -m "docs(findings): Phase 1 dogfooding findings, ranked gaps for Phase 2"
```

---

## Self-Review

**Spec coverage:**
- Hard rules (lib/ frozen, intent-first, all legal) → enforced in every task + check-corpus gate. ✓
- Capability boundary documented → in plan header + spec. ✓
- Corpus structure (4 clusters + misc) → Tasks 1,4,5. ✓
- Hybrid process (owner seeds, Claude expands) → Tasks 2,3,4,5. ✓
- Inline FRICTION + ranked FINDINGS.md → tag convention + Task 6 mechanical tally. ✓
- The one script (check-corpus.sh) → Task 1. ✓
- Success criteria (20–30 legal files + ranked findings) → Task 5 Step 3, Task 6. ✓
- Out of scope (no lib/ changes, no later phases) → hard rules. ✓
- Hypothesis (inputs #1) addressed by corpus → Task 6 Step 2 Notes. ✓

**Placeholder scan:** The concept pools are deliberately enumerated (not vague); the worked example is complete and legal; FINDINGS row contents are filled from a real tally command, not invented. The owner-seed task is intentionally human (a checkpoint, not a placeholder).

**Consistency:** FRICTION tag format `[category:slug]` is identical in the convention, the worked example, and the Task 6 grep. The binary path `_build/default/bin/main.exe` and `promptc check` semantics (exit 0 = OK) match the actual MVP.

## Execution note

This plan has a **human checkpoint (Task 2)** and cross-cutting judgment (consistent friction tagging, the final ranking), so inline execution in this session fits more naturally than fanning out to subagents. Offered both at handoff.
