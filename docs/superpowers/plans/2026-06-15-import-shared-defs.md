# import + Shared Text Fragments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a minimal cross-file module system — `def name = "..."` in lib files, `import "path" as alias` in agent files, and `{{alias.name}}` references substituted at compile time alongside inputs.

**Architecture:** A new `resolve` stage between parse and sema loads imported lib files (via an injected loader), parses them with a second Menhir start symbol (`library`), and collects `alias.name -> text` fragments. Sema validates fragment references; bind substitutes them. Agents with no `import` are unchanged.

**Tech Stack:** OCaml, dune, Menhir (two `%start` symbols), ocamllex, yojson, cmdliner, alcotest.

**Spec:** `docs/superpowers/specs/2026-06-15-import-shared-defs-design.md`

---

## Conventions

- `dune test` for unit suites; `./scripts/check-corpus.sh` must stay 25/25 (backward compat).
- Commit on a feature branch (executor sets up). Trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- Distinct field names: `def_decl` uses `def_*`, `import_decl` uses `imp_*`, `agent_file` uses `af_*`.

## Type vocabulary (keep identical across tasks)

```
Ast.def_decl    = { def_name:string; def_text:string; def_loc:Location.t }
Ast.import_decl = { imp_path:string; imp_alias:string; imp_loc:Location.t }
Ast.agent_file  = { af_imports:import_decl list; af_agent:agent_block }
Resolve.lookup_result = Found of string | NoAlias | NoDef
Resolve.fragments = (string * (string*string) list) list   (* alias -> [(name,text)] *)
Resolve.find   : fragments -> string -> string -> lookup_result
Resolve.lookup : fragments -> string -> string -> string option
Resolve.resolve : parse_lib:(string -> (Ast.def_decl list, Error.t) result)
               -> resolver:(string -> (string, string) result)
               -> Ast.import_decl list -> (fragments, Error.t list) result
Compile.parse         : string -> (Ast.agent_file, Error.t) result   (* WAS agent_block *)
Compile.parse_library : string -> (Ast.def_decl list, Error.t) result
Sema.analyze   : ?fragments:Resolve.fragments -> Ast.agent_block -> (checked, Error.t list) result
Bind.bind      : ?fragments:Resolve.fragments -> Sema.checked -> (string*string) list -> (bound, Error.t list) result
```

## Reference rule (sema + bind share it)

A `{{x}}` whose name contains `.` is a fragment ref: split on the first `.` into `(alias, name)`. Otherwise it's an input (bare name). `Interp` is unchanged.

## File map

```
lib/ast.ml        + def_decl, import_decl, agent_file
lib/lexer.mll     + `import`, `as`, `def` keywords (EQ token already exists)
lib/parser.mly    + %start library; import_decl/def_decl rules; program now `import* agent`
lib/resolve.ml    NEW: load + parse libs, collect fragments, validate import errors
lib/sema.ml       extend {{ref}} check: dotted -> fragment via Resolve.find; ?fragments
lib/bind.ml       fragment substitution in the {{x}} lookup; ?fragments
lib/compile.ml    run_parser helper; parse -> agent_file; parse_library; frontend = parse->resolve->sema; resolver threading
lib/driver.ml     filesystem resolver rooted at the main file's dir; thread into compile/check
test/*            new alcotest + cram coverage
```

---

### Task 1: AST + two-grammar parser (`import* agent` and lib `def*`)

**Files:** Modify `lib/ast.ml`, `lib/lexer.mll`, `lib/parser.mly`, `lib/compile.ml`, `test/test_parser.ml`, `test/test_sema.ml`.

- [ ] **Step 1: Write the failing tests**

Add to `test/test_parser.ml` (before `let suite`) and register:
```ocaml
let test_parse_import_and_agent () =
  let src =
    {|import "finance.prompt" as fin
      agent "a" { goal "g {{fin.disclaimer}}" }|}
  in
  match Compile.parse src with
  | Error e -> Alcotest.failf "unexpected parse error: %s" e.Error.message
  | Ok af -> (
      Alcotest.(check string) "agent name" "a" af.Ast.af_agent.Ast.block_name;
      match af.Ast.af_imports with
      | [ i ] ->
          Alcotest.(check string) "path" "finance.prompt" i.Ast.imp_path;
          Alcotest.(check string) "alias" "fin" i.Ast.imp_alias
      | _ -> Alcotest.fail "expected one import")

let test_parse_library () =
  match Compile.parse_library {|def disclaimer = "x"  def rubric = "y"|} with
  | Error e -> Alcotest.failf "unexpected: %s" e.Error.message
  | Ok [ a; b ] ->
      Alcotest.(check string) "1 name" "disclaimer" a.Ast.def_name;
      Alcotest.(check string) "1 text" "x" a.Ast.def_text;
      Alcotest.(check string) "2 name" "rubric" b.Ast.def_name
  | Ok _ -> Alcotest.fail "expected two defs"
```
Register: `Alcotest.test_case "import+agent" `Quick test_parse_import_and_agent;` and `Alcotest.test_case "library" `Quick test_parse_library;`.

- [ ] **Step 2: Run to verify it fails**

`dune test 2>&1 | head -20` → expect `Compile.parse_library` unbound / `af_agent` unbound.

- [ ] **Step 3: Extend the AST**

In `lib/ast.ml`, add (e.g. after `agent_block`):
```ocaml
type def_decl = { def_name : string; def_text : string; def_loc : Location.t }
type import_decl = { imp_path : string; imp_alias : string; imp_loc : Location.t }
type agent_file = { af_imports : import_decl list; af_agent : agent_block }
```

- [ ] **Step 4: Extend the lexer**

In `lib/lexer.mll`, add to the `keywords` list: `("import", IMPORT); ("as", AS); ("def", DEF);`. (The `EQ` token already exists.)

- [ ] **Step 5: Extend the parser (two start symbols)**

In `lib/parser.mly`:
- Add tokens: `%token IMPORT AS DEF`.
- Add a second start declaration next to the existing one:
```
%start <Ast.agent_file> program
%start <Ast.def_decl list> library
```
(Remove the old `%start <Ast.agent_block> program` line — `program` now returns `agent_file`.)
- Replace the `program` rule and add the new rules:
```
program:
  | imports = list(import_decl) a = agent EOF
    { { af_imports = imports; af_agent = a } }

library:
  | defs = list(def_decl) EOF { defs }

import_decl:
  | IMPORT p = STRING AS a = IDENT
    { { imp_path = p; imp_alias = a; imp_loc = mkloc $loc } }

def_decl:
  | DEF name = IDENT EQ text = STRING
    { { def_name = name; def_text = text; def_loc = mkloc $loc } }
```

- [ ] **Step 6: Update `lib/compile.ml` (parse -> agent_file, add parse_library)**

Replace the existing `parse` with a shared driver plus the two entry points (keep the rest of the file unchanged for now):
```ocaml
let run_parser entry (src : string) =
  let lexbuf = Lexing.from_string src in
  lexbuf.Lexing.lex_curr_p <-
    { lexbuf.Lexing.lex_curr_p with Lexing.pos_lnum = 1; pos_fname = "" };
  try Ok (entry Lexer.token lexbuf) with
  | Lexer.Error (msg, loc) -> Error (Error.make loc msg)
  | Parser.Error ->
      let tok = Lexing.lexeme lexbuf in
      let msg =
        if tok = "" then "syntax error at end of input"
        else Printf.sprintf "syntax error near '%s'" tok
      in
      let loc =
        Location.of_positions (Lexing.lexeme_start_p lexbuf) (Lexing.lexeme_end_p lexbuf)
      in
      Error (Error.make loc msg)

let parse (src : string) : (Ast.agent_file, Error.t) result = run_parser Parser.program src
let parse_library (src : string) : (Ast.def_decl list, Error.t) result =
  run_parser Parser.library src
```
Then update `parse_and_check` to extract the agent (resolve comes in Task 5):
```ocaml
let parse_and_check (src : string) : (Sema.checked, Error.t list) result =
  match parse src with
  | Error e -> Error [ e ]
  | Ok af -> Sema.analyze af.Ast.af_agent
```
(`compile_string` is unchanged this task — it still calls `parse_and_check`.)

- [ ] **Step 7: Update existing test call sites (mechanical, parse now returns agent_file)**

In `test/test_parser.ml`, every existing test binds `Ok block ->` and reads `block.Ast.block_name` / `block.Ast.block_items`. Rename the binder to `Ok af ->` and replace each `block.Ast.X` with `af.Ast.af_agent.Ast.X`. (Affected: `test_parse_ok`, `test_schema_types`, `test_parse_input_block` — any test that inspects the parsed block.)

In `test/test_sema.ml`, the helper currently ends `| Ok b -> Sema.analyze b`. Change to:
```ocaml
  | Ok af -> Sema.analyze af.Ast.af_agent
```

- [ ] **Step 8: Run to verify it passes**

`dune build 2>&1 | head && dune test 2>&1 | tail -8 && ./scripts/check-corpus.sh`
Expected: clean build (no menhir conflicts), the two new parser cases pass, all prior cases pass, corpus 25/25.

- [ ] **Step 9: Commit**

```bash
git add lib/ast.ml lib/lexer.mll lib/parser.mly lib/compile.ml test/test_parser.ml test/test_sema.ml
git commit -m "feat(import): parse import* agent files and def-only lib files (two grammars)"
```

---

### Task 2: `resolve` — load + collect fragments

**Files:** Create `lib/resolve.ml`, `test/test_resolve.ml`; register in `test/test_promptdsl.ml`.

- [ ] **Step 1: Write the failing tests**

`test/test_resolve.ml`:
```ocaml
open Promptdsl

(* in-memory loader *)
let mem files path =
  match List.assoc_opt path files with Some c -> Ok c | None -> Error "no such file"

let imp path alias = { Ast.imp_path = path; imp_alias = alias; imp_loc = Location.dummy }

let test_resolve_ok () =
  let files = [ ("fin.prompt", {|def disclaimer = "D"  def rubric = "R"|}) ] in
  match
    Resolve.resolve ~parse_lib:Compile.parse_library ~resolver:(mem files)
      [ imp "fin.prompt" "fin" ]
  with
  | Error _ -> Alcotest.fail "unexpected error"
  | Ok frags ->
      Alcotest.(check (option string)) "found" (Some "D") (Resolve.lookup frags "fin" "disclaimer");
      (match Resolve.find frags "nope" "x" with
       | Resolve.NoAlias -> ()
       | _ -> Alcotest.fail "expected NoAlias");
      (match Resolve.find frags "fin" "nope" with
       | Resolve.NoDef -> ()
       | _ -> Alcotest.fail "expected NoDef")

let has frags msg ds =
  ignore frags;
  List.exists (fun (d : Error.t) -> d.Error.message = msg) ds

let test_resolve_not_found () =
  match Resolve.resolve ~parse_lib:Compile.parse_library ~resolver:(mem []) [ imp "x.prompt" "x" ] with
  | Ok _ -> Alcotest.fail "expected error"
  | Error ds ->
      Alcotest.(check bool) "not found" true
        (has () "cannot import \"x.prompt\": no such file" ds)

let test_resolve_not_def_only () =
  let files = [ ("bad.prompt", {|agent "a" { goal "g" }|}) ] in
  match Resolve.resolve ~parse_lib:Compile.parse_library ~resolver:(mem files) [ imp "bad.prompt" "b" ] with
  | Ok _ -> Alcotest.fail "expected error"
  | Error ds ->
      Alcotest.(check bool) "not def-only" true
        (List.exists
           (fun (d : Error.t) ->
             let m = d.Error.message in
             String.length m > 13 && String.sub m 0 13 = "imported file")
           ds)

let test_resolve_dup_alias () =
  let files = [ ("a.prompt", {|def x = "1"|}) ] in
  match
    Resolve.resolve ~parse_lib:Compile.parse_library ~resolver:(mem files)
      [ imp "a.prompt" "fin"; imp "a.prompt" "fin" ]
  with
  | Ok _ -> Alcotest.fail "expected error"
  | Error ds ->
      Alcotest.(check bool) "dup alias" true
        (has () "duplicate import alias 'fin'" ds)

let suite =
  ( "resolve",
    [ Alcotest.test_case "ok" `Quick test_resolve_ok;
      Alcotest.test_case "not found" `Quick test_resolve_not_found;
      Alcotest.test_case "not def-only" `Quick test_resolve_not_def_only;
      Alcotest.test_case "dup alias" `Quick test_resolve_dup_alias ] )
```
Append `Test_resolve.suite` to the runner list in `test/test_promptdsl.ml`.

- [ ] **Step 2: Run to verify it fails**

`dune test 2>&1 | head -10` → `Unbound module Resolve`.

- [ ] **Step 3: Implement `resolve`**

`lib/resolve.ml`:
```ocaml
type lookup_result = Found of string | NoAlias | NoDef

type fragments = (string * (string * string) list) list
(* alias -> [(def_name, def_text)] *)

let find (frags : fragments) (alias : string) (name : string) : lookup_result =
  match List.assoc_opt alias frags with
  | None -> NoAlias
  | Some defs -> ( match List.assoc_opt name defs with Some t -> Found t | None -> NoDef)

let lookup frags alias name =
  match find frags alias name with Found t -> Some t | _ -> None

let resolve ~(parse_lib : string -> (Ast.def_decl list, Error.t) result)
    ~(resolver : string -> (string, string) result) (imports : Ast.import_decl list) :
    (fragments, Error.t list) result =
  let errors = ref [] in
  let add loc m = errors := Error.make loc m :: !errors in
  let seen = Hashtbl.create 8 in
  let frags = ref [] in
  List.iter
    (fun (imp : Ast.import_decl) ->
      if Hashtbl.mem seen imp.Ast.imp_alias then
        add imp.Ast.imp_loc
          (Printf.sprintf "duplicate import alias '%s'" imp.Ast.imp_alias)
      else begin
        Hashtbl.add seen imp.Ast.imp_alias ();
        match resolver imp.Ast.imp_path with
        | Error msg ->
            add imp.Ast.imp_loc
              (Printf.sprintf "cannot import %S: %s" imp.Ast.imp_path msg)
        | Ok contents -> (
            match parse_lib contents with
            | Error e ->
                add imp.Ast.imp_loc
                  (Printf.sprintf "imported file %S is not a valid library: %s"
                     imp.Ast.imp_path e.Error.message)
            | Ok defs ->
                let seen_def = Hashtbl.create 8 in
                let pairs =
                  List.filter_map
                    (fun (d : Ast.def_decl) ->
                      if Hashtbl.mem seen_def d.Ast.def_name then begin
                        add imp.Ast.imp_loc
                          (Printf.sprintf "duplicate def '%s' in import %S"
                             d.Ast.def_name imp.Ast.imp_path);
                        None
                      end
                      else begin
                        Hashtbl.add seen_def d.Ast.def_name ();
                        Some (d.Ast.def_name, d.Ast.def_text)
                      end)
                    defs
                in
                frags := (imp.Ast.imp_alias, pairs) :: !frags)
      end)
    imports;
  match List.rev !errors with [] -> Ok (List.rev !frags) | es -> Error es
```

- [ ] **Step 4: Run to verify it passes**

`dune test 2>&1 | tail -6` → `resolve` suite passes.

- [ ] **Step 5: Commit**

```bash
git add lib/resolve.ml test/test_resolve.ml test/test_promptdsl.ml
git commit -m "feat(import): resolve stage loads libs and collects fragments"
```

---

### Task 3: Sema — validate `{{alias.name}}` references

**Files:** Modify `lib/sema.ml`, `test/test_sema.ml`.

- [ ] **Step 1: Write the failing tests**

Add to `test/test_sema.ml` a helper + cases (and register). The existing `analyze`/`ok_or_fail`/`err_or_fail` don't pass fragments; add a fragment-aware analyzer:
```ocaml
let analyze_with frags src =
  match Compile.parse src with
  | Error e -> Alcotest.failf "parse error: %s" e.Error.message
  | Ok af -> Sema.analyze ~fragments:frags af.Ast.af_agent

let test_fragment_ref_ok () =
  let frags = [ ("fin", [ ("disclaimer", "D") ]) ] in
  match analyze_with frags {|agent "a" { goal "g {{fin.disclaimer}}" }|} with
  | Ok _ -> ()
  | Error ds ->
      Alcotest.failf "unexpected: %s"
        (String.concat "; " (List.map (fun (d : Error.t) -> d.Error.message) ds))

let test_unknown_alias () =
  match analyze_with [] {|agent "a" { goal "g {{fin.disclaimer}}" }|} with
  | Ok _ -> Alcotest.fail "expected error"
  | Error ds ->
      Alcotest.(check bool) "unknown alias" true
        (List.exists
           (fun (d : Error.t) -> d.Error.message = "unknown import alias 'fin'")
           ds)

let test_unknown_def () =
  let frags = [ ("fin", [ ("disclaimer", "D") ]) ] in
  match analyze_with frags {|agent "a" { goal "g {{fin.nope}}" }|} with
  | Ok _ -> Alcotest.fail "expected error"
  | Error ds ->
      Alcotest.(check bool) "unknown def" true
        (List.exists
           (fun (d : Error.t) -> d.Error.message = "no def 'nope' in import 'fin'")
           ds)
```
Register: `fragment ref ok`, `unknown alias`, `unknown def`.

- [ ] **Step 2: Run to verify it fails**

`dune test 2>&1 | head -10` → `Sema.analyze` has no `~fragments` label.

- [ ] **Step 3: Extend `analyze`**

In `lib/sema.ml`, change the `analyze` signature to add an optional fragments param:
```ocaml
let analyze ?(fragments : Resolve.fragments = []) (block : Ast.agent_block) :
    (checked, Error.t list) result =
```
Replace the existing post-loop ref-validation block (the one that reports `undeclared input reference`) with:
```ocaml
  let declared = List.map (fun (i : checked_input) -> i.ci_name) !inputs in
  List.iter
    (fun (text, span) ->
      List.iter
        (fun name ->
          match String.index_opt name '.' with
          | Some i ->
              let alias = String.sub name 0 i in
              let dname = String.sub name (i + 1) (String.length name - i - 1) in
              (match Resolve.find fragments alias dname with
               | Resolve.Found _ -> ()
               | Resolve.NoAlias ->
                   add (Error.make span (Printf.sprintf "unknown import alias '%s'" alias))
               | Resolve.NoDef ->
                   add (Error.make span
                          (Printf.sprintf "no def '%s' in import '%s'" dname alias)))
          | None ->
              if not (List.mem name declared) then
                add (Error.make span
                       (Printf.sprintf "undeclared input reference '{{%s}}'" name)))
        (Interp.refs text))
    (List.rev !ref_sites);
```

- [ ] **Step 4: Run to verify it passes**

`dune test 2>&1 | tail -10` → the three new sema cases pass; all prior sema/parser/etc. pass.

- [ ] **Step 5: Commit**

```bash
git add lib/sema.ml test/test_sema.ml
git commit -m "feat(import): sema validates {{alias.name}} fragment references"
```

---

### Task 4: Bind — substitute fragments

**Files:** Modify `lib/bind.ml`, `test/test_bind.ml`.

- [ ] **Step 1: Write the failing test**

Add to `test/test_bind.ml` (and register). The existing `bind` helper uses `parse_and_check`; add a fragment-aware path:
```ocaml
let test_fragment_subst () =
  match Compile.parse {|agent "a" { input { t: string } goal "{{t}} {{fin.disclaimer}}" }|} with
  | Error e -> Alcotest.failf "parse: %s" e.Error.message
  | Ok af -> (
      let frags = [ ("fin", [ ("disclaimer", "D") ]) ] in
      match Sema.analyze ~fragments:frags af.Ast.af_agent with
      | Error _ -> Alcotest.fail "sema error"
      | Ok c -> (
          match Bind.bind ~fragments:frags c [ ("t", "X") ] with
          | Error _ -> Alcotest.fail "bind error"
          | Ok b -> Alcotest.(check string) "subst" "X D" b.Bind.b_goal))
```
Register: `Alcotest.test_case "fragment subst" `Quick test_fragment_subst;`.

- [ ] **Step 2: Run to verify it fails**

`dune test 2>&1 | head -10` → `Bind.bind` has no `~fragments` label.

- [ ] **Step 3: Extend `bind`**

In `lib/bind.ml`, change the `bind` signature to add the optional fragments param:
```ocaml
let bind ?(fragments : Resolve.fragments = []) (c : Sema.checked)
    (values : (string * string) list) : (bound, Error.t list) result =
```
Replace the `lookup` used for substitution (the `let lookup name = Hashtbl.find_opt resolved name in`) with a fragment-aware version:
```ocaml
      let lookup x =
        match String.index_opt x '.' with
        | Some i ->
            let alias = String.sub x 0 i in
            let name = String.sub x (i + 1) (String.length x - i - 1) in
            Resolve.lookup fragments alias name
        | None -> Hashtbl.find_opt resolved x
      in
```

- [ ] **Step 4: Run to verify it passes**

`dune test 2>&1 | tail -6` → the new bind case passes; all prior pass.

- [ ] **Step 5: Commit**

```bash
git add lib/bind.ml test/test_bind.ml
git commit -m "feat(import): bind substitutes {{alias.name}} fragments"
```

---

### Task 5: Wire resolve into compile + filesystem resolver

**Files:** Modify `lib/compile.ml`, `lib/driver.ml`, `test/test_backends.ml`.

- [ ] **Step 1: Write the failing test**

Add to `test/test_backends.ml` (and register) — end-to-end compile with an in-memory resolver:
```ocaml
let test_import_end_to_end () =
  let resolver = function
    | "fin.prompt" -> Ok {|def disclaimer = "Not advice."|}
    | _ -> Error "no such file"
  in
  let src =
    {|import "fin.prompt" as fin
      agent "a" { goal "Analyze. {{fin.disclaimer}}" }|}
  in
  match Compile.compile_string ~resolver src with
  | Compile.Failure ds ->
      Alcotest.failf "unexpected failure: %s"
        (String.concat "; " (List.map (fun (d : Error.t) -> d.Error.message) ds))
  | Compile.Success o ->
      Alcotest.(check bool) "fragment substituted" true
        (contains o.Compile.prose "Analyze. Not advice.")
```
Register: `Alcotest.test_case "import end-to-end" `Quick test_import_end_to_end;`.

- [ ] **Step 2: Run to verify it fails**

`dune test 2>&1 | head -12` → `compile_string` has no `~resolver` label.

- [ ] **Step 3: Rewrite the Compile frontend**

In `lib/compile.ml`, replace `parse_and_check` and `compile_string` with a shared `frontend` plus a default resolver (keep `run_parser`/`parse`/`parse_library` from Task 1, and `outputs`/`outcome`):
```ocaml
let default_resolver (_ : string) : (string, string) result =
  Error "imports require a file context (compile a file, not a bare string)"

let frontend ?(resolver = default_resolver) (src : string) :
    (Sema.checked * Resolve.fragments, Error.t list) result =
  match parse src with
  | Error e -> Error [ e ]
  | Ok af -> (
      match Resolve.resolve ~parse_lib:parse_library ~resolver af.Ast.af_imports with
      | Error ds -> Error ds
      | Ok fragments -> (
          match Sema.analyze ~fragments af.Ast.af_agent with
          | Error ds -> Error ds
          | Ok checked -> Ok (checked, fragments)))

let parse_and_check ?(resolver = default_resolver) (src : string) :
    (Sema.checked, Error.t list) result =
  Result.map fst (frontend ~resolver src)

let compile_string ?(values = []) ?(resolver = default_resolver) (src : string) : outcome =
  match frontend ~resolver src with
  | Error ds -> Failure ds
  | Ok (checked, fragments) -> (
      match Bind.bind ~fragments checked values with
      | Error ds -> Failure ds
      | Ok bound ->
          let ir = Lower.lower bound in
          Success { prose = Backend_prose.render ir; json = Backend_openai.render ir })
```
(Delete the old `parse_and_check`/`compile_string` bodies. Note `parse_and_check` keeps its old default behavior for callers that pass no resolver — `test_bind`/`test_sema` no-import snippets still work because the default resolver is only invoked when there are imports.)

- [ ] **Step 4: Add the filesystem resolver to the driver**

In `lib/driver.ml`, add (above `run_check`):
```ocaml
let fs_resolver base_dir path : (string, string) result =
  match read_file (Filename.concat base_dir path) with
  | s -> Ok s
  | exception Sys_error msg -> Error msg
```
In `run_check`, build a resolver and pass it:
```ocaml
      let resolver = fs_resolver (Filename.dirname file) in
      (match Compile.parse_and_check ~resolver src with
       | Ok _ -> print_endline "OK"; 0
       | Error ds -> print_diags file ds; 1)
```
In `run_compile`, after reading `src`, build the resolver and pass it to `compile_string`:
```ocaml
          let resolver = fs_resolver (Filename.dirname file) in
          match Compile.compile_string ~values ~resolver src with
```

- [ ] **Step 5: Run to verify it passes**

`dune test 2>&1 | tail -6 && ./scripts/check-corpus.sh`
Expected: the new `import end-to-end` case passes; all prior tests pass; corpus 25/25 (no-import agents unaffected — they never hit the resolver).

- [ ] **Step 6: Commit**

```bash
git add lib/compile.ml lib/driver.ml test/test_backends.ml
git commit -m "feat(import): wire resolve into compile; filesystem resolver in driver"
```

---

### Task 6: CLI end-to-end + cram

**Files:** Create `test/cram/import.t`.

- [ ] **Step 1: Manual end-to-end check**

```bash
dune build 2>&1 | head
mkdir -p /tmp/impdemo
printf 'def disclaimer = "Informational, not advice."\n' > /tmp/impdemo/fin.prompt
printf 'import "fin.prompt" as fin\nagent "r" {\n  input { ticker: string }\n  goal "Analyze {{ticker}}. {{fin.disclaimer}}"\n}\n' > /tmp/impdemo/r.prompt
dune exec promptc -- compile /tmp/impdemo/r.prompt --set ticker=TSLA --emit prose
```
Expected: prose contains `Goal: Analyze TSLA. Informational, not advice.`. Then a missing-import check:
```bash
printf 'import "nope.prompt" as x\nagent "r" { goal "g {{x.y}}" }\n' > /tmp/impdemo/bad.prompt
dune exec promptc -- compile /tmp/impdemo/bad.prompt; echo "exit=$?"
```
Expected: a `cannot import "nope.prompt": ...` diagnostic on stderr, `exit=1`.

- [ ] **Step 2: Add the cram test (commands only; promote output)**

`test/cram/import.t`:
```
A def from an imported lib is substituted at compile time:

  $ printf 'def disclaimer = "Informational, not advice."\n' > fin.prompt
  $ printf 'import "fin.prompt" as fin\nagent "r" {\n  input { ticker: string }\n  goal "Analyze {{ticker}}. {{fin.disclaimer}}"\n}\n' > r.prompt
  $ promptc compile r.prompt --set ticker=TSLA --emit prose

A missing import is reported and exits 1:

  $ printf 'import "nope.prompt" as x\nagent "r" { goal "g {{x.y}}" }\n' > bad.prompt
  $ promptc compile bad.prompt
  [1]
```

- [ ] **Step 3: Record golden output and verify**

```bash
dune runtest --auto-promote 2>&1 | tail -5
dune runtest 2>&1; echo "exit=$?"
```
Review `git diff test/cram/import.t`: the prose must contain `Analyze TSLA. Informational, not advice.`; the missing-import run must show a `cannot import "nope.prompt": ...` diagnostic and `[1]`. Confirm `test/cram/compile.t`, `check.t`, `emit.t`, `input.t` are UNCHANGED (backward compat). Re-run `dune runtest` → clean, exit 0.

- [ ] **Step 4: Final full check**

```bash
dune runtest --force 2>&1 | tail -4
./scripts/check-corpus.sh
```
Expected: all unit + cram pass; corpus 25/25 unchanged.

- [ ] **Step 5: Commit**

```bash
git add test/cram/import.t
git commit -m "feat(import): cram coverage for import + fragment substitution"
```

---

## Self-Review

**Spec coverage:**
- `def`/`import as alias`/`{{alias.name}}` surface → Task 1 (parse) + Task 3 (sema) + Task 4 (bind).
- Two grammars (agent file / lib def-only) → Task 1.
- resolve stage (load, parse-lib, collect, validate errors: not-found, not-def-only, dup alias, dup def) → Task 2.
- Namespaced reference rule (dot → fragment) → Tasks 3 & 4 (shared split-on-dot).
- Single-level / def-only enforced: a lib with an agent fails the `library` grammar → "not a valid library" (Task 2 test). Nested `import` in a lib likewise fails the `library` grammar (no import rule there). ✓
- Path relative to main file dir → Task 5 `fs_resolver (Filename.dirname file)`.
- Fragments are plain text, compile-time, no nested interpolation → `Interp.subst` single pass (a `{{}}` inside fragment text is inserted verbatim, not re-substituted).
- resolver threading + backward compat → Task 5 (default resolver only invoked when imports exist) + corpus 25/25 checks.
- `check` validates refs without binding → `parse_and_check` runs frontend (parse→resolve→sema), no bind.

**Placeholder scan:** none — full code per step; the one mechanical uniform edit (Task 1 Step 7, `block` → `af.af_agent`) is described as an exact substitution, and cram output is generated by `--auto-promote` with explicit review criteria.

**Type consistency:** `Ast.def_decl`/`import_decl`/`agent_file` fields (`def_*`/`imp_*`/`af_*`); `Resolve.fragments` + `lookup_result` (`Found`/`NoAlias`/`NoDef`) used identically in `Resolve.find`, `Sema.analyze`, and `test_resolve`; `Sema.analyze`/`Bind.bind` both gain `?fragments:Resolve.fragments`; `Compile.parse : … agent_file`, `parse_library : … def_decl list`, `frontend`/`compile_string`/`parse_and_check` all take `?resolver`. The split-on-first-`.` rule is identical in sema and bind. No module cycle: `Resolve` depends only on `Ast`/`Error` (parse injected); `Sema`/`Bind` depend on `Resolve`; `Compile` depends on all.
