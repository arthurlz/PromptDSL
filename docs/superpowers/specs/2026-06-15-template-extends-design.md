# template + extends (Design)

**Date:** 2026-06-15
**Status:** Design — awaiting review

## Context

Phase 1 dogfooding (`FINDINGS.md`) found `repeated:template` in 9/25 agents — the
same `role / goal / steps / output` skeleton copied across the files of a domain
cluster. The first reuse cut (`import` + shared text fragments) handled *content*
repetition; this cut handles *structural* repetition: a reusable agent skeleton
that concrete agents specialize.

It builds on the two shipped features: templates are defined in lib files and
brought in via `import "..." as alias` (reusing the module system), and template
clauses use `{{param}}` interpolation (reusing inputs). The shared skeleton is
written once.

## Decisions (locked)

| Decision | Choice |
| --- | --- |
| Override semantics | **Whole-clause override.** For each clause kind (`input`/`goal`/`step*`/`output`), the agent's clause (if written) replaces the template's; an omitted clause is inherited. `step*` is all-or-nothing (the agent's whole step list replaces, or the template's is inherited) — no per-step merge. |
| Post-merge requirement | The merged agent must have a `goal` (its own or inherited). |
| Reference scope | `{{...}}` refs in merged clauses resolve in the **extending agent's scope** (the agent's inputs + the agent's imports). Templates mainly use `{{param}}`; a fragment ref `{{alias.def}}` in a template requires the extender to import that alias (documented sharp edge). |
| Where templates live | In **lib files** only (alongside `def`), referenced as `alias.Name` after import. No local templates in agent files this cut. |
| Template validation | Templates are **not** validated standalone (they may lack a goal). Only the merged agent is validated by sema. |
| Inheritance depth | **Single level** — a template may not `extends` another; no multiple inheritance. |
| Backward compatibility | Agents with no `extends` compile exactly as today. |

## Language surface

```
# strategy.prompt   (lib file)
template Rater {
  step { search "{{topic}} latest data" }
  step { summarize }
  output json { rating: enum("buy","hold","sell"); rationale: string }
}
```
```
# earnings.prompt   (agent file)
import "strategy.prompt" as s

agent "earnings-analyst" extends s.Rater {
  input { topic: string }
  goal "Analyze {{topic}}'s latest earnings and rate it."
  # steps + output inherited from Rater
}
```

- `template Name { <item>* }` — a top-level lib declaration; `<item>` are the same
  agent-body clauses (`goal` / `step` / `output` / `input`), all optional.
- `agent "x" extends alias.Name { <item>* }` — `extends alias.Name` is optional;
  the body holds the overriding clauses (any subset).
- An agent that overrides nothing is `agent "x" extends s.Rater {}`.

## Semantics (whole-clause override)

Let the template body and the agent body each be split into the four clause slots
`input?`, `goal?`, `step list`, `output?`. The merged agent uses, per slot:

- `goal`, `input`, `output`: the agent's if present, else the template's.
- `step list`: the agent's full list if it has any `step`, else the template's list.

Then sema validates the merged agent normally (goal required, known actions,
`{{ref}}` resolution against the agent's inputs + imports, etc.).

## Pipeline

```
parse → resolve (fragments + templates) → expand (apply extends) → sema → bind → lower → backends
```

- **resolve** (extended): a lib file now parses to a list of `def` and `template`
  declarations. `resolve` collects both, returning `{ fragments; templates }`
  (its return type changes from bare `fragments` — this ripples to the `resolve`
  call sites in `compile` and to `test_resolve`). It exposes a template lookup.
- **expand** (new `lib/expand.ml`): `expand templates agent` — if the agent has no
  `extends`, return it unchanged; otherwise look up the referenced template
  (`unknown template 'alias.Name'` error if absent) and merge per the whole-clause
  rule, producing a complete `agent_block`. Templates are not validated here.
- sema/bind/lower/backends operate on the merged agent exactly as today.

## Grammar / AST

- New tokens: `TEMPLATE`, `EXTENDS`, and `DOT` (`.`). `DOT` is only used in
  `extends alias.Name`; `{{a.b}}` interpolation lives inside string literals and is
  unaffected by the lexer.
- Lib grammar: `library: list(lib_item)` where `lib_item` is a `def_decl` or a
  `template_decl`. `template_decl: TEMPLATE IDENT LBRACE list(item) RBRACE` (reuses
  the existing agent `item` rule).
- Agent grammar: `agent : AGENT STRING extends_opt LBRACE list(item) RBRACE`;
  `extends_opt` is empty or `EXTENDS IDENT DOT IDENT`.
- AST:
  - `template_decl = { tpl_name:string; tpl_items:agent_item list; tpl_loc:Location.t }`
  - `lib_item = LDef of def_decl | LTemplate of template_decl`
  - `agent_block` gains `block_extends : (string * string * Location.t) option`
    (alias, template name, span).

## Module impact

```
lib/ast.ml       + template_decl, lib_item; agent_block.block_extends
lib/lexer.mll    + `template`, `extends` keywords; `.` -> DOT token
lib/parser.mly   + template_decl, lib_item, extends_opt; library returns lib_item list
lib/resolve.ml   collect templates too; return { fragments; templates } + a template lookup
lib/expand.ml    NEW: apply extends (whole-clause merge), error on unknown template
lib/compile.ml   frontend inserts expand between resolve and sema
test/*           parser, resolve, expand, end-to-end, backward-compat coverage
```

## Error handling

Span-carrying diagnostics: `extends` references an unknown alias/template; the
merged agent has no goal. (Existing sema errors continue to apply to the merged
agent.)

## Testing

- **parser:** a lib with a `template`; an agent with `extends alias.Name`.
- **resolve:** a lib exposing a template is collected (template lookup returns it);
  fragments still work.
- **expand:** override (agent goal replaces template's), inherit (agent omits
  steps → template's steps used), unknown template → error, no-extends passthrough.
- **end-to-end:** an agent extending a template, declaring an input, overriding the
  goal, inheriting steps + output → `compile --set` produces the expected prompt.
- **backward-compat:** a no-`extends` agent is byte-identical to today; corpus 25/25.

## Out of scope (later cuts)

Template inheritance chains (template `extends` template); multiple inheritance;
per-step merge/append; local templates in agent files; standalone template
validation; cross-lib reference scoping (merged refs resolve in the extender's
scope only).
