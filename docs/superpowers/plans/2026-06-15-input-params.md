# Input Parameters Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a typed `input { }` block with `{{name}}` interpolation, compiled by `promptc compile --set k=v` (compile-time substitution), with one input markable `@content` to fill the OpenAI user message.

**Architecture:** New pipeline stage `bind` sits between `sema` and `lower`: sema validates the input block and that every `{{ref}}` is declared; bind merges `--set` values with defaults, type-checks them, substitutes `{{name}}` in the goal/step strings, and resolves the `@content` value. A small `interp` module owns `{{...}}` scanning. Agents with no `input` block are byte-identical to today.

**Tech Stack:** OCaml, dune, Menhir, ocamllex, yojson, cmdliner, alcotest (all already set up).

**Spec:** `docs/superpowers/specs/2026-06-15-input-params-design.md`

---

## Conventions (carry into every task)

- Run `dune test` for unit suites; `./scripts/check-corpus.sh` must still pass (backward compat).
- Field-name distinctness convention holds: `Ast.input_decl` uses `in_*`, `Sema.checked_input` uses `ci_*`, `Bind.bound` uses `b_*`, `Ir.t` gains `content`.
- Commit on a feature branch (the executor sets this up). Trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

## Type vocabulary (defined across tasks — keep identical)

```
Ast.input_decl     = { in_name:string; in_ty:Ast.ty; in_default:string option; in_content:bool; in_loc:Location.t }
Ast.agent_item    += IInputs of input_decl list node
Sema.checked_input = { ci_name:string; ci_ty:Ast.ty; ci_default:string option; ci_content:bool; ci_loc:Location.t }
Sema.checked      += inputs : checked_input list
Bind.bound         = { b_name:string; b_goal:string; b_steps:Sema.checked_step list; b_output:Sema.checked_output; b_content:string option }
Ir.t              += content : string option   (* None=no input block -> legacy {{input}}; Some s=user message (s may be "") *)
```

## File map

```
lib/ast.ml           + input_decl; IInputs variant
lib/lexer.mll        + `input` keyword, `@content` token, `=` token
lib/parser.mly       + input block + input-field rules
lib/interp.ml        NEW: {{name}} scan/substitute
lib/sema.ml          + input validation, {{ref}}-declared check, checked.inputs
lib/bind.ml          NEW: resolve values+defaults, type-check, substitute, content
lib/ir.ml            + content field
lib/lower.ml         consume Bind.bound; set Ir.content
lib/backend_prose.ml render "## Input" section when content present & non-empty
lib/backend_openai.ml user message from content (per the table below)
lib/compile.ml       compile_string gains ?values; runs bind
lib/driver.ml        parse --set; pass values through
bin/main.ml          `--set k=v` repeatable arg
test/*               new alcotest cases + cram
```

User-message rule (implemented in backends via `Ir.content`):

| `Ir.content` | user message |
| --- | --- |
| `None` (no input block) | `{{input}}` (unchanged) |
| `Some s` (content input bound) | `s` |
| `Some ""` (input block, no `@content`) | `""` |

---

### Task 1: Parse the `input` block

**Files:** Modify `lib/ast.ml`, `lib/lexer.mll`, `lib/parser.mly`; add `test/test_parser.ml` cases.

- [ ] **Step 1: Write the failing test**

Add to `test/test_parser.ml` (before `let suite`), and register the two cases in the suite list:
```ocaml
let test_parse_input_block () =
  let src =
    {|agent "a" {
        input {
          ticker: string
          depth:  enum("brief", "deep") = "brief"
          notes:  string @content
        }
        goal "Analyze {{ticker}} at {{depth}}."
      }|}
  in
  match Compile.parse src with
  | Error e -> Alcotest.failf "unexpected parse error: %s" e.Error.message
  | Ok block -> (
      match
        List.find_map
          (function Ast.IInputs n -> Some n.Ast.v | _ -> None)
          block.Ast.block_items
      with
      | Some [ a; b; c ] ->
          Alcotest.(check string) "1 name" "ticker" a.Ast.in_name;
          Alcotest.(check bool) "1 required" true (a.Ast.in_default = None);
          Alcotest.(check (option string)) "2 default" (Some "brief") b.Ast.in_default;
          Alcotest.(check bool) "3 content" true c.Ast.in_content
      | _ -> Alcotest.fail "expected an input block with 3 fields")
```

Add to the suite list: `Alcotest.test_case "input block" `Quick test_parse_input_block;`.

- [ ] **Step 2: Run test to verify it fails**

Run: `dune test 2>&1 | head -20`
Expected: compile error — `Ast.IInputs` / `in_name` unbound.

- [ ] **Step 3: Extend the AST**

In `lib/ast.ml`, add the `input_decl` type after `field` and a variant to `agent_item`:
```ocaml
type input_decl = {
  in_name : string;
  in_ty : ty;
  in_default : string option;
  in_content : bool;
  in_loc : Location.t;
}
```
Change `agent_item` to add the variant:
```ocaml
type agent_item =
  | IGoal of string node
  | IStep of action
  | IOutput of raw_output node
  | IInputs of input_decl list node
```

- [ ] **Step 4: Extend the lexer**

In `lib/lexer.mll`, add `("input", INPUT)` to the `keywords` list, and add these rules to the `token` rule (next to the other punctuation, before the `ident` rule is fine since `@`/`=` aren't ident chars):
```ocaml
  | '='            { EQ }
  | "@content"     { CONTENT }
```

- [ ] **Step 5: Extend the parser**

In `lib/parser.mly`: add tokens, then the rules.

Add to the `%token` declarations:
```
%token INPUT CONTENT EQ
```
Add an `item` alternative:
```
  | INPUT LBRACE fs = list(input_field) RBRACE
    { IInputs (mknode fs $loc) }
```
Add these rules (after `field`):
```
input_field:
  | name = IDENT COLON t = ty d = default_opt c = content_opt
    { { in_name = name; in_ty = t; in_default = d; in_content = c; in_loc = mkloc $loc } }

default_opt:
  | { None }
  | EQ s = STRING { Some s }

content_opt:
  | { false }
  | CONTENT { true }
```

- [ ] **Step 6: Run test to verify it passes**

Run: `dune build 2>&1 | head -20 && dune test 2>&1 | tail -5`
Expected: build clean (no menhir conflicts), the new `input block` case passes, all prior parser/sema/etc. cases still pass.

- [ ] **Step 7: Commit**

```bash
git add lib/ast.ml lib/lexer.mll lib/parser.mly test/test_parser.ml
git commit -m "feat(input): parse the input{} block (decls, defaults, @content)"
```

---

### Task 2: `interp` — `{{name}}` scan & substitute

**Files:** Create `lib/interp.ml`, `test/test_interp.ml`; register suite in `test/test_promptdsl.ml`.

- [ ] **Step 1: Write the failing test**

`test/test_interp.ml`:
```ocaml
open Promptdsl

let test_refs () =
  Alcotest.(check (list string)) "refs"
    [ "ticker"; "depth" ]
    (Interp.refs "Analyze {{ticker}} at {{ depth }} depth.");
  Alcotest.(check (list string)) "none" [] (Interp.refs "no refs here")

let test_subst () =
  let lookup = function "ticker" -> Some "TSLA" | _ -> None in
  Alcotest.(check string) "subst"
    "Analyze TSLA now"
    (Interp.subst lookup "Analyze {{ticker}} now");
  (* unknown refs are left verbatim; subst is not responsible for validation *)
  Alcotest.(check string) "unknown left as-is"
    "Hi {{name}}"
    (Interp.subst lookup "Hi {{name}}")

let suite =
  ( "interp",
    [ Alcotest.test_case "refs" `Quick test_refs;
      Alcotest.test_case "subst" `Quick test_subst ] )
```

Add `Test_interp.suite` to the runner list in `test/test_promptdsl.ml`.

- [ ] **Step 2: Run test to verify it fails**

Run: `dune test 2>&1 | head -10`
Expected: `Unbound module Interp`.

- [ ] **Step 3: Implement `interp`**

`lib/interp.ml`:
```ocaml
(* Scan a string for {{ name }} occurrences. Returns each (name, start, stop)
   where the literal {{...}} spans [start, stop) in the original string. *)
let tokens (s : string) : (string * int * int) list =
  let n = String.length s in
  let acc = ref [] in
  let i = ref 0 in
  while !i + 1 < n do
    if s.[!i] = '{' && s.[!i + 1] = '{' then begin
      let j = ref (!i + 2) in
      let close = ref (-1) in
      while !j + 1 < n && !close < 0 do
        if s.[!j] = '}' && s.[!j + 1] = '}' then close := !j else incr j
      done;
      if !close >= 0 then begin
        let name = String.trim (String.sub s (!i + 2) (!close - (!i + 2))) in
        acc := (name, !i, !close + 2) :: !acc;
        i := !close + 2
      end
      else i := n
    end
    else incr i
  done;
  List.rev !acc

(* Names referenced by {{...}}, ignoring malformed empties. *)
let refs (s : string) : string list =
  List.filter_map
    (fun (name, _, _) -> if name = "" then None else Some name)
    (tokens s)

(* Replace each {{name}} via [lookup]; unknown names are left verbatim. *)
let subst (lookup : string -> string option) (s : string) : string =
  match tokens s with
  | [] -> s
  | toks ->
      let b = Buffer.create (String.length s) in
      let pos = ref 0 in
      List.iter
        (fun (name, start, stop) ->
          Buffer.add_string b (String.sub s !pos (start - !pos));
          (match lookup name with
           | Some v -> Buffer.add_string b v
           | None -> Buffer.add_string b (String.sub s start (stop - start)));
          pos := stop)
        toks;
      Buffer.add_string b (String.sub s !pos (String.length s - !pos));
      Buffer.contents b
```

- [ ] **Step 4: Run test to verify it passes**

Run: `dune test 2>&1 | tail -5`
Expected: `interp` suite passes.

- [ ] **Step 5: Commit**

```bash
git add lib/interp.ml test/test_interp.ml test/test_promptdsl.ml
git commit -m "feat(input): interp module for {{name}} scan and substitution"
```

---

### Task 3: Sema — validate inputs + `{{ref}}` declared

**Files:** Modify `lib/sema.ml`, `test/test_sema.ml`.

- [ ] **Step 1: Write the failing tests**

Add to `test/test_sema.ml` (before `let suite`) and register them:
```ocaml
let test_valid_inputs () =
  let c =
    ok_or_fail
      {|agent "a" { input { ticker: string  depth: enum("b","d") = "b" } goal "x {{ticker}} {{depth}}" }|}
  in
  Alcotest.(check int) "inputs" 2 (List.length c.Sema.inputs)

let test_undeclared_ref () =
  let ds = err_or_fail {|agent "a" { goal "analyze {{ticker}}" }|} in
  Alcotest.(check bool) "undeclared ref" true
    (List.exists
       (fun (d : Error.t) -> d.Error.message = "undeclared input reference '{{ticker}}'")
       ds)

let test_dup_input () =
  let ds = err_or_fail {|agent "a" { input { x: string  x: string } goal "g" }|} in
  Alcotest.(check bool) "dup input" true
    (List.exists (fun (d : Error.t) -> d.Error.message = "duplicate input 'x'") ds)

let test_two_content () =
  let ds =
    err_or_fail {|agent "a" { input { x: string @content  y: string @content } goal "g" }|}
  in
  Alcotest.(check bool) "two content" true
    (List.exists
       (fun (d : Error.t) -> d.Error.message = "at most one input may be @content")
       ds)

let test_default_on_int () =
  let ds = err_or_fail {|agent "a" { input { n: int = "5" } goal "g" }|} in
  Alcotest.(check bool) "default on int" true
    (List.exists
       (fun (d : Error.t) ->
         d.Error.message = "a default is only allowed on string or enum inputs")
       ds)

let test_content_not_string () =
  let ds = err_or_fail {|agent "a" { input { n: int @content } goal "g" }|} in
  Alcotest.(check bool) "content not string" true
    (List.exists
       (fun (d : Error.t) -> d.Error.message = "@content must be on a string input")
       ds)
```
Register in the suite list: `valid inputs`, `undeclared ref`, `dup input`, `two content`, `default on int`, `content not string`.

- [ ] **Step 2: Run to verify it fails**

Run: `dune test 2>&1 | head -10`
Expected: `Sema.inputs` / record field unbound (checked has no `inputs` yet).

- [ ] **Step 3: Extend Sema types**

In `lib/sema.ml`, add after `checked_step`:
```ocaml
type checked_input = {
  ci_name : string;
  ci_ty : Ast.ty;
  ci_default : string option;
  ci_content : bool;
  ci_loc : Location.t;
}
```
Add `inputs : checked_input list;` to the `checked` record.

- [ ] **Step 4: Handle the input block and ref-check in `analyze`**

In `analyze`, add a ref accumulator near the other refs:
```ocaml
  let inputs = ref [] and saw_input_block = ref false in
  let ref_sites = ref [] in   (* (text, span) to validate {{...}} against declared inputs *)
```
In the goal case, record the ref site (change the `IGoal` arm to also push):
```ocaml
      | IGoal g -> (
          ref_sites := (g.v, g.span) :: !ref_sites;
          match !goal with
          | None -> goal := Some g.v
          | Some _ -> add (Error.make g.span "duplicate 'goal'"))
```
In the `IStep` arm, after computing `name`, record a ref site for the arg (add this line right after `let name = a.action_name.v in`):
```ocaml
          (match a.action_arg with
           | Some arg -> ref_sites := (arg, a.action_name.span) :: !ref_sites
           | None -> ());
```
Add a new `IInputs` arm to the item match:
```ocaml
      | IInputs blk ->
          if !saw_input_block then
            add (Error.make blk.span "duplicate 'input' block")
          else begin
            saw_input_block := true;
            let seen = Hashtbl.create 8 in
            let content_count = ref 0 in
            List.iter
              (fun (d : Ast.input_decl) ->
                (if Hashtbl.mem seen d.in_name then
                   add (Error.make d.in_loc (Printf.sprintf "duplicate input '%s'" d.in_name))
                 else Hashtbl.add seen d.in_name ());
                (match d.in_ty with
                 | Ast.TList _ ->
                     add (Error.make d.in_loc "list is not allowed as an input type")
                 | _ -> ());
                (match (d.in_default, d.in_ty) with
                 | Some _, Ast.TString -> ()
                 | Some def, Ast.TEnum opts ->
                     if not (List.mem def opts) then
                       add (Error.make d.in_loc
                              (Printf.sprintf "default %S is not one of the enum options" def))
                 | Some _, _ ->
                     add (Error.make d.in_loc
                            "a default is only allowed on string or enum inputs")
                 | None, _ -> ());
                (if d.in_content then begin
                   incr content_count;
                   (match d.in_ty with
                    | Ast.TString -> ()
                    | _ -> add (Error.make d.in_loc "@content must be on a string input"))
                 end);
                inputs :=
                  { ci_name = d.in_name; ci_ty = d.in_ty; ci_default = d.in_default;
                    ci_content = d.in_content; ci_loc = d.in_loc }
                  :: !inputs)
              blk.v;
            if !content_count > 1 then
              add (Error.make blk.span "at most one input may be @content")
          end
```
After the `List.iter ... block.block_items;` loop (and after computing `goal_val`), validate refs against declared input names — insert before the final `match List.rev !errors with`:
```ocaml
  let declared = List.map (fun (i : checked_input) -> i.ci_name) !inputs in
  List.iter
    (fun (text, span) ->
      List.iter
        (fun name ->
          if not (List.mem name declared) then
            add (Error.make span
                   (Printf.sprintf "undeclared input reference '{{%s}}'" name)))
        (Interp.refs text))
    (List.rev !ref_sites);
```
Finally, add `inputs = List.rev !inputs;` to the record built in the `Ok` branch.

- [ ] **Step 5: Run to verify it passes**

Run: `dune test 2>&1 | tail -8`
Expected: all six new sema cases pass; prior cases still pass.

- [ ] **Step 6: Commit**

```bash
git add lib/sema.ml test/test_sema.ml
git commit -m "feat(input): sema validates input block and {{ref}} declarations"
```

---

### Task 4: `bind` — resolve values, type-check, substitute

**Files:** Create `lib/bind.ml`, `test/test_bind.ml`; register suite.

- [ ] **Step 1: Write the failing tests**

`test/test_bind.ml`:
```ocaml
open Promptdsl

let bind src values =
  match Compile.parse_and_check src with
  | Error ds -> Alcotest.failf "sema error: %s" (String.concat "; " (List.map (fun (d:Error.t) -> d.Error.message) ds))
  | Ok c -> Bind.bind c values

let test_subst_and_default () =
  match bind {|agent "a" { input { ticker: string  depth: enum("b","d") = "d" } goal "{{ticker}} {{depth}}" }|}
          [ ("ticker", "TSLA") ] with
  | Error ds -> Alcotest.failf "unexpected: %s" (String.concat "; " (List.map (fun (d:Error.t) -> d.Error.message) ds))
  | Ok b -> Alcotest.(check string) "goal" "TSLA d" b.Bind.b_goal

let test_missing_required () =
  match bind {|agent "a" { input { ticker: string } goal "{{ticker}}" }|} [] with
  | Ok _ -> Alcotest.fail "expected missing-input error"
  | Error ds ->
      Alcotest.(check bool) "missing" true
        (List.exists (fun (d:Error.t) ->
           d.Error.message = "missing required input 'ticker' (use --set ticker=...)") ds)

let test_type_mismatch () =
  match bind {|agent "a" { input { n: int } goal "g {{n}}" }|} [ ("n", "abc") ] with
  | Ok _ -> Alcotest.fail "expected type error"
  | Error ds ->
      Alcotest.(check bool) "type" true
        (List.exists (fun (d:Error.t) -> d.Error.message = "input 'n': expected an int, got \"abc\"") ds)

let test_unknown_set () =
  match bind {|agent "a" { input { x: string } goal "{{x}}" }|} [ ("x","v"); ("y","z") ] with
  | Ok _ -> Alcotest.fail "expected unknown-input error"
  | Error ds ->
      Alcotest.(check bool) "unknown" true
        (List.exists (fun (d:Error.t) -> d.Error.message = "unknown input 'y' passed with --set") ds)

let test_content () =
  match bind {|agent "a" { input { body: string @content } goal "g" }|} [ ("body","hello") ] with
  | Ok b -> Alcotest.(check (option string)) "content" (Some "hello") b.Bind.b_content
  | Error _ -> Alcotest.fail "unexpected error"

let test_no_input_block_content_none () =
  match bind {|agent "a" { goal "g" }|} [] with
  | Ok b -> Alcotest.(check (option string)) "legacy" None b.Bind.b_content
  | Error _ -> Alcotest.fail "unexpected error"

let suite =
  ( "bind",
    [ Alcotest.test_case "subst + default" `Quick test_subst_and_default;
      Alcotest.test_case "missing required" `Quick test_missing_required;
      Alcotest.test_case "type mismatch" `Quick test_type_mismatch;
      Alcotest.test_case "unknown --set" `Quick test_unknown_set;
      Alcotest.test_case "content" `Quick test_content;
      Alcotest.test_case "no input block" `Quick test_no_input_block_content_none ] )
```
Register `Test_bind.suite` in `test/test_promptdsl.ml`.

- [ ] **Step 2: Run to verify it fails**

Run: `dune test 2>&1 | head -10`
Expected: `Unbound module Bind`.

- [ ] **Step 3: Implement `bind`**

`lib/bind.ml`:
```ocaml
type bound = {
  b_name : string;
  b_goal : string;
  b_steps : Sema.checked_step list;
  b_output : Sema.checked_output;
  b_content : string option;
}

let typecheck (ty : Ast.ty) (v : string) : (unit, string) result =
  match ty with
  | Ast.TString -> Ok ()
  | Ast.TInt -> (
      match int_of_string_opt v with
      | Some _ -> Ok ()
      | None -> Error (Printf.sprintf "expected an int, got %S" v))
  | Ast.TBool -> (
      match v with "true" | "false" -> Ok () | _ -> Error (Printf.sprintf "expected true or false, got %S" v))
  | Ast.TEnum opts ->
      if List.mem v opts then Ok ()
      else Error (Printf.sprintf "expected one of %s, got %S" (String.concat "/" opts) v)
  | Ast.TList _ -> Error "list inputs are not supported"

let bind (c : Sema.checked) (values : (string * string) list) : (bound, Error.t list) result =
  let errors = ref [] in
  let add ?(loc = Location.dummy) m = errors := Error.make loc m :: !errors in
  let declared = List.map (fun (i : Sema.checked_input) -> i.Sema.ci_name) c.Sema.inputs in
  List.iter
    (fun (k, _) ->
      if not (List.mem k declared) then
        add (Printf.sprintf "unknown input '%s' passed with --set" k))
    values;
  let resolved = Hashtbl.create 8 in
  List.iter
    (fun (i : Sema.checked_input) ->
      let v =
        match List.assoc_opt i.ci_name values with
        | Some v -> Some v
        | None -> i.ci_default
      in
      match v with
      | None ->
          add ~loc:i.ci_loc
            (Printf.sprintf "missing required input '%s' (use --set %s=...)" i.ci_name i.ci_name)
      | Some v -> (
          match typecheck i.ci_ty v with
          | Ok () -> Hashtbl.replace resolved i.ci_name v
          | Error msg -> add ~loc:i.ci_loc (Printf.sprintf "input '%s': %s" i.ci_name msg)))
    c.Sema.inputs;
  match List.rev !errors with
  | _ :: _ as es -> Error es
  | [] ->
      let lookup name = Hashtbl.find_opt resolved name in
      let b_goal = Interp.subst lookup c.Sema.goal in
      let b_steps =
        List.map
          (fun (s : Sema.checked_step) ->
            { s with Sema.arg = Option.map (Interp.subst lookup) s.Sema.arg })
          c.Sema.steps
      in
      let b_content =
        match List.find_opt (fun (i : Sema.checked_input) -> i.ci_content) c.Sema.inputs with
        | Some i -> Hashtbl.find_opt resolved i.ci_name
        | None -> if c.Sema.inputs = [] then None else Some ""
      in
      Ok { b_name = c.Sema.name; b_goal; b_steps; b_output = c.Sema.output; b_content }
```

- [ ] **Step 4: Run to verify it passes**

Run: `dune test 2>&1 | tail -8`
Expected: all six `bind` cases pass.

- [ ] **Step 5: Commit**

```bash
git add lib/bind.ml test/test_bind.ml test/test_promptdsl.ml
git commit -m "feat(input): bind stage resolves values, type-checks, substitutes"
```

---

### Task 5: Wire IR / lower / backends / compile

**Files:** Modify `lib/ir.ml`, `lib/lower.ml`, `lib/backend_openai.ml`, `lib/backend_prose.ml`, `lib/compile.ml`; add `test/test_backends.ml` case.

- [ ] **Step 1: Write the failing test**

Add to `test/test_backends.ml` (and register):
```ocaml
let test_content_to_user_message () =
  match Compile.compile_string ~values:[ ("body", "review this") ]
          {|agent "r" { input { body: string @content } goal "Review the input." }|}
  with
  | Compile.Failure _ -> Alcotest.fail "unexpected failure"
  | Compile.Success o ->
      let open Yojson.Safe.Util in
      let user =
        o.Compile.json |> member "messages" |> to_list |> List.rev |> List.hd
        |> member "content" |> to_string
      in
      Alcotest.(check string) "user message is content" "review this" user

let test_no_input_legacy_user_message () =
  match Compile.compile_string {|agent "r" { goal "g" }|} with
  | Compile.Failure _ -> Alcotest.fail "unexpected failure"
  | Compile.Success o ->
      let open Yojson.Safe.Util in
      let user =
        o.Compile.json |> member "messages" |> to_list |> List.rev |> List.hd
        |> member "content" |> to_string
      in
      Alcotest.(check string) "legacy {{input}}" "{{input}}" user
```
Register both in the backends suite list.

- [ ] **Step 2: Run to verify it fails**

Run: `dune test 2>&1 | head -12`
Expected: `compile_string` has no `~values` label / `Ir.content` unbound.

- [ ] **Step 3: Add `content` to the IR**

In `lib/ir.ml`, change `type t` to add the field:
```ocaml
type t = {
  agent_name : string;
  objective : string;
  instructions : string list;
  out : output;
  content : string option;
}
```

- [ ] **Step 4: Lower from `Bind.bound`**

Replace the `lower` function in `lib/lower.ml` (keep `render_instruction`, `ty_to_ir`, `field_to_ir`, `output_to_ir` unchanged):
```ocaml
let lower (b : Bind.bound) : Ir.t =
  {
    Ir.agent_name = b.Bind.b_name;
    objective = b.Bind.b_goal;
    instructions = List.map render_instruction b.Bind.b_steps;
    out = output_to_ir b.Bind.b_output;
    content = b.Bind.b_content;
  }
```

- [ ] **Step 5: OpenAI backend — user message from content**

In `lib/backend_openai.ml`, add a helper above `render` and use it for the user message:
```ocaml
let user_message (ir : Ir.t) : string =
  match ir.content with None -> "{{input}}" | Some s -> s
```
Then change the user message line inside `render` from
```ocaml
            `Assoc [ ("role", `String "user"); ("content", `String "{{input}}") ] ] ) ]
```
to
```ocaml
            `Assoc [ ("role", `String "user"); ("content", `String (user_message ir)) ] ] ) ]
```

- [ ] **Step 6: Prose backend — show the input**

In `lib/backend_prose.ml`, just before `Buffer.contents b`, add:
```ocaml
  (match ir.content with
   | Some s when s <> "" -> Buffer.add_string b (Printf.sprintf "\n## Input\n%s\n" s)
   | _ -> ());
```

- [ ] **Step 7: Thread values through `compile_string`**

In `lib/compile.ml`, replace `compile_string` with:
```ocaml
let compile_string ?(values = []) (src : string) : outcome =
  match parse_and_check src with
  | Error ds -> Failure ds
  | Ok checked -> (
      match Bind.bind checked values with
      | Error ds -> Failure ds
      | Ok bound ->
          let ir = Lower.lower bound in
          Success { prose = Backend_prose.render ir; json = Backend_openai.render ir })
```

- [ ] **Step 8: Run to verify it passes**

Run: `dune test 2>&1 | tail -6 && ./scripts/check-corpus.sh`
Expected: new backend cases pass; **all prior tests pass**; corpus check still 25/25 (backward compat — no-input agents unchanged).

- [ ] **Step 9: Commit**

```bash
git add lib/ir.ml lib/lower.ml lib/backend_openai.ml lib/backend_prose.ml lib/compile.ml test/test_backends.ml
git commit -m "feat(input): IR.content; backends route content to the user message"
```

---

### Task 6: CLI `--set` + cram

**Files:** Modify `lib/driver.ml`, `bin/main.ml`; add `test/cram/input.t`, `test/cram/researcher.prompt` already exists for backward-compat check.

- [ ] **Step 1: Add `--set` parsing to the driver**

In `lib/driver.ml`, add a parser and thread values into `run_compile`. Add near the top:
```ocaml
let parse_set (s : string) : ((string * string), string) result =
  match String.index_opt s '=' with
  | Some i -> Ok (String.sub s 0 i, String.sub s (i + 1) (String.length s - i - 1))
  | None -> Error (Printf.sprintf "invalid --set %S (expected KEY=VALUE)" s)
```
Change `run_compile` to take the raw `--set` strings and pass parsed values to `compile_string`:
```ocaml
let run_compile (file : string) (emit : [ `Prose | `Json | `Both ]) (sets : string list) : int =
  let rec parse acc = function
    | [] -> Ok (List.rev acc)
    | s :: rest -> (
        match parse_set s with Ok kv -> parse (kv :: acc) rest | Error m -> Error m)
  in
  match parse [] sets with
  | Error m -> prerr_endline m; 2
  | Ok values -> (
      match read_file file with
      | exception Sys_error msg -> prerr_endline msg; 2
      | src -> (
          match Compile.compile_string ~values src with
          | Compile.Failure ds -> print_diags file ds; 1
          | Compile.Success o ->
              (match emit with
               | `Prose -> print_string o.Compile.prose
               | `Json -> print_endline (Yojson.Safe.pretty_to_string o.Compile.json)
               | `Both ->
                   print_endline "=== PROSE ===";
                   print_string o.Compile.prose;
                   print_endline "=== JSON ===";
                   print_endline (Yojson.Safe.pretty_to_string o.Compile.json));
              0))
```

- [ ] **Step 2: Add the `--set` arg to the CLI**

In `bin/main.ml`, add the arg and pass it:
```ocaml
let set_arg =
  let doc = "Bind an input: $(b,--set ticker=TSLA). Repeatable." in
  Arg.(value & opt_all string [] & info [ "set" ] ~docv:"KEY=VALUE" ~doc)
```
Change `compile_cmd`'s term to:
```ocaml
  let term = Term.(const Driver.run_compile $ file_arg $ emit_arg $ set_arg) in
```

- [ ] **Step 3: Build & manual check**

Run:
```bash
dune build 2>&1 | head && \
printf 'agent "x" {\n  input { ticker: string @content }\n  goal "Analyze {{ticker}}."\n}\n' > /tmp/in.prompt && \
dune exec promptc -- compile /tmp/in.prompt --set ticker=TSLA --emit both
```
Expected: prose shows `Goal: Analyze TSLA.` and an `## Input` section with `TSLA`; JSON user message is `TSLA`. Then:
```bash
dune exec promptc -- compile /tmp/in.prompt; echo "exit=$?"
```
Expected: `missing required input 'ticker' (use --set ticker=...)` on stderr, `exit=1`.

- [ ] **Step 4: Add cram tests**

`test/cram/input.t` (commands only; promote output):
```
Inputs are substituted at compile time:

  $ printf 'agent "x" {\n  input { ticker: string  note: string @content }\n  goal "Analyze {{ticker}}."\n}\n' > in.prompt
  $ promptc compile in.prompt --set ticker=TSLA --set note=hello --emit both

Missing a required input is an error:

  $ promptc compile in.prompt --emit prose
  [1]
```

- [ ] **Step 5: Record golden output and verify**

Run: `dune runtest --auto-promote 2>&1 | tail -5 && dune runtest 2>&1; echo "exit=$?"`
Then review `git diff test/cram/input.t`: the `--emit both` prose must contain `Analyze TSLA.` and `## Input` + `hello`; the JSON user message must be `hello`; the missing-input run must show the `missing required input 'ticker'` diagnostic and `[1]`.
Confirm the existing `test/cram/compile.t` and `check.t` are UNCHANGED (backward compat). Re-run `dune runtest` → clean, exit 0.

- [ ] **Step 6: Final full check**

Run: `dune runtest --force 2>&1 | tail -4 && ./scripts/check-corpus.sh`
Expected: all unit + cram pass; corpus check 25/25 unchanged.

- [ ] **Step 7: Commit**

```bash
git add lib/driver.ml bin/main.ml test/cram/input.t
git commit -m "feat(input): promptc compile --set k=v; cram coverage"
```

---

## Self-Review

**Spec coverage:**
- `input {}` block, defaults, `@content` syntax → Task 1.
- `{{name}}` interpolation engine → Task 2; ref-declared validation → Task 3.
- Input validation (dup, >1 content, default rules, @content string, no-list) → Task 3.
- Compile-time substitution + `--set` + type-check + missing/unknown errors → Task 4 (bind) + Task 6 (CLI).
- User-message rules (None→`{{input}}`, content→value, block-no-content→"") → Task 4 (`b_content`) + Task 5 (backends). Verified by `test_no_input_legacy_user_message` + `test_content_to_user_message` + corpus check.
- Backward compatibility → Task 5 Step 8 + Task 6 Step 5 (cram compile.t/check.t unchanged, corpus 25/25).
- `check` does not bind → unchanged `run_check` (Task 6 leaves it alone).

**Placeholder scan:** none — every step has complete code or an exact command + expected output. Cram expected output is generated by `--auto-promote` (standard), with explicit review criteria.

**Type consistency:** `Ast.input_decl` fields `in_*`; `Sema.checked_input` fields `ci_*` (incl. `ci_loc`); `Bind.bound` fields `b_*`; `Ir.t.content : string option`. `compile_string ?values`, `run_compile`'s new `sets` param, `Interp.refs`/`subst`/`tokens`, `Bind.bind`/`typecheck` — names are identical wherever referenced across tasks. The `IInputs of input_decl list node` variant is added in Task 1 and matched in Task 3's `analyze` (exhaustive — required since dune treats warning 8 as error).
