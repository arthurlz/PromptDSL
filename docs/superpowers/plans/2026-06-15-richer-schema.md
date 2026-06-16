# Richer Schema (float + range) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `float` schema type (input + output) and `minimum`/`maximum` range constraints on output `int`/`float` fields via `name: int(0..100)` syntax.

**Architecture:** `float` is one variant threaded end-to-end (ty → IR → backends + bind type-check). `range` is an optional `(min,max)` on output fields: new lexer literals (`INT_LIT`/`FLOAT_LIT`/`DOTDOT`), an `Ast.field.field_range`, sema validation (numeric fields only), and JSON-Schema `minimum`/`maximum` emission.

**Tech Stack:** OCaml, dune, Menhir, ocamllex, yojson, cmdliner, alcotest.

**Spec:** `docs/superpowers/specs/2026-06-15-richer-schema-design.md`

---

## Conventions

- `dune test` + `./scripts/check-corpus.sh` (stay 25/25).
- Commit on a feature branch (executor sets up). Trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

## Type vocabulary

```
Ast.ty           += TFloat
Ast.field        += field_range : (float * float) option
Ir.schema_ty     += SFloat
Ir.schema_field  += range : (float * float) option
```

## Two record-field ripples (OCaml requires all literals updated)

- Adding `Ast.field.field_range` (Task 2) breaks `Ast.field` record literals — `test/test_lower.ml` constructs one. Add `field_range = None` there.
- Adding `Ir.schema_field.range` (Task 4) breaks `Ir.schema_field` literals — `test/test_backends.ml` (`sample_ir`) and the float test from Task 1 construct them. Add `range = None` there.

## File map

```
lib/lexer.mll          + `float` keyword; INT_LIT / FLOAT_LIT / DOTDOT tokens
lib/ast.ml             + ty.TFloat; field.field_range
lib/parser.mly         + FLOAT_TY / INT_LIT / FLOAT_LIT / DOTDOT tokens; ty float alt; field range_opt
lib/ir.ml              + schema_ty.SFloat; schema_field.range
lib/lower.ml           + TFloat→SFloat; carry field_range→range
lib/sema.ml            + range validation (numeric fields; integer bounds for int)
lib/backend_openai.ml  + number type; minimum/maximum
lib/backend_prose.ml   + float rendering; range note
lib/bind.ml            + TFloat type-check (float_of_string_opt)
test/*                 parser, sema, lower, backends, bind, cram
```

---

### Task 1: `float` type (end-to-end)

**Files:** Modify `lib/lexer.mll`, `lib/ast.ml`, `lib/parser.mly`, `lib/ir.ml`, `lib/lower.ml`, `lib/backend_openai.ml`, `lib/backend_prose.ml`, `lib/bind.ml`, `test/test_parser.ml`, `test/test_backends.ml`.

- [ ] **Step 1: Write the failing tests**

Add to `test/test_parser.ml` (before `let suite`) and register:
```ocaml
let test_parse_float () =
  match Compile.parse {|agent "a" { input { pe: float } goal "g" output json { p: float } }|} with
  | Error e -> Alcotest.failf "parse: %s" e.Error.message
  | Ok af ->
      let items = af.Ast.af_agent.Ast.block_items in
      (match List.find_map (function Ast.IInputs n -> Some n.Ast.v | _ -> None) items with
       | Some [ d ] -> Alcotest.(check bool) "float input" true (d.Ast.in_ty = Ast.TFloat)
       | _ -> Alcotest.fail "expected one input");
      (match List.find_map (function Ast.IOutput o -> Some o.Ast.v | _ -> None) items with
       | Some ro -> (
           match ro.Ast.out_schema with
           | Some [ f ] -> Alcotest.(check bool) "float field" true (f.Ast.field_ty = Ast.TFloat)
           | _ -> Alcotest.fail "expected one field")
       | None -> Alcotest.fail "expected output")
```
Register: `Alcotest.test_case "float" `Quick test_parse_float;`.

Add to `test/test_backends.ml` (before `let suite`) and register:
```ocaml
let test_float_number () =
  let ir =
    { Ir.agent_name = "a"; objective = "g"; instructions = [];
      out = Ir.OJson (Some [ { Ir.fname = "p"; fty = Ir.SFloat; required = true } ]);
      content = None }
  in
  let open Yojson.Safe.Util in
  let t =
    Backend_openai.render ir |> member "response_format" |> member "json_schema"
    |> member "schema" |> member "properties" |> member "p" |> member "type" |> to_string
  in
  Alcotest.(check string) "float -> number" "number" t
```
Register: `Alcotest.test_case "float number" `Quick test_float_number;`.

Add to `test/test_bind.ml` (before `let suite`) and register:
```ocaml
let test_float_input () =
  (match bind {|agent "a" { input { pe: float } goal "{{pe}}" }|} [ ("pe", "12.5") ] with
   | Ok b -> Alcotest.(check string) "ok" "12.5" b.Bind.b_goal
   | Error _ -> Alcotest.fail "expected ok");
  (match bind {|agent "a" { input { pe: float } goal "{{pe}}" }|} [ ("pe", "abc") ] with
   | Ok _ -> Alcotest.fail "expected type error"
   | Error ds ->
       Alcotest.(check bool) "bad" true
         (List.exists (fun (d : Error.t) -> d.Error.message = "input 'pe': expected a number, got \"abc\"") ds))
```
Register: `Alcotest.test_case "float input" `Quick test_float_input;`.

- [ ] **Step 2: Run to verify it fails**

`dune test 2>&1 | head -20` → `Ast.TFloat` / `Ir.SFloat` unbound (and the build fails on non-exhaustive matches once `TFloat`/`SFloat` exist — that's the next step).

- [ ] **Step 3: Add the `float` variant everywhere**

`lib/ast.ml` — add `| TFloat` to `ty`:
```ocaml
type ty = TString | TInt | TBool | TFloat | TEnum of string list | TList of ty
```
`lib/lexer.mll` — add to `keywords`: `("float", FLOAT_TY);`.
`lib/parser.mly` — add token `%token FLOAT_TY` and a `ty` alt:
```
  | FLOAT_TY  { TFloat }
```
`lib/ir.ml` — add `| SFloat` to `schema_ty`:
```ocaml
type schema_ty = SString | SInt | SBool | SFloat | SEnum of string list | SList of schema_ty
```
`lib/lower.ml` — in `ty_to_ir`, add `| Ast.TFloat -> Ir.SFloat`.
`lib/backend_openai.ml` — in `json_of_ty`, add `| SFloat -> \`Assoc [ ("type", \`String "number") ]`.
`lib/backend_prose.ml` — in `render_ty`, add `| SFloat -> "float"`.
`lib/bind.ml` — in `typecheck`, add before the `TList` arm:
```ocaml
  | Ast.TFloat -> (
      match float_of_string_opt v with
      | Some _ -> Ok ()
      | None -> Error (Printf.sprintf "expected a number, got %S" v))
```

- [ ] **Step 4: Run to verify it passes**

`dune build 2>&1 | head && dune test 2>&1 | tail -8 && ./scripts/check-corpus.sh`
Expected: build clean (all exhaustive matches now cover `TFloat`/`SFloat`); the three new cases pass; all prior pass; corpus 25/25.

- [ ] **Step 5: Commit**

```bash
git add lib/ast.ml lib/lexer.mll lib/parser.mly lib/ir.ml lib/lower.ml lib/backend_openai.ml lib/backend_prose.ml lib/bind.ml test/test_parser.ml test/test_backends.ml test/test_bind.ml
git commit -m "feat(schema): add float type (input + output)"
```

---

### Task 2: parse `range` into `Ast.field.field_range`

**Files:** Modify `lib/lexer.mll`, `lib/ast.ml`, `lib/parser.mly`, `test/test_lower.ml`, `test/test_parser.ml`.

- [ ] **Step 1: Write the failing test**

Add to `test/test_parser.ml` (before `let suite`) and register:
```ocaml
let test_parse_range () =
  match Compile.parse {|agent "a" { goal "g" output json { score: int(0..100)  ratio: float(0.0..1.0) } }|} with
  | Error e -> Alcotest.failf "parse: %s" e.Error.message
  | Ok af -> (
      match List.find_map (function Ast.IOutput o -> Some o.Ast.v | _ -> None) af.Ast.af_agent.Ast.block_items with
      | Some ro -> (
          match ro.Ast.out_schema with
          | Some [ a; b ] ->
              Alcotest.(check bool) "int range" true (a.Ast.field_range = Some (0., 100.));
              Alcotest.(check bool) "float range" true (b.Ast.field_range = Some (0., 1.))
          | _ -> Alcotest.fail "expected two fields")
      | None -> Alcotest.fail "expected output")
```
Register: `Alcotest.test_case "range" `Quick test_parse_range;`.

- [ ] **Step 2: Run to verify it fails**

`dune test 2>&1 | head -20` → `field_range` unbound.

- [ ] **Step 3: Add `field_range` to the AST**

`lib/ast.ml` — add the field to `field`:
```ocaml
type field = {
  field_name : string;
  field_ty : ty;
  optional : bool;
  field_loc : Location.t;
  field_range : (float * float) option;
}
```

- [ ] **Step 4: Add lexer literals + DOTDOT**

`lib/lexer.mll` — add these rules among the token rules (place the FLOAT_LIT rule before INT_LIT; `".."` before the existing `'.'` rule is fine — longest match handles ordering, but list `".."` first for clarity):
```ocaml
  | ".."                          { DOTDOT }
  | ['0'-'9']+ '.' ['0'-'9']+ as f { FLOAT_LIT (float_of_string f) }
  | ['0'-'9']+ as n                { INT_LIT (int_of_string n) }
```

- [ ] **Step 5: Add parser tokens + range_opt**

`lib/parser.mly` — add tokens:
```
%token <int> INT_LIT
%token <float> FLOAT_LIT
%token DOTDOT
```
Change the `field` rule and add `range_opt` + `number`:
```
field:
  | name = IDENT q = boption(QUESTION) COLON t = ty r = range_opt
    { { field_name = name; field_ty = t; optional = q; field_loc = mkloc $loc; field_range = r } }

range_opt:
  | { None }
  | LPAREN lo = number DOTDOT hi = number RPAREN { Some (lo, hi) }

number:
  | n = INT_LIT { float_of_int n }
  | f = FLOAT_LIT { f }
```

- [ ] **Step 6: Fix the `Ast.field` record literal in `test/test_lower.ml`**

`test/test_lower.ml`'s `test_lower` builds a `Sema.COJson (Some [ { Ast.field_name = "ticker"; field_ty = Ast.TString; optional = false; field_loc = Location.dummy } ])`. Add `field_range = None;` to that record literal so it type-checks.

- [ ] **Step 7: Run to verify it passes**

`dune build 2>&1 | head && dune test 2>&1 | tail -8 && ./scripts/check-corpus.sh`
Expected: build clean (NO menhir conflicts — grep for "conflict"); `range` case passes; all prior pass; corpus 25/25.

- [ ] **Step 8: Commit**

```bash
git add lib/ast.ml lib/lexer.mll lib/parser.mly test/test_lower.ml test/test_parser.ml
git commit -m "feat(schema): parse range int(0..100) into field_range"
```

---

### Task 3: sema validates ranges

**Files:** Modify `lib/sema.ml`, `test/test_sema.ml`.

- [ ] **Step 1: Write the failing tests**

Add to `test/test_sema.ml` (before `let suite`) and register:
```ocaml
let test_range_on_string () =
  let ds = err_or_fail {|agent "a" { goal "g" output json { x: string(0..1) } }|} in
  Alcotest.(check bool) "range on string" true
    (List.exists
       (fun (d : Error.t) -> d.Error.message = "range is only allowed on int or float fields")
       ds)

let test_int_range_non_integer () =
  let ds = err_or_fail {|agent "a" { goal "g" output json { x: int(0.5..1.0) } }|} in
  Alcotest.(check bool) "non-integer int bounds" true
    (List.exists
       (fun (d : Error.t) -> d.Error.message = "int range bounds must be integers")
       ds)

let test_range_ok () =
  let _ = ok_or_fail {|agent "a" { goal "g" output json { x: int(0..100)  y: float(0.0..1.0) } }|} in
  ()
```
Register: `range on string`, `int range non-integer`, `range ok`.

- [ ] **Step 2: Run to verify it fails**

`dune test 2>&1 | tail -10` → the new cases fail (no range validation; the `string(0..1)` and `int(0.5..1.0)` currently pass sema).

- [ ] **Step 3: Add range validation in sema**

In `lib/sema.ml`, add a helper near `check_dup_fields` (inside `analyze`, same scope as `add`):
```ocaml
  let check_field_ranges fields =
    List.iter
      (fun (f : Ast.field) ->
        match f.field_range with
        | None -> ()
        | Some (lo, hi) -> (
            match f.field_ty with
            | Ast.TInt ->
                if Float.rem lo 1.0 <> 0.0 || Float.rem hi 1.0 <> 0.0 then
                  add (Error.make f.field_loc "int range bounds must be integers")
            | Ast.TFloat -> ()
            | _ -> add (Error.make f.field_loc "range is only allowed on int or float fields")))
      fields
  in
```
In the `IOutput` arm's `"json"` case, where it currently does `check_dup_fields fields; output := Some (COJson (Some fields))`, add a call:
```ocaml
                      check_dup_fields fields;
                      check_field_ranges fields;
                      output := Some (COJson (Some fields)))
```

- [ ] **Step 4: Run to verify it passes**

`dune test 2>&1 | tail -10 && ./scripts/check-corpus.sh`
Expected: the three new sema cases pass; all prior pass; corpus 25/25.

- [ ] **Step 5: Commit**

```bash
git add lib/sema.ml test/test_sema.ml
git commit -m "feat(schema): sema validates range (numeric fields; integer int bounds)"
```

---

### Task 4: emit `minimum`/`maximum` (IR + backends)

**Files:** Modify `lib/ir.ml`, `lib/lower.ml`, `lib/backend_openai.ml`, `lib/backend_prose.ml`, `test/test_backends.ml`.

- [ ] **Step 1: Write the failing test**

Add to `test/test_backends.ml` (before `let suite`) and register:
```ocaml
let test_range_emitted () =
  let ir =
    { Ir.agent_name = "a"; objective = "g"; instructions = [];
      out = Ir.OJson (Some [
        { Ir.fname = "score"; fty = Ir.SInt; required = true; range = Some (0., 100.) };
        { Ir.fname = "ratio"; fty = Ir.SFloat; required = true; range = Some (0., 1.) } ]);
      content = None }
  in
  let open Yojson.Safe.Util in
  let props = Backend_openai.render ir |> member "response_format" |> member "json_schema"
              |> member "schema" |> member "properties" in
  Alcotest.(check int) "int min" 0 (props |> member "score" |> member "minimum" |> to_int);
  Alcotest.(check int) "int max" 100 (props |> member "score" |> member "maximum" |> to_int);
  Alcotest.(check (float 0.001)) "float max" 1.0 (props |> member "ratio" |> member "maximum" |> to_number);
  Alcotest.(check bool) "prose range" true
    (contains (Backend_prose.render ir) "score: int (0..100)")
```
Register: `Alcotest.test_case "range emitted" `Quick test_range_emitted;`.

- [ ] **Step 2: Run to verify it fails**

`dune build 2>&1 | head` → `range` field not in `Ir.schema_field` (record literal error), and `minimum` absent.

- [ ] **Step 3: Add `range` to the IR + lower**

`lib/ir.ml` — add to `schema_field`:
```ocaml
type schema_field = { fname : string; fty : schema_ty; required : bool; range : (float * float) option }
```
`lib/lower.ml` — in `field_to_ir`, carry the range:
```ocaml
let field_to_ir (f : Ast.field) : Ir.schema_field =
  { Ir.fname = f.Ast.field_name; fty = ty_to_ir f.Ast.field_ty;
    required = not f.Ast.optional; range = f.Ast.field_range }
```

- [ ] **Step 4: Fix existing `Ir.schema_field` literals**

Add `range = None;` to the `Ir.schema_field` record literals in `test/test_backends.ml`: `sample_ir` (two fields) and `test_float_number` (the `p` field). (Search the file for `Ir.fname =` and add `range = None` to each literal that lacks it.)

- [ ] **Step 5: Emit min/max in the OpenAI backend**

In `lib/backend_openai.ml`, the `response_format` builder maps fields to `(fname, json_of_ty fty)`. Add a range wrapper. Replace the `props` binding with:
```ocaml
  let with_range (f : Ir.schema_field) (base : Yojson.Safe.t) : Yojson.Safe.t =
    match (f.range, base) with
    | None, _ -> base
    | Some (lo, hi), `Assoc kvs ->
        let num v = match f.fty with Ir.SInt -> `Int (int_of_float v) | _ -> `Float v in
        `Assoc (kvs @ [ ("minimum", num lo); ("maximum", num hi) ])
    | Some _, j -> j
  in
  let props = List.map (fun (f : Ir.schema_field) -> (f.fname, with_range f (json_of_ty f.fty))) fields in
```
(`with_range`/`props` go inside `response_format`, where `fields` is in scope. Keep the rest — `required`, `additionalProperties` — unchanged.)

- [ ] **Step 6: Show ranges in the prose backend**

In `lib/backend_prose.ml`, the JSON-schema rendering prints each field as `"  %s%s: %s\n"` with `fname`, optional `?`, and `render_ty f.fty`. Append a range note. Add a helper and use it:
```ocaml
let range_str = function
  | None -> ""
  | Some (lo, hi) -> Printf.sprintf " (%g..%g)" lo hi
```
and change the field line to include `^ range_str f.range`, e.g.:
```ocaml
           (Printf.sprintf "  %s%s: %s%s\n" f.fname
              (if f.required then "" else "?")
              (render_ty f.fty) (range_str f.range))
```

- [ ] **Step 7: Run to verify it passes**

`dune build 2>&1 | head && dune test 2>&1 | tail -8 && ./scripts/check-corpus.sh`
Expected: `range emitted` passes; all prior pass; corpus 25/25.

- [ ] **Step 8: Commit**

```bash
git add lib/ir.ml lib/lower.ml lib/backend_openai.ml lib/backend_prose.ml test/test_backends.ml
git commit -m "feat(schema): emit minimum/maximum for ranged fields; prose range note"
```

---

### Task 5: cram end-to-end

**Files:** Create `test/cram/schema.t`.

- [ ] **Step 1: Manual check**

```bash
dune build 2>&1 | head
mkdir -p /tmp/schdemo
printf 'agent "a" {\n  input { pe: float }\n  goal "Analyze (P/E {{pe}})."\n  output json { score: int(0..100)  margin: float }\n}\n' > /tmp/schdemo/a.prompt
dune exec promptc -- compile /tmp/schdemo/a.prompt --set pe=12.5 --emit both
```
Expected: prose shows `Goal: Analyze (P/E 12.5).` and a schema block with `score: int (0..100)` and `margin: float`; JSON `properties.score` has `"type": "integer"`, `"minimum": 0`, `"maximum": 100`, and `margin` has `"type": "number"`. Then a bad float:
```bash
dune exec promptc -- compile /tmp/schdemo/a.prompt --set pe=abc; echo "exit=$?"
```
Expected: `input 'pe': expected a number, got "abc"`, `exit=1`.

- [ ] **Step 2: Add the cram test (commands only; promote)**

`test/cram/schema.t`:
```
A float input and a ranged int field compile through to JSON:

  $ printf 'agent "a" {\n  input { pe: float }\n  goal "Analyze (P/E {{pe}})."\n  output json { score: int(0..100)  margin: float }\n}\n' > a.prompt
  $ promptc compile a.prompt --set pe=12.5 --emit both

A non-numeric float input is an error:

  $ promptc compile a.prompt --set pe=abc
  [1]
```

- [ ] **Step 3: Record golden output and verify**

```bash
dune runtest --auto-promote 2>&1 | tail -5
dune runtest 2>&1; echo "exit=$?"
```
Review `git diff test/cram/schema.t`: prose has `score: int (0..100)` + `margin: float`; JSON `score` has integer `minimum`/`maximum` and `margin` is `"number"`; the bad-input block shows `expected a number` + `[1]`. Confirm `test/cram/{compile,check,emit,input,import,template}.t` are UNCHANGED. Re-run `dune runtest` → clean, exit 0.

- [ ] **Step 4: Final full check**

```bash
dune runtest --force 2>&1 | tail -4
./scripts/check-corpus.sh
```
Expected: all unit + cram pass; corpus 25/25 unchanged.

- [ ] **Step 5: Commit**

```bash
git add test/cram/schema.t
git commit -m "feat(schema): cram coverage for float input + ranged field"
```

---

## Self-Review

**Spec coverage:**
- `float` input + output → Task 1 (all 8 lib files + 3 tests).
- `float` → JSON `"number"`, prose `"float"`, bind `float_of_string_opt` → Task 1.
- range `int(0..100)`/`float(0.0..1.0)` syntax → Task 2 (lexer literals + DOTDOT + field range_opt).
- range only on int/float; integer bounds for int → Task 3 (sema `check_field_ranges`).
- range → JSON `minimum`/`maximum` (int bounds for int, float for float) + prose note → Task 4.
- range is output-only (no input range) → only `Ast.field`/`Ir.schema_field` carry range; `input_decl`/`bind` untouched by range.
- Lexer disambiguation (`0..100` vs `0.0`) → FLOAT_LIT requires a digit after the dot; DOTDOT is 2 chars (longest match). Verified by Task 2's `range` test parsing `int(0..100)` and `float(0.0..1.0)` together.
- Backward compat → pure additions; corpus 25/25 in every task; existing cram goldens unchanged (Task 5 confirms).

**Placeholder scan:** none — every step has complete code; the two record-field ripples (Task 2 Step 6, Task 4 Step 4) name the exact literals to update; cram via `--auto-promote` with review criteria.

**Type consistency:** `Ast.ty.TFloat` / `Ir.schema_ty.SFloat`; `Ast.field.field_range : (float*float) option` / `Ir.schema_field.range : (float*float) option` (both `(min,max)` floats); `INT_LIT : int`, `FLOAT_LIT : float`, `number → float`. `with_range` keys off `f.fty` (`SInt`→`\`Int`, else `\`Float`) consistently with the prose `%g`. Every exhaustive match over `ty`/`schema_ty` (`ty_to_ir`, `json_of_ty`, `render_ty`, `bind.typecheck`) gets the new variant in Task 1, so the build stays green.
