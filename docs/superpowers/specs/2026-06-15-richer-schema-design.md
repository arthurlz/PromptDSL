# Richer Schema: float + range (Design)

**Date:** 2026-06-15
**Status:** Design — awaiting review

## Context

Phase 1 dogfooding (`FINDINGS.md`) flagged two schema gaps: `float-type` (4/25 —
financial ratios, money) and `range-constraint` (2/25 — `score` 0-100, accuracy
0-100). Both are small extensions to the existing schema type system used by
`output json { … }` (and, for scalars, by `input { … }`). This cut adds both.

## Decisions (locked)

| Decision | Choice |
| --- | --- |
| `float` type | Add `float` to the type system. Usable in **output schema fields and input params** (a scalar, like `string`/`int`/`bool`/`enum`). `@content` stays string-only. |
| `range` applies to | **Output schema numeric fields only** (`int`/`float`). No input-range validation this cut (no finding for it). |
| `range` syntax | `score: int(0..100)` / `ratio: float(0.0..1.0)` — a `..` range after the type. |
| `range` bounds | **Non-negative** (no `-` in literals this cut); on an `int` field the bounds must be **integers** (else a sema error). |
| `range` effect | Emitted as JSON-Schema `minimum`/`maximum` (integer bounds for an `int` field, number bounds for a `float` field) and noted in prose. The model's output is not validated by `promptc` (it's a downstream/API concern). |
| Backward compatibility | Pure additions; existing agents/corpus unchanged. |

## Language surface

```
agent "earnings-analyst" {
  input { pe: float }                       # float input
  goal "..."
  output json {
    rating: enum("buy","hold","sell")
    score:  int(0..100)                     # int field with a range
    margin: float                           # float field
    ratio:  float(0.0..1.0)                 # float field with a range
  }
}
```
```
promptc compile a.prompt --set pe=12.5      # float input type-checked
```

## float

- `Ast.ty` gains `TFloat`. Lexer keyword `float` → `FLOAT_TY`. Parser `ty` alt
  `FLOAT_TY { TFloat }`.
- `Ir.schema_ty` gains `SFloat`. `lower.ty_to_ir`: `TFloat → SFloat`.
- `backend_openai.json_of_ty`: `SFloat → \`Assoc [("type", \`String "number")]`.
- `backend_prose.render_ty`: `SFloat → "float"`.
- `bind.typecheck`: a `TFloat` input value is checked with `float_of_string_opt`
  (`--set pe=12.5` ok; `pe=abc` → `input 'pe': expected a number, got "abc"`).
- Sema already allows any non-`list` type as an input, so `float` inputs are
  accepted automatically; `@content` is still restricted to `string`.

## range (output fields only)

- **Lexer:** add `INT_LIT` (`['0'-'9']+` → int), `FLOAT_LIT`
  (`['0'-'9']+ '.' ['0'-'9']+` → float), and `DOTDOT` (`".."`). Because a float
  literal requires a digit after the dot, `0..100` lexes as `INT_LIT DOTDOT INT_LIT`
  while `0.0` lexes as `FLOAT_LIT` — no ambiguity (longest match). `DOTDOT` (2 chars)
  out-prioritizes the existing `DOT` (1 char) by longest match.
- **AST:** `Ast.field` gains `field_range : (float * float) option`. The parser's
  `field` rule appends an optional `LPAREN bound DOTDOT bound RPAREN`, where a bound
  is `INT_LIT` (→ `float_of_int`) or `FLOAT_LIT`. Stored as `(min, max)` floats.
- **Sema:** a range is only valid on an `int`/`float` field (else
  `"range is only allowed on int or float fields"`); on an `int` field both bounds
  must be integral (else `"int range bounds must be integers"`). (Optional niceties
  like `min ≤ max` are out of scope.)
- **IR/lower:** `Ir.schema_field` gains `range : (float * float) option`, carried through.
- **backend_openai:** when a field has a range, add `minimum`/`maximum` to its
  schema object — integer JSON numbers (`\`Int`) for an `int` field, float (`\`Float`)
  for a `float` field.
- **backend_prose:** render the range after the type, e.g. `score: int (0..100)`.

## Module impact

```
lib/lexer.mll      + `float` keyword; INT_LIT, FLOAT_LIT, DOTDOT tokens
lib/ast.ml         + ty.TFloat; field.field_range
lib/parser.mly     + FLOAT_TY/INT_LIT/FLOAT_LIT/DOTDOT tokens; ty float alt; field range_opt
lib/sema.ml        + range validation (int/float only; integer bounds for int)
lib/ir.ml          + schema_ty.SFloat; schema_field.range
lib/lower.ml       + TFloat→SFloat; carry field_range→range
lib/backend_openai.ml  + number type; minimum/maximum
lib/backend_prose.ml   + float rendering; range note
lib/bind.ml        + TFloat typecheck (float_of_string_opt)
test/*             parser, sema, lower, backends, bind, cram
```

## Error handling

Span-carrying: range on a non-numeric field; non-integer bounds on an `int` field;
a `float` input value that isn't a number (bind).

## Testing

- **parser:** `price: float`; `pe: float` input; `score: int(0..100)`; `ratio: float(0.0..1.0)`.
- **sema:** range on a `string` field → error; `int(0.5..1)` → error; valid ranges pass.
- **lower/backends:** `SFloat → {"type":"number"}`; an `int(0..100)` field emits
  `"minimum": 0, "maximum": 100`; a `float(0.0..1.0)` emits float bounds; prose shows the range.
- **bind:** `--set pe=12.5` ok; `--set pe=abc` → error.
- **cram:** a schema using `float` + a ranged `int` compiled to JSON shows `number`
  + `minimum`/`maximum`; backward-compat goldens unchanged; corpus 25/25.

## Out of scope (later cuts)

Negative range bounds; input-param range validation; `min ≤ max` checking;
exclusive bounds; range on non-numeric types; arbitrary precision.
