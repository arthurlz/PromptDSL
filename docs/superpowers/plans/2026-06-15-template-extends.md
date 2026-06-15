# template + extends Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add reusable agent skeletons — `template Name { ... }` in lib files and `agent "x" extends alias.Name { ... }` with whole-clause override — built on the import + inputs features.

**Architecture:** Lib files now hold `def` and `template` declarations. `resolve` collects both. A new `expand` stage applies `extends` by merging the agent's clauses over the template's (each of input/goal/steps/output: agent's if present, else template's), producing a complete agent_block that sema/bind/backends process unchanged.

**Tech Stack:** OCaml, dune, Menhir, ocamllex, yojson, cmdliner, alcotest.

**Spec:** `docs/superpowers/specs/2026-06-15-template-extends-design.md`

---

## Conventions

- `dune test` + `./scripts/check-corpus.sh` (must stay 25/25 — backward compat).
- Commit on a feature branch (executor sets up). Trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- Distinct field names: `template_decl` uses `tpl_*`; agent_block's new field is `block_extends`.

## Type vocabulary (keep identical)

```
Ast.template_decl = { tpl_name:string; tpl_items:agent_item list; tpl_loc:Location.t }
Ast.lib_item      = LDef of def_decl | LTemplate of template_decl
Ast.agent_block  += block_extends : (string * string * Location.t) option   (* alias, name, span *)
Compile.parse_library : string -> (Ast.lib_item list, Error.t) result        (* WAS def_decl list *)
Resolve.resolved  = { fragments : fragments; templates : ((string*string) * Ast.agent_item list) list }
Resolve.resolve   : … -> (resolved, Error.t list) result                     (* WAS fragments *)
Resolve.find_template : resolved -> string -> string -> Ast.agent_item list option
Expand.expand     : Resolve.resolved -> Ast.agent_block -> (Ast.agent_block, Error.t list) result
```

## Whole-clause merge rule (Expand)

Classify a body's items into 4 sublists by constructor: goals (`IGoal`), steps (`IStep`), outputs (`IOutput`), inputs (`IInputs`). For each slot, take the agent's sublist if non-empty, else the template's. Merged `block_items = pick inputs @ pick goal @ pick steps @ pick output`.

## File map

```
lib/ast.ml       + template_decl, lib_item; agent_block.block_extends
lib/lexer.mll    + `template`, `extends` keywords; `.` -> DOT token
lib/parser.mly   + template_decl, lib_item, extends_opt; library -> lib_item list; agent gains extends_opt
lib/resolve.ml   consume lib_item list; collect templates; return `resolved`; find_template
lib/expand.ml    NEW: apply extends via whole-clause merge
lib/compile.ml   frontend inserts Expand.expand between resolve and sema
test/*           parser, resolve, expand, end-to-end, cram, backward-compat
```

---

### Task 1: AST + parser (template / extends) + parse_library → lib_item list

**Files:** Modify `lib/ast.ml`, `lib/lexer.mll`, `lib/parser.mly`, `lib/compile.ml`, `lib/resolve.ml`, `test/test_parser.ml`.

- [ ] **Step 1: Write the failing tests**

Add to `test/test_parser.ml` (before `let suite`) and register:
```ocaml
let test_parse_template () =
  match Compile.parse_library {|def d = "x"  template Rater { goal "g" step { summarize } }|} with
  | Error e -> Alcotest.failf "unexpected: %s" e.Error.message
  | Ok [ Ast.LDef d; Ast.LTemplate t ] ->
      Alcotest.(check string) "def" "d" d.Ast.def_name;
      Alcotest.(check string) "tpl name" "Rater" t.Ast.tpl_name;
      Alcotest.(check int) "tpl items" 2 (List.length t.Ast.tpl_items)
  | Ok _ -> Alcotest.fail "expected one def then one template"

let test_parse_extends () =
  match Compile.parse {|import "s.prompt" as s
                        agent "a" extends s.Rater { goal "g" }|} with
  | Error e -> Alcotest.failf "unexpected: %s" e.Error.message
  | Ok af -> (
      match af.Ast.af_agent.Ast.block_extends with
      | Some (alias, name, _) ->
          Alcotest.(check string) "alias" "s" alias;
          Alcotest.(check string) "name" "Rater" name
      | None -> Alcotest.fail "expected extends")
```
Register: `Alcotest.test_case "template" `Quick test_parse_template;` and `Alcotest.test_case "extends" `Quick test_parse_extends;`.

Also UPDATE the existing `test_parse_library` test (added by the import feature): its `library` now returns `lib_item list`, so change its match arm from
```ocaml
  | Ok [ a; b ] -> Alcotest.(check string) "1 name" "disclaimer" a.Ast.def_name; ...
```
to:
```ocaml
  | Ok [ Ast.LDef a; Ast.LDef b ] ->
      Alcotest.(check string) "1 name" "disclaimer" a.Ast.def_name;
      Alcotest.(check string) "1 text" "x" a.Ast.def_text;
      Alcotest.(check string) "2 name" "rubric" b.Ast.def_name
  | Ok _ -> Alcotest.fail "expected two defs"
```

- [ ] **Step 2: Run to verify it fails**

`dune test 2>&1 | head -20` → expect `Ast.LDef`/`tpl_name`/`block_extends` unbound.

- [ ] **Step 3: Extend the AST**

In `lib/ast.ml`:
- Add after `def_decl`/`import_decl`:
```ocaml
type template_decl = { tpl_name : string; tpl_items : agent_item list; tpl_loc : Location.t }
type lib_item = LDef of def_decl | LTemplate of template_decl
```
- Add a field to `agent_block`:
```ocaml
type agent_block = {
  block_name : string;
  block_items : agent_item list;
  block_loc : Location.t;
  block_extends : (string * string * Location.t) option;
}
```
(`template_decl`/`lib_item` must come after `agent_item` is defined and after `def_decl`. `agent_block` already follows `agent_item`.)

- [ ] **Step 4: Extend the lexer**

In `lib/lexer.mll`: add to `keywords`: `("template", TEMPLATE); ("extends", EXTENDS);`. Add a token rule among the punctuation: `| '.' { DOT }`.

- [ ] **Step 5: Extend the parser**

In `lib/parser.mly`:
- Add tokens: `%token TEMPLATE EXTENDS DOT`.
- Change the `library` start type and rule. Replace `%start <Ast.def_decl list> library` with `%start <Ast.lib_item list> library`, and the rule:
```
library:
  | items = list(lib_item) EOF { items }

lib_item:
  | d = def_decl { Ast.LDef d }
  | t = template_decl { Ast.LTemplate t }

template_decl:
  | TEMPLATE name = IDENT LBRACE items = list(item) RBRACE
    { { tpl_name = name; tpl_items = items; tpl_loc = mkloc $loc } }
```
- Change the `agent` rule to accept an optional `extends` and set `block_extends`:
```
agent:
  | AGENT name = STRING ext = extends_opt LBRACE items = list(item) RBRACE
    { { block_name = name; block_items = items; block_loc = mkloc $loc; block_extends = ext } }

extends_opt:
  | { None }
  | EXTENDS a = IDENT DOT n = IDENT { Some (a, n, mkloc $loc) }
```
(`def_decl`/`import_decl`/`item` rules are unchanged.)

- [ ] **Step 6: Update `lib/compile.ml` and `lib/resolve.ml`**

In `lib/compile.ml`, `parse_library`'s type changes automatically (it's `run_parser Parser.library`), but update the annotation:
```ocaml
let parse_library (src : string) : (Ast.lib_item list, Error.t) result =
  run_parser Parser.library src
```
In `lib/resolve.ml`, `resolve` calls `parse_lib contents` which now yields `lib_item list`. Keep `resolve` returning `fragments` for now (templates handled in Task 2) by extracting the defs. Change the `parse_lib` param type and the `Ok defs ->` arm:
```ocaml
let resolve ~(parse_lib : string -> (Ast.lib_item list, Error.t) result)
    ~(resolver : string -> (string, string) result) (imports : Ast.import_decl list) :
    (fragments, Error.t list) result =
```
and inside, replace `| Ok defs ->` with:
```ocaml
            | Ok items ->
                let defs =
                  List.filter_map (function Ast.LDef d -> Some d | Ast.LTemplate _ -> None) items
                in
```
(The rest of that arm — the `seen_def` dedup building `pairs` from `defs` — is unchanged.)

- [ ] **Step 7: Run to verify it passes**

`dune build 2>&1 | head && dune test 2>&1 | tail -8 && ./scripts/check-corpus.sh`
Expected: clean build (no menhir conflicts), the new `template`/`extends` cases + updated `library` case pass, all prior pass, corpus 25/25.

- [ ] **Step 8: Commit**

```bash
git add lib/ast.ml lib/lexer.mll lib/parser.mly lib/compile.ml lib/resolve.ml test/test_parser.ml
git commit -m "feat(template): parse template decls and 'extends alias.Name'"
```

---

### Task 2: resolve collects templates → `resolved`

**Files:** Modify `lib/resolve.ml`, `lib/compile.ml`, `test/test_resolve.ml`.

- [ ] **Step 1: Write the failing test**

Add to `test/test_resolve.ml` (and register), plus update the existing tests to use the new return type. First, the existing four tests bind `Ok frags ->` / use `Resolve.resolve … with Ok frags`. They now get a `resolved` record. Update `test_resolve_ok` to:
```ocaml
let test_resolve_ok () =
  let files = [ ("fin.prompt", {|def disclaimer = "D"  def rubric = "R"|}) ] in
  match
    Resolve.resolve ~parse_lib:Compile.parse_library ~resolver:(mem files)
      [ imp "fin.prompt" "fin" ]
  with
  | Error _ -> Alcotest.fail "unexpected error"
  | Ok r ->
      Alcotest.(check (option string)) "found" (Some "D")
        (Resolve.lookup r.Resolve.fragments "fin" "disclaimer")
```
(The `not found` / `not def-only` / `dup alias` tests match `Ok _ -> Alcotest.fail …`, so they need no change.) Add a template test:
```ocaml
let test_resolve_template () =
  let files = [ ("s.prompt", {|template Rater { step { summarize } }|}) ] in
  match
    Resolve.resolve ~parse_lib:Compile.parse_library ~resolver:(mem files) [ imp "s.prompt" "s" ]
  with
  | Error _ -> Alcotest.fail "unexpected error"
  | Ok r -> (
      match Resolve.find_template r "s" "Rater" with
      | Some items -> Alcotest.(check int) "tpl items" 1 (List.length items)
      | None -> Alcotest.fail "expected template Rater")
```
Register `Alcotest.test_case "template" `Quick test_resolve_template;`.

- [ ] **Step 2: Run to verify it fails**

`dune test 2>&1 | head -10` → `Resolve.find_template` unbound / `r.Resolve.fragments` field error.

- [ ] **Step 3: Change `resolve` to return `resolved` and collect templates**

In `lib/resolve.ml`, add the type + lookup near the top (after `fragments`):
```ocaml
type resolved = {
  fragments : fragments;
  templates : ((string * string) * Ast.agent_item list) list;
}

let find_template (r : resolved) (alias : string) (name : string) :
    Ast.agent_item list option =
  List.assoc_opt (alias, name) r.templates
```
Change `resolve`'s return type to `(resolved, Error.t list) result`, add a `tmpls` accumulator, and in the `Ok items ->` arm collect templates (alongside the existing defs handling). Replace the body of that arm with:
```ocaml
            | Ok items ->
                let defs =
                  List.filter_map (function Ast.LDef d -> Some d | Ast.LTemplate _ -> None) items
                in
                let tpls =
                  List.filter_map (function Ast.LTemplate t -> Some t | Ast.LDef _ -> None) items
                in
                let seen_def = Hashtbl.create 8 in
                let pairs =
                  List.filter_map
                    (fun (d : Ast.def_decl) ->
                      if Hashtbl.mem seen_def d.Ast.def_name then begin
                        add imp.Ast.imp_loc
                          (Printf.sprintf "duplicate def '%s' in import %S" d.Ast.def_name
                             imp.Ast.imp_path);
                        None
                      end
                      else begin
                        Hashtbl.add seen_def d.Ast.def_name ();
                        Some (d.Ast.def_name, d.Ast.def_text)
                      end)
                    defs
                in
                frags := (imp.Ast.imp_alias, pairs) :: !frags;
                let seen_tpl = Hashtbl.create 8 in
                List.iter
                  (fun (t : Ast.template_decl) ->
                    if Hashtbl.mem seen_tpl t.Ast.tpl_name then
                      add t.Ast.tpl_loc
                        (Printf.sprintf "duplicate template '%s' in import %S" t.Ast.tpl_name
                           imp.Ast.imp_path)
                    else begin
                      Hashtbl.add seen_tpl t.Ast.tpl_name ();
                      tmpls := ((imp.Ast.imp_alias, t.Ast.tpl_name), t.Ast.tpl_items) :: !tmpls
                    end)
                  tpls
```
Add `and tmpls = ref []` next to `let frags = ref [] in` (i.e. `let frags = ref [] and tmpls = ref [] in`). Change the final return:
```ocaml
  match List.rev !errors with
  | [] -> Ok { fragments = List.rev !frags; templates = List.rev !tmpls }
  | es -> Error es
```

- [ ] **Step 4: Update `compile.ml`'s frontend to use `resolved.fragments`**

In `lib/compile.ml`, `frontend` currently does `match Resolve.resolve … with … | Ok fragments -> … Sema.analyze ~fragments …`. The bound name is now a `resolved` record. Change it to:
```ocaml
      | Ok resolved -> (
          match Sema.analyze ~fragments:resolved.Resolve.fragments af.Ast.af_agent with
          | Error ds -> Error ds
          | Ok checked -> Ok (checked, resolved.Resolve.fragments)))
```
(Expand is wired in Task 4 — for now sema still runs on `af.Ast.af_agent` directly.)

- [ ] **Step 5: Run to verify it passes**

`dune test 2>&1 | tail -8 && ./scripts/check-corpus.sh`
Expected: the `resolve` suite (incl. new `template` case) passes; all prior pass; corpus 25/25.

- [ ] **Step 6: Commit**

```bash
git add lib/resolve.ml lib/compile.ml test/test_resolve.ml
git commit -m "feat(template): resolve collects templates; resolved record + find_template"
```

---

### Task 3: `expand` — apply extends (whole-clause merge)

**Files:** Create `lib/expand.ml`, `test/test_expand.ml`; register in `test/test_promptdsl.ml`.

- [ ] **Step 1: Write the failing tests**

`test/test_expand.ml`:
```ocaml
open Promptdsl

(* Build a resolved with a single template under alias.name. *)
let resolved_with alias name items : Resolve.resolved =
  { Resolve.fragments = []; templates = [ ((alias, name), items) ] }

(* Parse an agent file and return its agent_block. *)
let agent src =
  match Compile.parse src with
  | Error e -> Alcotest.failf "parse: %s" e.Error.message
  | Ok af -> af.Ast.af_agent

(* Count items of each kind in a block. *)
let counts (b : Ast.agent_block) =
  let n f = List.length (List.filter f b.Ast.block_items) in
  ( n (function Ast.IGoal _ -> true | _ -> false),
    n (function Ast.IStep _ -> true | _ -> false),
    n (function Ast.IOutput _ -> true | _ -> false) )

let goal_text (b : Ast.agent_block) =
  List.find_map (function Ast.IGoal g -> Some g.Ast.v | _ -> None) b.Ast.block_items

let test_inherit_and_override () =
  (* template has goal "T" + 2 steps; agent overrides goal, omits steps -> inherits *)
  let tpl = (agent {|agent "t" { goal "T" step { summarize } step { summarize } }|}).Ast.block_items in
  let ag = agent {|agent "a" extends m.Base { goal "A" }|} in
  match Expand.expand (resolved_with "m" "Base" tpl) ag with
  | Error _ -> Alcotest.fail "unexpected error"
  | Ok merged ->
      Alcotest.(check (option string)) "goal overridden" (Some "A") (goal_text merged);
      let _, steps, _ = counts merged in
      Alcotest.(check int) "steps inherited" 2 steps

let test_unknown_template () =
  let ag = agent {|agent "a" extends m.Nope { goal "A" }|} in
  match Expand.expand (resolved_with "m" "Base" []) ag with
  | Ok _ -> Alcotest.fail "expected error"
  | Error ds ->
      Alcotest.(check bool) "unknown template" true
        (List.exists (fun (d : Error.t) -> d.Error.message = "unknown template 'm.Nope'") ds)

let test_no_extends_passthrough () =
  let ag = agent {|agent "a" { goal "A" }|} in
  match Expand.expand { Resolve.fragments = []; templates = [] } ag with
  | Ok merged -> Alcotest.(check (option string)) "unchanged" (Some "A") (goal_text merged)
  | Error _ -> Alcotest.fail "unexpected error"

let suite =
  ( "expand",
    [ Alcotest.test_case "inherit + override" `Quick test_inherit_and_override;
      Alcotest.test_case "unknown template" `Quick test_unknown_template;
      Alcotest.test_case "no extends" `Quick test_no_extends_passthrough ] )
```
Append `Test_expand.suite` to the runner in `test/test_promptdsl.ml`.

- [ ] **Step 2: Run to verify it fails**

`dune test 2>&1 | head -10` → `Unbound module Expand`.

- [ ] **Step 3: Implement `expand`**

`lib/expand.ml`:
```ocaml
(* Split a body into the four clause sublists, preserving order within each. *)
let classify (items : Ast.agent_item list) =
  let is f x = f x in
  ( List.filter (is (function Ast.IInputs _ -> true | _ -> false)) items,
    List.filter (is (function Ast.IGoal _ -> true | _ -> false)) items,
    List.filter (is (function Ast.IStep _ -> true | _ -> false)) items,
    List.filter (is (function Ast.IOutput _ -> true | _ -> false)) items )

let expand (resolved : Resolve.resolved) (block : Ast.agent_block) :
    (Ast.agent_block, Error.t list) result =
  match block.Ast.block_extends with
  | None -> Ok block
  | Some (alias, name, loc) -> (
      match Resolve.find_template resolved alias name with
      | None ->
          Error [ Error.make loc (Printf.sprintf "unknown template '%s.%s'" alias name) ]
      | Some tpl_items ->
          let ai, ag, as_, ao = classify block.Ast.block_items in
          let ti, tg, ts, to_ = classify tpl_items in
          let pick a t = if a <> [] then a else t in
          let merged = pick ai ti @ pick ag tg @ pick as_ ts @ pick ao to_ in
          Ok { block with Ast.block_items = merged; block_extends = None })
```

- [ ] **Step 4: Run to verify it passes**

`dune test 2>&1 | tail -6` → `expand` suite passes; all prior pass.

- [ ] **Step 5: Commit**

```bash
git add lib/expand.ml test/test_expand.ml test/test_promptdsl.ml
git commit -m "feat(template): expand stage applies extends via whole-clause merge"
```

---

### Task 4: Wire `expand` into compile + end-to-end

**Files:** Modify `lib/compile.ml`, `test/test_backends.ml`.

- [ ] **Step 1: Write the failing test**

Add to `test/test_backends.ml` (and register) — full compile where an agent extends a template, inherits steps + output, declares an input, overrides the goal:
```ocaml
let test_extends_end_to_end () =
  let resolver = function
    | "s.prompt" ->
        Ok {|template Rater {
               step { summarize }
               output json { rating: enum("buy","sell"); why: string }
             }|}
    | _ -> Error "no such file"
  in
  let src =
    {|import "s.prompt" as s
      agent "a" extends s.Rater {
        input { topic: string }
        goal "Rate {{topic}}."
      }|}
  in
  match Compile.compile_string ~resolver ~values:[ ("topic", "TSLA") ] src with
  | Compile.Failure ds ->
      Alcotest.failf "unexpected failure: %s"
        (String.concat "; " (List.map (fun (d : Error.t) -> d.Error.message) ds))
  | Compile.Success o ->
      let open Yojson.Safe.Util in
      Alcotest.(check bool) "goal substituted" true (contains o.Compile.prose "Goal: Rate TSLA.");
      Alcotest.(check bool) "step inherited" true (contains o.Compile.prose "Summarize the findings");
      Alcotest.(check string) "output inherited" "json_schema"
        (o.Compile.json |> member "response_format" |> member "type" |> to_string)
```
Register: `Alcotest.test_case "extends end-to-end" `Quick test_extends_end_to_end;`.

- [ ] **Step 2: Run to verify it fails**

`dune test 2>&1 | tail -12` → fails (the agent's `extends` isn't applied yet, so `{{topic}}`-less inherited template clauses aren't present / sema sees the bare agent which has no steps/output — the assertions on inherited step/output fail).

- [ ] **Step 3: Insert `expand` into the frontend**

In `lib/compile.ml`'s `frontend`, between resolve and sema, apply expand. Replace the `Ok resolved -> …` arm with:
```ocaml
      | Ok resolved -> (
          match Expand.expand resolved af.Ast.af_agent with
          | Error ds -> Error ds
          | Ok merged -> (
              match Sema.analyze ~fragments:resolved.Resolve.fragments merged with
              | Error ds -> Error ds
              | Ok checked -> Ok (checked, resolved.Resolve.fragments))))
```

- [ ] **Step 4: Run to verify it passes**

`dune test 2>&1 | tail -6 && ./scripts/check-corpus.sh`
Expected: `extends end-to-end` passes; all prior pass; corpus 25/25 (no-extends agents unaffected — `Expand.expand` returns them unchanged).

- [ ] **Step 5: Commit**

```bash
git add lib/compile.ml test/test_backends.ml
git commit -m "feat(template): wire expand into the compile frontend"
```

---

### Task 5: cram end-to-end

**Files:** Create `test/cram/template.t`.

- [ ] **Step 1: Manual check**

```bash
dune build 2>&1 | head
mkdir -p /tmp/tpldemo
printf 'template Rater {\n  step { summarize }\n  output json { rating: enum("buy","sell"); why: string }\n}\n' > /tmp/tpldemo/s.prompt
printf 'import "s.prompt" as s\nagent "a" extends s.Rater {\n  input { topic: string }\n  goal "Rate {{topic}}."\n}\n' > /tmp/tpldemo/a.prompt
dune exec promptc -- compile /tmp/tpldemo/a.prompt --set topic=TSLA --emit prose
```
Expected prose: `Goal: Rate TSLA.`, a numbered step `Summarize the findings`, and a `Return ONLY JSON matching this schema:` block with `rating`/`why`. Then unknown template:
```bash
printf 'import "s.prompt" as s\nagent "a" extends s.Nope { goal "g" }\n' > /tmp/tpldemo/bad.prompt
dune exec promptc -- compile /tmp/tpldemo/bad.prompt; echo "exit=$?"
```
Expected: `unknown template 's.Nope'` diagnostic, `exit=1`.

- [ ] **Step 2: Add the cram test (commands only; promote)**

`test/cram/template.t`:
```
An agent inherits steps + output from a template and overrides the goal:

  $ printf 'template Rater {\n  step { summarize }\n  output json { rating: enum("buy","sell"); why: string }\n}\n' > s.prompt
  $ printf 'import "s.prompt" as s\nagent "a" extends s.Rater {\n  input { topic: string }\n  goal "Rate {{topic}}."\n}\n' > a.prompt
  $ promptc compile a.prompt --set topic=TSLA --emit prose

An unknown template is reported and exits 1:

  $ printf 'import "s.prompt" as s\nagent "a" extends s.Nope { goal "g" }\n' > nope.prompt
  $ promptc compile nope.prompt
  [1]
```

- [ ] **Step 3: Record golden output and verify**

```bash
dune runtest --auto-promote 2>&1 | tail -5
dune runtest 2>&1; echo "exit=$?"
```
Review `git diff test/cram/template.t`: the prose block shows `Goal: Rate TSLA.`, the inherited `Summarize the findings` step, and the inherited JSON schema; the unknown-template block shows `unknown template 's.Nope'` and `[1]`. Confirm `test/cram/{compile,check,emit,input,import}.t` are UNCHANGED. Re-run `dune runtest` → clean, exit 0.

- [ ] **Step 4: Final full check**

```bash
dune runtest --force 2>&1 | tail -4
./scripts/check-corpus.sh
```
Expected: all unit + cram pass; corpus 25/25 unchanged.

- [ ] **Step 5: Commit**

```bash
git add test/cram/template.t
git commit -m "feat(template): cram coverage for extends + clause inheritance"
```

---

## Self-Review

**Spec coverage:**
- `template Name {…}` in lib + `extends alias.Name` surface → Task 1 (parse) + Task 3 (merge) + Task 4 (wire).
- Whole-clause override (each slot: agent's else template's; steps all-or-nothing) → `Expand.classify`/`pick` (Task 3), tested by `inherit + override`.
- Post-merge goal requirement → sema runs on the merged block (Task 4); a merged agent with no goal still hits sema's existing "missing required 'goal'".
- Refs in merged clauses resolve in the extender's scope → sema/bind run on the merged block with the agent's `~fragments`; inputs come from the merged block. The end-to-end test (template step has no ref; agent goal uses `{{topic}}` against its own input) exercises this.
- resolve collects templates; `resolved` record + `find_template` → Task 2.
- expand new module → Task 3.
- Single level / not-standalone-validated / no local templates → templates are only parsed (never sema'd) and only live in lib files (the `library` grammar); a `template` in an agent file is a parse error (agent grammar has no template rule). No template-extends-template rule exists.
- Backward compat → Tasks 1/2/4 keep no-extends/no-import paths; corpus 25/25 checks; cram goldens unchanged.

**Placeholder scan:** none — full code per step; the `parse_library`/`resolve` return-type ripples (Task 1 Step 6, Task 2 Steps 1/3/4) are spelled out with exact replacement code; cram output via `--auto-promote` with review criteria.

**Type consistency:** `Ast.template_decl` (`tpl_*`), `Ast.lib_item` (`LDef`/`LTemplate`), `agent_block.block_extends : (string*string*Location.t) option`; `Compile.parse_library : … lib_item list`; `Resolve.resolved = { fragments; templates }`, `Resolve.find_template`; `Expand.expand : Resolve.resolved -> agent_block -> (agent_block, …) result`. The `classify` 4-tuple order (inputs, goal, steps, output) matches the `pick … @ pick …` merge order. `frontend` passes `resolved.Resolve.fragments` to sema/bind and `resolved` to `Expand.expand`. No cycle: `Expand` depends on `Resolve`+`Ast`+`Error`; `Resolve` depends on `Ast`+`Error` (parse injected); `Compile` depends on all.
