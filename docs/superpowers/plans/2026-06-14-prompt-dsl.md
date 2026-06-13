# promptc — Prompt DSL Compiler Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `promptc`, an OCaml compiler that parses a `.prompt` file, runs a semantic pass, lowers to a provider-agnostic IR, and emits both a human-readable prompt and an OpenAI Chat Completions JSON payload.

**Architecture:** Classic multi-pass compiler — `lexer → parser (Menhir) → sema → lower → IR → {prose, openai} backends`. Each pass is a focused module in the `promptdsl` library; a thin `cmdliner` binary wires the `compile`/`check` subcommands. Tests are alcotest unit suites plus cram golden tests.

**Tech Stack:** OCaml (≥ 4.14), dune, Menhir, ocamllex, yojson, cmdliner, alcotest.

**Spec:** `docs/superpowers/specs/2026-06-14-prompt-dsl-design.md`

---

## Prerequisites

Install the toolchain before Task 1 (one-time):

```bash
opam install dune menhir yojson cmdliner alcotest
```

Verify: `dune --version` prints a 3.x version.

## Key conventions (read once)

- Library is named `promptdsl`; modules are referenced as `Promptdsl.Foo`. Tests `open Promptdsl`.
- **Record field names are globally distinct** (e.g. node uses `v`/`span`, `Ast.field` uses `field_*`, `Ir.t` uses `agent_name`/`out`), so field access never needs disambiguation. Preserve this when editing.
- `Compile.outcome` constructors are `Success`/`Failure` (NOT `Ok`/`Error`) to avoid shadowing `Stdlib.result`.
- Each task ends with a commit. Use the exact `git add` paths shown.

## File map

```
dune-project                 # project config: menhir, cram, package
lib/dune                     # promptdsl library (ocamllex + menhir stanzas)
lib/location.ml              # source positions/spans
lib/error.ml                 # diagnostics (loc + message + hint) + printer
lib/ast.ml                   # raw AST (nodes carry spans)
lib/lexer.mll                # ocamllex tokens
lib/parser.mly               # Menhir grammar -> Ast.agent_block
lib/sema.ml                  # semantic pass: known-action/format checks, dedup -> checked AST
lib/ir.ml                    # provider-agnostic IR
lib/lower.ml                 # checked AST -> IR (verb -> instruction phrasing)
lib/backend_prose.ml         # IR -> human-readable prompt
lib/backend_openai.ml        # IR -> OpenAI request JSON
lib/compile.ml               # pipeline orchestration (parse / parse_and_check / compile_string)
lib/driver.ml                # file IO + stdout/stderr + exit codes
bin/dune                     # promptc executable
bin/main.ml                  # cmdliner CLI
test/dune                    # alcotest runner
test/test_promptdsl.ml       # aggregates suites
test/test_basics.ml          # Location + Error
test/test_parser.ml          # parsing
test/test_sema.ml            # semantic checks
test/test_lower.ml           # lowering
test/test_backends.ml        # prose + openai backends
test/cram/dune               # cram config
test/cram/*.t                # golden tests
test/cram/*.prompt           # cram inputs
examples/researcher.prompt   # user-facing example
README.md
```

---

There are 6 tasks. Each is committed independently and leaves `dune build && dune test` green (Task 1 onward).

---

### Task 1: Project scaffold + Location + Error

**Files:**
- Create: `dune-project`, `lib/dune`, `lib/location.ml`, `lib/error.ml`
- Create: `test/dune`, `test/test_promptdsl.ml`, `test/test_basics.ml`

- [ ] **Step 1: Create project + library config**

`dune-project`:
```
(lang dune 3.7)
(using menhir 2.1)
(cram enable)
(package
 (name promptc)
 (synopsis "A Prompt DSL compiler"))
```

`lib/dune`:
```
(library
 (name promptdsl)
 (public_name promptc.lib)
 (libraries yojson))

(ocamllex lexer)

(menhir
 (modules parser))
```

> Note: `lexer.mll`/`parser.mly` arrive in Task 2. dune will error until then, so build only after Task 2's frontend exists. For Task 1, temporarily comment out the `(ocamllex lexer)` and `(menhir ...)` stanzas, then uncomment in Task 2. (Leave a `; TODO Task 2: enable lexer/menhir` line so it isn't forgotten.)

- [ ] **Step 2: Write the failing test**

`test/test_basics.ml`:
```ocaml
open Promptdsl

let test_location () =
  let s = Lexing.{ pos_fname = ""; pos_lnum = 2; pos_bol = 10; pos_cnum = 12 } in
  let e = Lexing.{ pos_fname = ""; pos_lnum = 2; pos_bol = 10; pos_cnum = 18 } in
  let loc = Location.of_positions s e in
  Alcotest.(check int) "line" 2 loc.Location.start_line;
  Alcotest.(check int) "col" 3 loc.Location.start_col

let test_error_format () =
  let loc = Location.{ start_line = 3; start_col = 5; end_line = 3; end_col = 11 } in
  let d = Error.make ~hint:"did you mean 'search'?" loc "unknown action 'searchh'" in
  Alcotest.(check string) "fmt"
    "f.prompt:3:5: error: unknown action 'searchh' (did you mean 'search'?)"
    (Error.to_string ~filename:"f.prompt" d)

let suite =
  ( "basics",
    [ Alcotest.test_case "location" `Quick test_location;
      Alcotest.test_case "error format" `Quick test_error_format ] )
```

`test/test_promptdsl.ml`:
```ocaml
let () = Alcotest.run "promptdsl" [ Test_basics.suite ]
```

`test/dune`:
```
(test
 (name test_promptdsl)
 (libraries promptdsl alcotest yojson))
```

- [ ] **Step 3: Run test to verify it fails**

Run: `dune test`
Expected: FAIL — `Unbound module Location` / `Unbound module Error` (modules don't exist yet).

- [ ] **Step 4: Implement Location and Error**

`lib/location.ml`:
```ocaml
type t = {
  start_line : int;
  start_col : int;
  end_line : int;
  end_col : int;
}

let dummy = { start_line = 0; start_col = 0; end_line = 0; end_col = 0 }

let of_positions (s : Lexing.position) (e : Lexing.position) : t =
  {
    start_line = s.Lexing.pos_lnum;
    start_col = s.Lexing.pos_cnum - s.Lexing.pos_bol + 1;
    end_line = e.Lexing.pos_lnum;
    end_col = e.Lexing.pos_cnum - e.Lexing.pos_bol + 1;
  }
```

`lib/error.ml`:
```ocaml
type t = { loc : Location.t; message : string; hint : string option }

let make ?hint loc message = { loc; message; hint }

let to_string ~(filename : string) (d : t) : string =
  let base =
    Printf.sprintf "%s:%d:%d: error: %s" filename d.loc.Location.start_line
      d.loc.Location.start_col d.message
  in
  match d.hint with
  | Some h -> base ^ Printf.sprintf " (%s)" h
  | None -> base
```

- [ ] **Step 5: Run test to verify it passes**

Run: `dune test`
Expected: PASS (2 test cases in suite "basics").

- [ ] **Step 6: Commit**

```bash
git init   # repo does not exist yet; run once
git add dune-project lib/dune lib/location.ml lib/error.ml test/dune test/test_promptdsl.ml test/test_basics.ml
git commit -m "feat: project scaffold with Location and Error modules"
```

---

### Task 2: AST + Lexer + Parser + Compile.parse

**Files:**
- Create: `lib/ast.ml`, `lib/lexer.mll`, `lib/parser.mly`, `lib/compile.ml`
- Modify: `lib/dune` (enable the `ocamllex`/`menhir` stanzas from Task 1)
- Create: `examples/researcher.prompt`, `test/test_parser.ml`
- Modify: `test/test_promptdsl.ml`

- [ ] **Step 1: Write the failing test**

`test/test_parser.ml`:
```ocaml
open Promptdsl

let researcher =
  {|
agent "researcher" {
  goal "analyze TSLA"
  step { search "TSLA earnings" }
  step { summarize }
  output json {
    ticker: string
    rating: enum("buy", "hold", "sell")
    summary: string
  }
}
|}

let test_parse_ok () =
  match Compile.parse researcher with
  | Error e -> Alcotest.failf "unexpected parse error: %s" e.Error.message
  | Ok block ->
      Alcotest.(check string) "name" "researcher" block.Ast.block_name;
      Alcotest.(check int) "items" 4 (List.length block.Ast.block_items);
      (match List.nth block.Ast.block_items 0 with
       | Ast.IGoal g -> Alcotest.(check string) "goal" "analyze TSLA" g.Ast.v
       | _ -> Alcotest.fail "expected goal first");
      (match List.nth block.Ast.block_items 3 with
       | Ast.IOutput o ->
           Alcotest.(check string) "fmt" "json" o.Ast.v.Ast.out_format.Ast.v;
           (match o.Ast.v.Ast.out_schema with
            | Some fs -> Alcotest.(check int) "fields" 3 (List.length fs)
            | None -> Alcotest.fail "expected schema")
       | _ -> Alcotest.fail "expected output last")

let test_parse_error () =
  match Compile.parse "agent \"x\" { goal }" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected parse error (goal without string)"

let suite =
  ( "parser",
    [ Alcotest.test_case "parse ok" `Quick test_parse_ok;
      Alcotest.test_case "parse error" `Quick test_parse_error ] )
```

Update `test/test_promptdsl.ml`:
```ocaml
let () = Alcotest.run "promptdsl" [ Test_basics.suite; Test_parser.suite ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dune test`
Expected: FAIL — `Unbound module Compile` / `Unbound module Ast`.

- [ ] **Step 3: Implement the AST**

`lib/ast.ml`:
```ocaml
type 'a node = { v : 'a; span : Location.t }

let node v span = { v; span }

type ty =
  | TString
  | TInt
  | TBool
  | TEnum of string list
  | TList of ty

type field = {
  field_name : string;
  field_ty : ty;
  optional : bool;
  field_loc : Location.t;
}

type action = { action_name : string node; action_arg : string option }

type raw_output = { out_format : string node; out_schema : field list option }

type agent_item =
  | IGoal of string node
  | IStep of action
  | IOutput of raw_output node

type agent_block = {
  block_name : string;
  block_items : agent_item list;
  block_loc : Location.t;
}
```

- [ ] **Step 4: Implement the lexer**

`lib/lexer.mll`:
```ocaml
{
open Parser

exception Error of string * Location.t

let loc_of lexbuf =
  Location.of_positions (Lexing.lexeme_start_p lexbuf) (Lexing.lexeme_end_p lexbuf)

let keywords =
  [ ("agent", AGENT); ("goal", GOAL); ("step", STEP); ("output", OUTPUT);
    ("string", STRING_TY); ("int", INT_TY); ("bool", BOOL_TY);
    ("enum", ENUM); ("list", LIST) ]

let ident_or_keyword s =
  match List.assoc_opt s keywords with Some t -> t | None -> IDENT s

let buf = Buffer.create 64
}

let white = [' ' '\t' '\r']+
let newline = '\n'
let ident = ['a'-'z' 'A'-'Z' '_'] ['a'-'z' 'A'-'Z' '0'-'9' '_']*

rule token = parse
  | white          { token lexbuf }
  | newline        { Lexing.new_line lexbuf; token lexbuf }
  | "//" [^ '\n']* { token lexbuf }
  | '{'            { LBRACE }
  | '}'            { RBRACE }
  | '('            { LPAREN }
  | ')'            { RPAREN }
  | '<'            { LT }
  | '>'            { GT }
  | ','            { COMMA }
  | ':'            { COLON }
  | '?'            { QUESTION }
  | '"'            { Buffer.clear buf; string_lit lexbuf }
  | ident as id    { ident_or_keyword id }
  | eof            { EOF }
  | _ as c         { raise (Error (Printf.sprintf "unexpected character '%c'" c, loc_of lexbuf)) }

and string_lit = parse
  | '"'        { STRING (Buffer.contents buf) }
  | '\\' '"'   { Buffer.add_char buf '"'; string_lit lexbuf }
  | '\\' '\\'  { Buffer.add_char buf '\\'; string_lit lexbuf }
  | '\\' 'n'   { Buffer.add_char buf '\n'; string_lit lexbuf }
  | '\\' 't'   { Buffer.add_char buf '\t'; string_lit lexbuf }
  | newline    { Lexing.new_line lexbuf; Buffer.add_char buf '\n'; string_lit lexbuf }
  | eof        { raise (Error ("unterminated string literal", loc_of lexbuf)) }
  | _ as c     { Buffer.add_char buf c; string_lit lexbuf }
```

- [ ] **Step 5: Implement the parser**

`lib/parser.mly`:
```
%{
open Ast

let mknode v (s, e) = { v; span = Location.of_positions s e }
let mkloc (s, e) = Location.of_positions s e
%}

%token AGENT GOAL STEP OUTPUT
%token STRING_TY INT_TY BOOL_TY ENUM LIST
%token <string> IDENT
%token <string> STRING
%token LBRACE RBRACE LPAREN RPAREN LT GT COMMA COLON QUESTION
%token EOF

%start <Ast.agent_block> program

%%

program:
  | a = agent EOF { a }

agent:
  | AGENT name = STRING LBRACE items = list(item) RBRACE
    { { block_name = name; block_items = items; block_loc = mkloc $loc } }

item:
  | GOAL s = STRING
    { IGoal (mknode s $loc(s)) }
  | STEP LBRACE a = action RBRACE
    { IStep a }
  | OUTPUT f = IDENT s = schema_opt
    { IOutput (mknode { out_format = mknode f $loc(f); out_schema = s } $loc) }

action:
  | name = IDENT arg = action_arg
    { { action_name = mknode name $loc(name); action_arg = arg } }

action_arg:
  | { None }
  | s = STRING { Some s }

schema_opt:
  | { None }
  | LBRACE fs = list(field) RBRACE { Some fs }

field:
  | name = IDENT q = boption(QUESTION) COLON t = ty
    { { field_name = name; field_ty = t; optional = q; field_loc = mkloc $loc } }

ty:
  | STRING_TY { TString }
  | INT_TY    { TInt }
  | BOOL_TY   { TBool }
  | ENUM LPAREN opts = separated_nonempty_list(COMMA, STRING) RPAREN { TEnum opts }
  | LIST LT t = ty GT { TList t }
```

- [ ] **Step 6: Implement Compile.parse and enable dune stanzas**

In `lib/dune`, uncomment the `(ocamllex lexer)` and `(menhir (modules parser))` stanzas.

`lib/compile.ml` (only `parse` for now; the rest is added in later tasks):
```ocaml
let parse (src : string) : (Ast.agent_block, Error.t) result =
  let lexbuf = Lexing.from_string src in
  lexbuf.Lexing.lex_curr_p <-
    { lexbuf.Lexing.lex_curr_p with Lexing.pos_lnum = 1; pos_fname = "" };
  try Ok (Parser.program Lexer.token lexbuf) with
  | Lexer.Error (msg, loc) -> Error (Error.make loc msg)
  | Parser.Error ->
      let loc =
        Location.of_positions (Lexing.lexeme_start_p lexbuf)
          (Lexing.lexeme_end_p lexbuf)
      in
      Error (Error.make loc "syntax error")
```

`examples/researcher.prompt`:
```
agent "researcher" {
  goal "analyze TSLA earnings"

  step { search "TSLA earnings" }
  step { summarize }

  output markdown
}
```

- [ ] **Step 7: Run test to verify it passes**

Run: `dune test`
Expected: PASS (suites "basics" and "parser").

- [ ] **Step 8: Commit**

```bash
git add lib/dune lib/ast.ml lib/lexer.mll lib/parser.mly lib/compile.ml examples/researcher.prompt test/test_parser.ml test/test_promptdsl.ml
git commit -m "feat: lexer, Menhir parser, and AST for the prompt DSL"
```

---

### Task 3: Semantic pass

Validates the raw AST: known actions/formats (with "did you mean" via edit distance), required/duplicate `goal`, duplicate `output`, schema only on `json`, `instruct` requires an arg, duplicate schema fields. Produces a `checked` AST.

**Files:**
- Create: `lib/sema.ml`, `test/test_sema.ml`
- Modify: `lib/compile.ml` (add `parse_and_check`), `test/test_promptdsl.ml`

- [ ] **Step 1: Write the failing test for the edit-distance helpers**

`test/test_sema.ml`:
```ocaml
open Promptdsl

let msgs ds = String.concat "; " (List.map (fun (d : Error.t) -> d.Error.message) ds)

let analyze src =
  match Compile.parse src with
  | Error e -> Alcotest.failf "parse error: %s" e.Error.message
  | Ok b -> Sema.analyze b

let ok_or_fail src =
  match analyze src with
  | Ok c -> c
  | Error ds -> Alcotest.failf "unexpected errors: %s" (msgs ds)

let err_or_fail src =
  match analyze src with
  | Error ds -> ds
  | Ok _ -> Alcotest.fail "expected an error"

let test_levenshtein () =
  Alcotest.(check int) "off-by-one" 1 (Sema.levenshtein "search" "serch");
  Alcotest.(check int) "equal" 0 (Sema.levenshtein "abc" "abc")

let test_closest () =
  Alcotest.(check (option string)) "near" (Some "search")
    (Sema.closest "serch" Sema.known_actions);
  Alcotest.(check (option string)) "far" None
    (Sema.closest "zzzzzzz" Sema.known_actions)

let test_valid () =
  let c = ok_or_fail {|agent "a" { goal "g" step { summarize } }|} in
  Alcotest.(check string) "goal" "g" c.Sema.goal;
  Alcotest.(check int) "steps" 1 (List.length c.Sema.steps)

let test_unknown_action () =
  let ds = err_or_fail {|agent "a" { goal "g" step { searchh "x" } }|} in
  let d = List.hd ds in
  Alcotest.(check string) "msg" "unknown action 'searchh'" d.Error.message;
  Alcotest.(check (option string)) "hint" (Some "did you mean 'search'?") d.Error.hint

let test_missing_goal () =
  let ds = err_or_fail {|agent "a" { step { summarize } }|} in
  Alcotest.(check bool) "missing goal" true
    (List.exists (fun (d : Error.t) -> d.Error.message = "missing required 'goal'") ds)

let test_instruct_no_arg () =
  let ds = err_or_fail {|agent "a" { goal "g" step { instruct } }|} in
  Alcotest.(check string) "msg" "'instruct' requires a string argument"
    (List.hd ds).Error.message

let test_dup_field () =
  let ds = err_or_fail {|agent "a" { goal "g" output json { x: string x: int } }|} in
  Alcotest.(check bool) "dup field" true
    (List.exists (fun (d : Error.t) -> d.Error.message = "duplicate field 'x'") ds)

let test_schema_on_text () =
  let ds = err_or_fail {|agent "a" { goal "g" output text { x: string } }|} in
  Alcotest.(check bool) "schema-on-text" true
    (List.exists
       (fun (d : Error.t) -> d.Error.message = "'text' output does not take a schema")
       ds)

let suite =
  ( "sema",
    [ Alcotest.test_case "levenshtein" `Quick test_levenshtein;
      Alcotest.test_case "closest" `Quick test_closest;
      Alcotest.test_case "valid" `Quick test_valid;
      Alcotest.test_case "unknown action" `Quick test_unknown_action;
      Alcotest.test_case "missing goal" `Quick test_missing_goal;
      Alcotest.test_case "instruct no arg" `Quick test_instruct_no_arg;
      Alcotest.test_case "dup field" `Quick test_dup_field;
      Alcotest.test_case "schema on text" `Quick test_schema_on_text ] )
```

Update `test/test_promptdsl.ml`:
```ocaml
let () =
  Alcotest.run "promptdsl"
    [ Test_basics.suite; Test_parser.suite; Test_sema.suite ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dune test`
Expected: FAIL — `Unbound module Sema`.

- [ ] **Step 3: Implement Sema**

`lib/sema.ml`:
```ocaml
open Ast

type checked_step = { verb : string; arg : string option }

type checked_output =
  | COText
  | COMarkdown
  | COJson of Ast.field list option

type checked = {
  name : string;
  goal : string;
  steps : checked_step list;
  output : checked_output;
}

let known_actions =
  [ "search"; "summarize"; "extract"; "translate"; "classify"; "instruct" ]

let known_formats = [ "text"; "markdown"; "json" ]

let levenshtein a b =
  let la = String.length a and lb = String.length b in
  let d = Array.make_matrix (la + 1) (lb + 1) 0 in
  for i = 0 to la do d.(i).(0) <- i done;
  for j = 0 to lb do d.(0).(j) <- j done;
  for i = 1 to la do
    for j = 1 to lb do
      let cost = if a.[i - 1] = b.[j - 1] then 0 else 1 in
      d.(i).(j) <-
        min
          (min (d.(i - 1).(j) + 1) (d.(i).(j - 1) + 1))
          (d.(i - 1).(j - 1) + cost)
    done
  done;
  d.(la).(lb)

let closest target candidates =
  let scored = List.map (fun c -> (c, levenshtein target c)) candidates in
  match List.sort (fun (_, x) (_, y) -> compare x y) scored with
  | (c, dist) :: _ when dist <= 2 -> Some c
  | _ -> None

let hint_for target candidates =
  match closest target candidates with
  | Some s -> Some (Printf.sprintf "did you mean '%s'?" s)
  | None -> None

let analyze (block : Ast.agent_block) : (checked, Error.t list) result =
  let errors = ref [] in
  let add e = errors := e :: !errors in
  let goal = ref None and steps = ref [] and output = ref None in
  let check_dup_fields fields =
    let seen = Hashtbl.create 8 in
    List.iter
      (fun (f : Ast.field) ->
        if Hashtbl.mem seen f.field_name then
          add
            (Error.make f.field_loc
               (Printf.sprintf "duplicate field '%s'" f.field_name))
        else Hashtbl.add seen f.field_name ())
      fields
  in
  List.iter
    (fun item ->
      match item with
      | IGoal g -> (
          match !goal with
          | None -> goal := Some g.v
          | Some _ -> add (Error.make g.span "duplicate 'goal'"))
      | IStep a ->
          let name = a.action_name.v in
          if not (List.mem name known_actions) then
            add
              (Error.make ?hint:(hint_for name known_actions) a.action_name.span
                 (Printf.sprintf "unknown action '%s'" name))
          else if name = "instruct" && a.action_arg = None then
            add
              (Error.make a.action_name.span
                 "'instruct' requires a string argument")
          else steps := { verb = name; arg = a.action_arg } :: !steps
      | IOutput o -> (
          match !output with
          | Some _ -> add (Error.make o.span "duplicate 'output'")
          | None -> (
              let ro = o.v in
              match ro.out_format.v with
              | "text" -> (
                  match ro.out_schema with
                  | Some _ ->
                      add (Error.make o.span "'text' output does not take a schema")
                  | None -> output := Some COText)
              | "markdown" -> (
                  match ro.out_schema with
                  | Some _ ->
                      add
                        (Error.make o.span
                           "'markdown' output does not take a schema")
                  | None -> output := Some COMarkdown)
              | "json" -> (
                  match ro.out_schema with
                  | None -> output := Some (COJson None)
                  | Some fields ->
                      check_dup_fields fields;
                      output := Some (COJson (Some fields)))
              | other ->
                  add
                    (Error.make ?hint:(hint_for other known_formats)
                       ro.out_format.span
                       (Printf.sprintf "unknown output format '%s'" other)))))
    block.block_items;
  let goal_val =
    match !goal with
    | Some g -> Some g
    | None ->
        add (Error.make block.block_loc "missing required 'goal'");
        None
  in
  match List.rev !errors with
  | [] ->
      Ok
        {
          name = block.block_name;
          goal = Option.get goal_val;
          steps = List.rev !steps;
          output = Option.value !output ~default:COText;
        }
  | es -> Error es
```

- [ ] **Step 4: Add `parse_and_check` to Compile**

Append to `lib/compile.ml`:
```ocaml
let parse_and_check (src : string) : (Sema.checked, Error.t list) result =
  match parse src with
  | Error e -> Error [ e ]
  | Ok block -> Sema.analyze block
```

- [ ] **Step 5: Run test to verify it passes**

Run: `dune test`
Expected: PASS (suites basics, parser, sema).

- [ ] **Step 6: Commit**

```bash
git add lib/sema.ml lib/compile.ml test/test_sema.ml test/test_promptdsl.ml
git commit -m "feat: semantic analysis pass with edit-distance diagnostics"
```

---

### Task 4: IR + lowering

The provider-agnostic IR and the lowering that turns each checked step into a normalized instruction string (shared by both backends, keeping prose and JSON consistent).

**Files:**
- Create: `lib/ir.ml`, `lib/lower.ml`, `test/test_lower.ml`
- Modify: `test/test_promptdsl.ml`

- [ ] **Step 1: Write the failing test**

`test/test_lower.ml`:
```ocaml
open Promptdsl

let test_lower () =
  let checked =
    {
      Sema.name = "researcher";
      goal = "analyze TSLA";
      steps =
        [ { Sema.verb = "search"; arg = Some "TSLA earnings" };
          { Sema.verb = "summarize"; arg = None } ];
      output =
        Sema.COJson
          (Some
             [ { Ast.field_name = "ticker"; field_ty = Ast.TString;
                 optional = false; field_loc = Location.dummy } ]);
    }
  in
  let ir = Lower.lower checked in
  Alcotest.(check string) "agent" "researcher" ir.Ir.agent_name;
  Alcotest.(check string) "objective" "analyze TSLA" ir.Ir.objective;
  Alcotest.(check (list string)) "instructions"
    [ "Search for: TSLA earnings"; "Summarize the findings" ]
    ir.Ir.instructions;
  match ir.Ir.out with
  | Ir.OJson (Some [ f ]) ->
      Alcotest.(check string) "field name" "ticker" f.Ir.fname;
      Alcotest.(check bool) "required" true f.Ir.required
  | _ -> Alcotest.fail "expected json schema with one field"

let suite = ("lower", [ Alcotest.test_case "lower" `Quick test_lower ])
```

Update `test/test_promptdsl.ml`:
```ocaml
let () =
  Alcotest.run "promptdsl"
    [ Test_basics.suite; Test_parser.suite; Test_sema.suite; Test_lower.suite ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dune test`
Expected: FAIL — `Unbound module Ir` / `Unbound module Lower`.

- [ ] **Step 3: Implement the IR**

`lib/ir.ml`:
```ocaml
type schema_ty =
  | SString
  | SInt
  | SBool
  | SEnum of string list
  | SList of schema_ty

type schema_field = { fname : string; fty : schema_ty; required : bool }

type output =
  | OText
  | OMarkdown
  | OJson of schema_field list option

type t = {
  agent_name : string;
  objective : string;
  instructions : string list;
  out : output;
}
```

- [ ] **Step 4: Implement lowering**

`lib/lower.ml`:
```ocaml
let render_instruction (s : Sema.checked_step) : string =
  match (s.Sema.verb, s.Sema.arg) with
  | "search", Some a -> "Search for: " ^ a
  | "search", None -> "Search for relevant information"
  | "summarize", Some a -> "Summarize: " ^ a
  | "summarize", None -> "Summarize the findings"
  | "extract", Some a -> "Extract: " ^ a
  | "extract", None -> "Extract the key information"
  | "translate", Some a -> "Translate the result into: " ^ a
  | "translate", None -> "Translate the result"
  | "classify", Some a -> "Classify: " ^ a
  | "classify", None -> "Classify the result"
  | "instruct", Some a -> a
  | _, Some a -> s.Sema.verb ^ ": " ^ a
  | verb, None -> verb

let rec ty_to_ir (t : Ast.ty) : Ir.schema_ty =
  match t with
  | Ast.TString -> Ir.SString
  | Ast.TInt -> Ir.SInt
  | Ast.TBool -> Ir.SBool
  | Ast.TEnum opts -> Ir.SEnum opts
  | Ast.TList t -> Ir.SList (ty_to_ir t)

let field_to_ir (f : Ast.field) : Ir.schema_field =
  { Ir.fname = f.Ast.field_name; fty = ty_to_ir f.Ast.field_ty;
    required = not f.Ast.optional }

let output_to_ir (o : Sema.checked_output) : Ir.output =
  match o with
  | Sema.COText -> Ir.OText
  | Sema.COMarkdown -> Ir.OMarkdown
  | Sema.COJson None -> Ir.OJson None
  | Sema.COJson (Some fields) -> Ir.OJson (Some (List.map field_to_ir fields))

let lower (c : Sema.checked) : Ir.t =
  {
    Ir.agent_name = c.Sema.name;
    objective = c.Sema.goal;
    instructions = List.map render_instruction c.Sema.steps;
    out = output_to_ir c.Sema.output;
  }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `dune test`
Expected: PASS (4 suites).

- [ ] **Step 6: Commit**

```bash
git add lib/ir.ml lib/lower.ml test/test_lower.ml test/test_promptdsl.ml
git commit -m "feat: provider-agnostic IR and lowering"
```

---

### Task 5: Backends + `compile_string`

Prose backend renders a readable prompt; OpenAI backend reuses the prose text as the system message and adds `response_format`. `compile_string` wires the full pipeline into the `Success`/`Failure` outcome.

**Files:**
- Create: `lib/backend_prose.ml`, `lib/backend_openai.ml`, `test/test_backends.ml`
- Modify: `lib/compile.ml` (add `outputs`, `outcome`, `compile_string`), `test/test_promptdsl.ml`

- [ ] **Step 1: Write the failing test**

`test/test_backends.ml`:
```ocaml
open Promptdsl

let sample_ir =
  {
    Ir.agent_name = "researcher";
    objective = "analyze TSLA";
    instructions = [ "Search for: TSLA earnings"; "Summarize the findings" ];
    out =
      Ir.OJson
        (Some
           [ { Ir.fname = "rating"; fty = Ir.SEnum [ "buy"; "hold"; "sell" ];
               required = true };
             { Ir.fname = "note"; fty = Ir.SString; required = false } ]);
  }

let contains s sub =
  let ls = String.length s and lsub = String.length sub in
  let rec go i =
    if i + lsub > ls then false
    else if String.sub s i lsub = sub then true
    else go (i + 1)
  in
  go 0

let test_prose () =
  let s = Backend_prose.render sample_ir in
  Alcotest.(check bool) "goal" true (contains s "Goal: analyze TSLA");
  Alcotest.(check bool) "step 1" true (contains s "1. Search for: TSLA earnings");
  Alcotest.(check bool) "step 2" true (contains s "2. Summarize the findings")

let test_openai () =
  let open Yojson.Safe.Util in
  let j = Backend_openai.render sample_ir in
  Alcotest.(check string) "model" "gpt-4o-mini"
    (j |> member "model" |> to_string);
  let rf = j |> member "response_format" in
  Alcotest.(check string) "rf type" "json_schema" (rf |> member "type" |> to_string);
  let required =
    rf |> member "json_schema" |> member "schema" |> member "required"
    |> to_list |> List.map to_string
  in
  Alcotest.(check (list string)) "required" [ "rating" ] required

let suite =
  ( "backends",
    [ Alcotest.test_case "prose" `Quick test_prose;
      Alcotest.test_case "openai" `Quick test_openai ] )
```

Update `test/test_promptdsl.ml`:
```ocaml
let () =
  Alcotest.run "promptdsl"
    [ Test_basics.suite; Test_parser.suite; Test_sema.suite;
      Test_lower.suite; Test_backends.suite ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dune test`
Expected: FAIL — `Unbound module Backend_prose` / `Backend_openai`.

- [ ] **Step 3: Implement the prose backend**

`lib/backend_prose.ml`:
```ocaml
open Ir

let rec render_ty = function
  | SString -> "string"
  | SInt -> "int"
  | SBool -> "bool"
  | SEnum opts -> "enum(" ^ String.concat ", " opts ^ ")"
  | SList t -> "list<" ^ render_ty t ^ ">"

let render (ir : Ir.t) : string =
  let b = Buffer.create 256 in
  Buffer.add_string b (Printf.sprintf "You are \"%s\".\n" ir.agent_name);
  Buffer.add_string b (Printf.sprintf "Goal: %s\n" ir.objective);
  if ir.instructions <> [] then begin
    Buffer.add_string b "\nSteps:\n";
    List.iteri
      (fun i instr -> Buffer.add_string b (Printf.sprintf "%d. %s\n" (i + 1) instr))
      ir.instructions
  end;
  (match ir.out with
   | OText -> ()
   | OMarkdown -> Buffer.add_string b "\nFormat your answer as Markdown.\n"
   | OJson None -> Buffer.add_string b "\nReturn your answer as JSON.\n"
   | OJson (Some fields) ->
       Buffer.add_string b "\nReturn ONLY JSON matching this schema:\n";
       List.iter
         (fun f ->
           Buffer.add_string b
             (Printf.sprintf "  %s%s: %s\n" f.fname
                (if f.required then "" else "?")
                (render_ty f.fty)))
         fields);
  Buffer.contents b
```

- [ ] **Step 4: Implement the OpenAI backend**

`lib/backend_openai.ml`:
```ocaml
open Ir

let rec json_of_ty = function
  | SString -> `Assoc [ ("type", `String "string") ]
  | SInt -> `Assoc [ ("type", `String "integer") ]
  | SBool -> `Assoc [ ("type", `String "boolean") ]
  | SEnum opts ->
      `Assoc
        [ ("type", `String "string");
          ("enum", `List (List.map (fun s -> `String s) opts)) ]
  | SList t -> `Assoc [ ("type", `String "array"); ("items", json_of_ty t) ]

let response_format fields =
  let props = List.map (fun f -> (f.fname, json_of_ty f.fty)) fields in
  let required =
    List.filter_map
      (fun f -> if f.required then Some (`String f.fname) else None)
      fields
  in
  `Assoc
    [ ("type", `String "json_schema");
      ( "json_schema",
        `Assoc
          [ ("name", `String "output");
            ( "schema",
              `Assoc
                [ ("type", `String "object");
                  ("properties", `Assoc props);
                  ("required", `List required);
                  ("additionalProperties", `Bool false) ] ) ] ) ]

let render (ir : Ir.t) : Yojson.Safe.t =
  let base =
    [ ("model", `String "gpt-4o-mini");
      ( "messages",
        `List
          [ `Assoc
              [ ("role", `String "system");
                ("content", `String (Backend_prose.render ir)) ];
            `Assoc
              [ ("role", `String "user"); ("content", `String "{{input}}") ] ] ) ]
  in
  let fields =
    match ir.out with
    | OJson (Some fields) -> base @ [ ("response_format", response_format fields) ]
    | OJson None ->
        base @ [ ("response_format", `Assoc [ ("type", `String "json_object") ]) ]
    | OText | OMarkdown -> base
  in
  `Assoc fields
```

- [ ] **Step 5: Add `compile_string` to Compile**

Append to `lib/compile.ml`:
```ocaml
type outputs = { prose : string; json : Yojson.Safe.t }
type outcome = Success of outputs | Failure of Error.t list

let compile_string (src : string) : outcome =
  match parse_and_check src with
  | Error ds -> Failure ds
  | Ok checked ->
      let ir = Lower.lower checked in
      Success { prose = Backend_prose.render ir; json = Backend_openai.render ir }
```

- [ ] **Step 6: Run test to verify it passes**

Run: `dune test`
Expected: PASS (5 suites).

- [ ] **Step 7: Commit**

```bash
git add lib/backend_prose.ml lib/backend_openai.ml lib/compile.ml test/test_backends.ml test/test_promptdsl.ml
git commit -m "feat: prose and OpenAI backends; full compile pipeline"
```

---

### Task 6: Driver, CLI, cram tests, README

Wires the pipeline to files/stdout/exit codes, builds the `promptc` binary with `cmdliner`, and adds cram golden tests that exercise the real binary end to end.

**Files:**
- Create: `lib/driver.ml`, `bin/dune`, `bin/main.ml`
- Create: `test/cram/dune`, `test/cram/researcher.prompt`, `test/cram/bad.prompt`, `test/cram/compile.t`, `test/cram/check.t`
- Create: `README.md`

- [ ] **Step 1: Implement the driver (in lib, so it is unit-testable)**

`lib/driver.ml`:
```ocaml
let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let print_diags filename ds =
  List.iter (fun d -> prerr_endline (Error.to_string ~filename d)) ds

let run_check (file : string) : int =
  match read_file file with
  | exception Sys_error msg ->
      prerr_endline msg;
      2
  | src -> (
      match Compile.parse_and_check src with
      | Ok _ ->
          print_endline "OK";
          0
      | Error ds ->
          print_diags file ds;
          1)

let run_compile (file : string) (emit : [ `Prose | `Json | `Both ]) : int =
  match read_file file with
  | exception Sys_error msg ->
      prerr_endline msg;
      2
  | src -> (
      match Compile.compile_string src with
      | Compile.Failure ds ->
          print_diags file ds;
          1
      | Compile.Success o ->
          (match emit with
           | `Prose -> print_string o.Compile.prose
           | `Json -> print_endline (Yojson.Safe.pretty_to_string o.Compile.json)
           | `Both ->
               print_endline "=== PROSE ===";
               print_string o.Compile.prose;
               print_endline "=== JSON ===";
               print_endline (Yojson.Safe.pretty_to_string o.Compile.json));
          0)
```

- [ ] **Step 2: Implement the CLI binary**

`bin/dune`:
```
(executable
 (name main)
 (public_name promptc)
 (package promptc)
 (libraries promptdsl cmdliner))
```

`bin/main.ml`:
```ocaml
open Cmdliner
open Promptdsl

let emit_conv = Arg.enum [ ("prose", `Prose); ("json", `Json); ("both", `Both) ]

let file_arg =
  let doc = "The .prompt source file." in
  Arg.(required & pos 0 (some string) None & info [] ~docv:"FILE" ~doc)

let emit_arg =
  let doc = "What to emit: prose, json, or both." in
  Arg.(value & opt emit_conv `Prose & info [ "emit" ] ~docv:"WHAT" ~doc)

let compile_cmd =
  let doc = "Compile a .prompt file to a prompt and/or an OpenAI request." in
  let term = Term.(const Driver.run_compile $ file_arg $ emit_arg) in
  Cmd.v (Cmd.info "compile" ~doc) term

let check_cmd =
  let doc = "Parse and check a .prompt file, reporting diagnostics." in
  let term = Term.(const Driver.run_check $ file_arg) in
  Cmd.v (Cmd.info "check" ~doc) term

let () =
  let doc = "A Prompt DSL compiler." in
  let info = Cmd.info "promptc" ~version:"0.1.0" ~doc in
  exit (Cmd.eval' (Cmd.group info [ compile_cmd; check_cmd ]))
```

- [ ] **Step 3: Verify the binary builds and runs manually**

Run: `dune build && dune exec promptc -- compile examples/researcher.prompt --emit prose`
Expected output:
```
You are "researcher".
Goal: analyze TSLA earnings

Steps:
1. Search for: TSLA earnings
2. Summarize the findings

Format your answer as Markdown.
```

Also run `dune exec promptc -- check examples/researcher.prompt` → prints `OK`, exit 0.

- [ ] **Step 4: Add cram inputs and test files (commands only)**

`test/cram/dune`:
```
(cram
 (deps %{bin:promptc} (glob_files *.prompt)))
```

`test/cram/researcher.prompt`:
```
agent "researcher" {
  goal "analyze TSLA earnings"

  step { search "TSLA earnings" }
  step { summarize }

  output json {
    ticker:  string
    rating:  enum("buy", "hold", "sell")
    summary: string
  }
}
```

`test/cram/bad.prompt`:
```
agent "researcher" {
  step { searchh "TSLA earnings" }
}
```

`test/cram/compile.t` (write the commands; expected output is filled by promotion in Step 5):
```
Compile to prose:

  $ promptc compile researcher.prompt --emit prose

Compile to OpenAI JSON:

  $ promptc compile researcher.prompt --emit json
```

`test/cram/check.t`:
```
Unknown action and missing goal are reported:

  $ promptc check bad.prompt
  [1]
```

> The `[1]` line asserts exit code 1. The diagnostic lines above it are filled by promotion.

- [ ] **Step 5: Record golden output, then verify**

Run: `dune runtest --auto-promote`
This populates the expected output blocks in the `.t` files from the real binary.

Then review with `git diff test/cram` and sanity-check:
- `compile.t` prose block matches the Step 3 output.
- `compile.t` json block is a JSON object with `"model"`, `"messages"`, and a `"response_format"` containing `"json_schema"`.
- `check.t` shows two diagnostics — `researcher.prompt:...: error: unknown action 'searchh' (did you mean 'search'?)` and `... error: missing required 'goal'` — followed by `[1]`. (Filename in the message is `bad.prompt`.)

Run again to confirm determinism: `dune runtest`
Expected: PASS, no diff.

- [ ] **Step 6: Write the README**

`README.md`:
```markdown
# promptc

A Prompt DSL compiler. Write a structured `.prompt` file describing an agent's
goal and steps, and compile it to a human-readable prompt and an OpenAI Chat
Completions request.

## Build

    opam install dune menhir yojson cmdliner alcotest
    dune build

## Usage

    dune exec promptc -- compile examples/researcher.prompt --emit prose
    dune exec promptc -- compile examples/researcher.prompt --emit json
    dune exec promptc -- compile examples/researcher.prompt --emit both
    dune exec promptc -- check examples/researcher.prompt

## Language

    agent "researcher" {
      goal "analyze TSLA earnings"

      step { search "TSLA earnings" }
      step { summarize }

      output json {
        ticker:  string
        rating:  enum("buy", "hold", "sell")
        summary: string
      }
    }

- Actions: `search`, `summarize`, `extract`, `translate`, `classify`, `instruct "..."`.
- Output: `text` | `markdown` | `json` (with an optional typed schema).
- Field types: `string`, `int`, `bool`, `enum(...)`, `list<T>`; suffix `?` marks a field optional.

## Tests

    dune test
```

- [ ] **Step 7: Run the full test suite**

Run: `dune test`
Expected: PASS — all alcotest suites and both cram tests.

- [ ] **Step 8: Commit**

```bash
git add lib/driver.ml bin/dune bin/main.ml test/cram README.md
git commit -m "feat: promptc CLI with compile/check, cram golden tests, README"
```

---

## Self-Review

**Spec coverage:**
- Language surface (`agent`/`goal`/`step`/`output` + typed schema) → Tasks 2–3.
- Pipeline lexer → parser → sema → lower → prose+OpenAI backends → Tasks 2–5.
- `promptc compile`/`check` with `--emit prose|json|both` → Task 6.
- Diagnostics with spans + "did you mean" → Tasks 1, 3.
- Both prose + JSON output via IR/two backends → Tasks 4–5.
- Tests: alcotest unit suites (Tasks 1–5) + cram golden corpus, happy + error path (Task 6).
- Example corpus + README → Task 6.
- Out-of-scope respected: no execution, OpenAI-only, no full type system. ✓

**Placeholder scan:** No `TODO`/`TBD` in source. The one deliberately-recorded value is the cram `.t` expected output, which is generated by `dune runtest --auto-promote` (the standard cram workflow), with explicit review criteria in Task 6 Step 5 — not an unfilled placeholder.

**Type consistency (verified across tasks):**
- AST `node` fields `v`/`span`; `Ast.field` fields `field_name`/`field_ty`/`optional`/`field_loc`; `raw_output` fields `out_format`/`out_schema`.
- `Sema.checked` fields `name`/`goal`/`steps`/`output`; `checked_step` fields `verb`/`arg`; `checked_output` = `COText|COMarkdown|COJson`.
- `Ir.t` fields `agent_name`/`objective`/`instructions`/`out`; `schema_field` fields `fname`/`fty`/`required`; `output` = `OText|OMarkdown|OJson`.
- `Compile.outcome` = `Success|Failure` (avoids shadowing `Stdlib.result`); `outputs` fields `prose`/`json`.
- CLI emit variants `` `Prose|`Json|`Both `` match `Driver.run_compile`.
All field names are globally distinct, so record access needs no disambiguation.

## End-to-end verification

After Task 6:

```bash
dune build
dune test                                                   # all suites + cram pass
dune exec promptc -- compile examples/researcher.prompt --emit both
dune exec promptc -- check examples/researcher.prompt       # prints OK, exit 0
echo 'agent "x" { step { summarize } }' > /tmp/bad.prompt
dune exec promptc -- check /tmp/bad.prompt; echo "exit=$?"   # missing-goal error, exit=1
```

