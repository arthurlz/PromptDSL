# Phase 2 — Input Parameters (Design)

**Date:** 2026-06-15
**Status:** Design — awaiting review

## Context

Phase 1 dogfooding (`FINDINGS.md`) found that **25 / 25** agents wanted to pass
something in at run time; `input-params` was the single most-hit gap (16/25
directly). The MVP DSL has no inputs — values get baked into the `goal` string,
so an agent isn't reusable, and the OpenAI user message is hardcoded `{{input}}`.

This is Phase 2 of the roadmap. Per the findings it is scoped to **inputs only**.
Reuse (`template`/`import`, 13/25) and richer schema (`float`, ranges) are
deferred to later sub-phases — `input` is foundational and is the precondition
for Phase 4 (`promptc run` must bind values to declared inputs).

## Decisions (locked)

| Decision | Choice |
| --- | --- |
| Semantic model | **Compile-time substitution.** `--set name=value` supplies values; `{{name}}` is replaced at compile time. |
| Missing required input | Compile error (lists which). |
| Input types | **Scalars only:** `string`/`int`/`bool`/`enum` (content uses `string`). `list` stays output-schema-only this phase (avoids CLI list-parsing ambiguity). **No `float`.** |
| Defaults | Allowed on **`string` and `enum` only** (string-literal syntax `= "..."`); no int/bool literals introduced. int/bool/list inputs are required. |
| User-message content | One input may be marked **`@content`** → fills the OpenAI user message. Others are params substituted into the system prompt. At most one `@content`. |
| No `@content` | If an `input` block is present but nothing is `@content`, the user message is **empty**. |
| Backward compatibility | Agents with **no `input` block compile exactly as today** (user message stays `{{input}}`). |

## Language surface

```
agent "earnings-analyst" {
  input {
    ticker: string                              // required
    depth:  enum("brief", "deep") = "brief"     // optional, default
    notes:  string @content                     // fills the user message
  }

  goal "Analyze {{ticker}}'s latest earnings at {{depth}} depth."
  step { search "{{ticker}} latest quarterly earnings" }
  step { summarize }
  output json { rating: enum("buy","hold","sell"); rationale: string }
}
```

- `input { <field>* }` — at most one block, placed in the agent body.
- Field: `name : type [= "default"] [@content]`.
  - `type` ∈ `string` / `int` / `bool` / `enum` (scalars; `list` is not an input type this phase).
  - `= "default"` only on `string`/`enum` (enum default must be a declared member).
  - `@content` marks the user-message input (≤ 1 per agent) and must be on a `string` input.
- Interpolation: `{{name}}` inside the strings of `goal`, `step` action args, and
  `instruct` text. It lives *inside* string literals, so the lexer is unchanged;
  substitution scans string values during the bind stage.

## CLI

- `promptc compile <file> --set k=v [--set k=v ...]` — repeatable. Values are
  strings parsed/validated against each input's declared type:
  - `int` value that doesn't parse, or `enum` value not in the set → compile error.
- `--set` for an undeclared input → error. Missing a required input (no value, no
  default) → error naming it and suggesting `--set`.
- `check` runs structure validation only (no values needed); it does **not** bind.

## Compilation pipeline

```
parse → sema → bind(values) → lower → {prose, openai} backends
```

- **sema** (extended): validate the input block (unique names, ≤1 `@content`,
  default only on string/enum and a valid enum member); collect declared input
  names; verify every `{{name}}` referenced in goal/step strings is declared.
- **bind** (NEW stage, `lib/bind.ml`): merge `--set` values with defaults;
  type-check each value against its declared type; error on missing required;
  substitute `{{name}}` in the checked AST's strings; resolve the `@content`
  value. Produces a "bound" result the backends can render.
- **lower/backends**: largely unchanged. `Ir.t` gains `content : string option`
  (the user-message text). The OpenAI backend sets the user message from it; the
  prose backend appends an `## Input` section when content is present.

## User-message rules (summary)

| Agent shape | OpenAI user message |
| --- | --- |
| No `input` block | `{{input}}` (unchanged from MVP) |
| `input` block with an `@content` input | that input's bound value |
| `input` block, no `@content` | empty string |

## Error handling

All diagnostics carry spans via the existing `Error` module:
- undeclared `{{name}}` reference (pointed at the goal/step it appears in);
- duplicate input name; more than one `@content`; default on a non-string/enum
  type; enum default not a member;
- (bind) missing required input; `--set` of an undeclared input; value that fails
  its declared type.

## Module impact

```
lib/ast.ml          + input_decl type; agent body carries an optional input block
lib/lexer.mll       + `input` keyword, `@content` token, `=` token  (NOT {{ }})
lib/parser.mly      + input block + input-field rules
lib/sema.ml         + input validation + {{ref}}-declared check
lib/bind.ml         NEW: resolve values+defaults, type-check, substitute, set content
lib/ir.ml           + content : string option
lib/lower.ml        consume bound AST
lib/backend_prose.ml   render content as an "## Input" section
lib/backend_openai.ml  user message from content (per the table above)
lib/compile.ml      thread values; compile_string gains a values argument
lib/driver.ml       parse/collect --set; pass through
bin/main.ml         `--set k=v` repeatable cmdliner arg
```

## Testing

- **parser:** input block with default and `@content`; field variants.
- **sema:** undeclared `{{ref}}`; duplicate name; >1 `@content`; default on `int`
  (rejected); enum default not a member.
- **bind:** missing required → error; type mismatch (`int` given `abc`) → error;
  successful substitution; default applied when unset; `@content` → content value.
- **backends/compile:** end-to-end with `--set` produces substituted system prompt
  and content in the user message.
- **cram:** `compile --set ...` golden output; missing-input error; and a
  **backward-compat** case proving a no-`input` agent is byte-identical to today.

## Out of scope (later phases)

`template`/`import`; `float`/range constraints; reading content from a file or
stdin; multiple `@content` inputs; conditional steps; `promptc run` (Phase 4).
