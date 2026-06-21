# TypeScript Typed Client Codegen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `promptc codegen <file> --target <p>` emits one self-contained, zero-dependency TypeScript file: a typed `agentName(inputs) → Promise<Output>` that builds the request, calls the provider, extracts + validates the reply, and returns the typed result.

**Architecture:** A new `lib/codegen_ts.ml`. It hooks after `Compile.frontend` (→ `checked`, `fragments`), builds a template `Bind.bound` (fragments resolved, input refs left as `{{name}}` holes), `Lower.lower`s it, and renders it with the existing `Backend_<target>.render`. The resulting request JSON (holes intact) is emitted as a TS expression where each `{{name}}` becomes `${inputs.name}`. Types come from `checked.inputs`/`checked.output`; a zero-dep validator is generated for typed json.

**Tech Stack:** OCaml 5.4, dune, yojson, cmdliner, alcotest, cram. Generated output: TypeScript (no runtime deps; `fetch` + env). warning-8 (non-exhaustive match) is an error.

**Spec:** `docs/superpowers/specs/2026-06-17-ts-codegen-design.md`

**Verified signatures (do not re-derive):**
- `Sema.checked = { name:string; goal:string; steps:checked_step list; output:checked_output; inputs:checked_input list; has_input_block:bool }`
- `Sema.checked_step = { verb:string; arg:string option }`
- `Sema.checked_input = { ci_name:string; ci_ty:Ast.ty; ci_default:string option; ci_content:bool; ci_loc:Location.t }`
- `Sema.checked_output = COText | COMarkdown | COJson of Ast.field list option`
- `Ast.ty = TString | TInt | TBool | TFloat | TEnum of string list | TList of ty`
- `Ir.schema_ty = SString|SInt|SBool|SFloat|SEnum of string list|SList of schema_ty`; `Ir.schema_field = {fname;fty;required;range:(float*float) option}`; `Ir.output = OText|OMarkdown|OJson of schema_field list option`; `Ir.t = {agent_name;objective;instructions;out;content}`
- `Bind.bound = { b_name:string; b_goal:string; b_steps:Sema.checked_step list; b_output:Sema.checked_output; b_content:string option }`
- `Lower.lower : Bind.bound -> Ir.t` (and public `Lower.render_instruction`, `Lower.output_to_ir`)
- `Interp.subst : (string -> string option) -> string -> string`; `Interp.refs : string -> string list`
- `Resolve.lookup : Resolve.fragments -> string -> string -> string option`
- `Compile.frontend ?resolver (src) : (Sema.checked * Resolve.fragments, Error.t list) result`
- `Backend_openai.render ?no_content_user ?model (ir)` / `Backend_anthropic.render ?no_content_user ?model (ir)` / `Backend_gemini.render ?no_content_user (ir)`; `Backend_<p>.default_model`

**Conventions:** Build `dune build`; tests `dune runtest --force 2>&1 | grep -E "tests run|FAIL"`; corpus `bash scripts/check-corpus.sh` (stay `25/25`). The `promptdsl` library and the `test_promptdsl` test exe auto-include new `.ml` files; the new test suite must be registered in `test/test_promptdsl.ml`. No dune edits needed.

---

## File Structure

- `lib/codegen_ts.ml` (NEW) — the generator; built up over Tasks 1–4.
- `lib/driver.ml` (MODIFY) — add `run_codegen` (Task 5).
- `bin/main.ml` (MODIFY) — add `output_arg` + `codegen_cmd` (Task 5).
- `test/test_codegen.ml` (NEW) — unit tests; registered in `test/test_promptdsl.ml` (Task 1).
- `test/cram/codegen.t` (NEW) — golden output (Task 5).

---

## Task 1: `Codegen_ts` scaffolding — identifiers, type mapping, template IR

**Files:**
- Create: `lib/codegen_ts.ml`
- Create: `test/test_codegen.ml`
- Modify: `test/test_promptdsl.ml`

- [ ] **Step 1: Write the failing test**

Create `test/test_codegen.ml`:

```ocaml
open Promptdsl

let contains s sub =
  let ls = String.length s and lsub = String.length sub in
  let rec go i =
    if i + lsub > ls then false
    else if String.sub s i lsub = sub then true
    else go (i + 1)
  in
  go 0

let test_ts_type_mapping () =
  Alcotest.(check string) "enum union" {|"buy" | "sell"|}
    (Codegen_ts.ts_of_schema_ty (Ir.SEnum [ "buy"; "sell" ]));
  Alcotest.(check string) "list" "string[]"
    (Codegen_ts.ts_of_schema_ty (Ir.SList Ir.SString));
  Alcotest.(check string) "int -> number" "number"
    (Codegen_ts.ts_of_schema_ty Ir.SInt);
  Alcotest.(check string) "ast enum" {|"a" | "b"|}
    (Codegen_ts.ts_of_ast_ty (Ast.TEnum [ "a"; "b" ]))

let test_identifiers () =
  Alcotest.(check string) "pascal" "EarningsAnalyst" (Codegen_ts.pascal "earnings-analyst");
  Alcotest.(check string) "camel" "earningsAnalyst" (Codegen_ts.camel "earnings analyst")

let test_template_ir_holes () =
  match
    Compile.frontend {|agent "r" { input { ticker: string } goal "analyze {{ticker}}" }|}
  with
  | Error _ -> Alcotest.fail "frontend failed"
  | Ok (checked, fragments) ->
      let ir = Codegen_ts.template_ir checked fragments in
      Alcotest.(check bool) "hole preserved in objective" true
        (contains ir.Ir.objective "{{ticker}}")

let suite =
  ( "codegen",
    [ Alcotest.test_case "ts type mapping" `Quick test_ts_type_mapping;
      Alcotest.test_case "identifiers" `Quick test_identifiers;
      Alcotest.test_case "template ir holes" `Quick test_template_ir_holes ] )
```

Register it in `test/test_promptdsl.ml` by adding `Test_codegen.suite;` to the list passed to `Alcotest.run`.

- [ ] **Step 2: Run the build to confirm it fails**

Run: `dune build 2>&1 | head -20`
Expected: FAIL — `Unbound module Codegen_ts`.

- [ ] **Step 3: Create `lib/codegen_ts.ml`**

```ocaml
(* TypeScript typed-client codegen. *)

(* --- identifiers --- *)

(* Split a name into alphanumeric words (drop other chars). *)
let words (s : string) : string list =
  let buf = Buffer.create 16 in
  let out = ref [] in
  let flush () = if Buffer.length buf > 0 then (out := Buffer.contents buf :: !out; Buffer.clear buf) in
  String.iter
    (fun c ->
      if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
      then Buffer.add_char buf c
      else flush ())
    s;
  flush ();
  List.rev !out

let cap s =
  if s = "" then s
  else String.make 1 (Char.uppercase_ascii s.[0]) ^ String.sub s 1 (String.length s - 1)

(* Leading digit would be an invalid identifier; prefix with '_'. *)
let safe_ident s = if s <> "" && s.[0] >= '0' && s.[0] <= '9' then "_" ^ s else s

let pascal (name : string) : string =
  safe_ident (match words name with [] -> "Agent" | ws -> String.concat "" (List.map cap ws))

let camel (name : string) : string =
  let p = pascal name in
  if p = "" then p else String.make 1 (Char.lowercase_ascii p.[0]) ^ String.sub p 1 (String.length p - 1)

(* --- TS type mapping --- *)

let union opts = String.concat " | " (List.map (fun o -> Yojson.Safe.to_string (`String o)) opts)

let rec ts_of_ast_ty (t : Ast.ty) : string =
  match t with
  | Ast.TString -> "string"
  | Ast.TInt | Ast.TFloat -> "number"
  | Ast.TBool -> "boolean"
  | Ast.TEnum opts -> union opts
  | Ast.TList t -> ts_of_ast_ty t ^ "[]"

let rec ts_of_schema_ty (t : Ir.schema_ty) : string =
  match t with
  | Ir.SString -> "string"
  | Ir.SInt | Ir.SFloat -> "number"
  | Ir.SBool -> "boolean"
  | Ir.SEnum opts -> union opts
  | Ir.SList t -> ts_of_schema_ty t ^ "[]"

(* --- template IR (fragments resolved, input refs left as {{name}} holes) --- *)

let template_ir (checked : Sema.checked) (fragments : Resolve.fragments) : Ir.t =
  let frag_lookup x =
    match String.index_opt x '.' with
    | Some i ->
        let alias = String.sub x 0 i in
        let name = String.sub x (i + 1) (String.length x - i - 1) in
        Resolve.lookup fragments alias name
    | None -> None
  in
  let b_goal = Interp.subst frag_lookup checked.Sema.goal in
  let b_steps =
    List.map
      (fun (s : Sema.checked_step) ->
        { s with Sema.arg = Option.map (Interp.subst frag_lookup) s.Sema.arg })
      checked.Sema.steps
  in
  let b_content =
    match List.find_opt (fun (i : Sema.checked_input) -> i.Sema.ci_content) checked.Sema.inputs with
    | Some i -> Some ("{{" ^ i.Sema.ci_name ^ "}}")
    | None -> if checked.Sema.has_input_block then Some "" else None
  in
  Lower.lower
    { Bind.b_name = checked.Sema.name; b_goal; b_steps;
      b_output = checked.Sema.output; b_content }
```

- [ ] **Step 4: Build and test — verify green**

Run: `dune build && dune runtest --force 2>&1 | grep -E "tests run|FAIL"` then `bash scripts/check-corpus.sh`
Expected: PASS — the 3 codegen cases pass; everything else green; corpus `25/25`.

- [ ] **Step 5: Commit**

```bash
git add lib/codegen_ts.ml test/test_codegen.ml test/test_promptdsl.ml
git commit -m "feat(codegen): TS scaffolding — identifiers, type mapping, template IR

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Request-body emitter (`{{name}}` → `${inputs.name}`)

**Files:**
- Modify: `lib/codegen_ts.ml`
- Test: `test/test_codegen.ml`

- [ ] **Step 1: Write the failing test**

Add to `test/test_codegen.ml` above `let suite` and register the cases:

```ocaml
let test_body_emitter () =
  (* a plain string -> JSON string literal *)
  Alcotest.(check string) "plain string" {|"hi"|} (Codegen_ts.yojson_to_ts (`String "hi"));
  (* a holey string -> backtick template literal with ${inputs.x} *)
  let t = Codegen_ts.yojson_to_ts (`String "analyze {{ticker}} now") in
  Alcotest.(check bool) "is template literal" true (contains t "${inputs.ticker}");
  Alcotest.(check bool) "is backticked" true (String.length t > 0 && t.[0] = '`');
  (* nested object/array round-trips structurally *)
  let o = Codegen_ts.yojson_to_ts (`Assoc [ ("a", `Int 1); ("b", `List [ `Bool true ]) ]) in
  Alcotest.(check bool) "object keys quoted" true (contains o {|"a": 1|});
  Alcotest.(check bool) "array" true (contains o "[true]")
```

Register: `Alcotest.test_case "body emitter" \`Quick test_body_emitter;`

- [ ] **Step 2: Confirm it fails**

Run: `dune build 2>&1 | head -20` → expect `Codegen_ts.yojson_to_ts` unbound.

- [ ] **Step 3: Add the emitter to `lib/codegen_ts.ml`** (append after the type mapping section)

```ocaml
(* --- request body: Yojson -> TS expression, holes -> ${inputs.name} --- *)

(* Escape a string for inside a `...` template literal: \, `, and ${ . *)
let esc_template (s : string) : string =
  let b = Buffer.create (String.length s + 8) in
  let n = String.length s in
  let i = ref 0 in
  while !i < n do
    let c = s.[!i] in
    if c = '\\' then Buffer.add_string b "\\\\"
    else if c = '`' then Buffer.add_string b "\\`"
    else if c = '$' && !i + 1 < n && s.[!i + 1] = '{' then Buffer.add_string b "\\$"
    else Buffer.add_char b c;
    incr i
  done;
  Buffer.contents b

(* A string value -> a TS expression. If it has {{name}} holes, a template
   literal with ${inputs.name}; otherwise a JSON string literal. By this point
   any remaining holes are input names (fragments were resolved in template_ir). *)
let ts_string_expr (s : string) : string =
  if Interp.refs s = [] then Yojson.Safe.to_string (`String s)
  else
    let body = Interp.subst (fun name -> Some (Printf.sprintf "${inputs.%s}" name)) (esc_template s) in
    "`" ^ body ^ "`"

let rec yojson_to_ts (j : Yojson.Safe.t) : string =
  match j with
  | `String s -> ts_string_expr s
  | `Assoc kvs ->
      "{ "
      ^ String.concat ", "
          (List.map
             (fun (k, v) -> Yojson.Safe.to_string (`String k) ^ ": " ^ yojson_to_ts v)
             kvs)
      ^ " }"
  | `List xs -> "[" ^ String.concat ", " (List.map yojson_to_ts xs) ^ "]"
  | other -> Yojson.Safe.to_string other
```

Note: `esc_template` turns a literal `${` in prose into `\${`; the `{{name}}` holes contain no `$`, survive escaping, then `Interp.subst` rewrites them to `${inputs.name}` (inserted after escaping, so not re-escaped).

- [ ] **Step 4: Build and test — verify green**

Run: `dune build && dune runtest --force 2>&1 | grep -E "tests run|FAIL"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/codegen_ts.ml test/test_codegen.ml
git commit -m "feat(codegen): Yojson->TS body emitter with {{name}} -> \${inputs.name}

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Output type + runtime validator emitter

**Files:**
- Modify: `lib/codegen_ts.ml`
- Test: `test/test_codegen.ml`

- [ ] **Step 1: Write the failing test**

Add to `test/test_codegen.ml` and register:

```ocaml
let test_validator () =
  let fields =
    [ { Ir.fname = "rating"; fty = Ir.SEnum [ "buy"; "sell" ]; required = true; range = None };
      { Ir.fname = "score"; fty = Ir.SInt; required = true; range = Some (0., 100.) };
      { Ir.fname = "note"; fty = Ir.SString; required = false; range = None } ]
  in
  let v = Codegen_ts.gen_validator "FooOutput" fields in
  Alcotest.(check bool) "fn header" true (contains v "function validateFooOutput(x: any): FooOutput");
  Alcotest.(check bool) "enum check" true (contains v {|["buy", "sell"].includes|});
  Alcotest.(check bool) "range check" true (contains v "x[\"score\"] < 0 || x[\"score\"] > 100");
  Alcotest.(check bool) "optional guard" true (contains v {|x["note"] !== undefined|});
  Alcotest.(check string) "object type" "{ rating: \"buy\" | \"sell\"; score: number; note?: string }"
    (Codegen_ts.ts_output_type (Ir.OJson (Some fields)));
  Alcotest.(check string) "text type" "string" (Codegen_ts.ts_output_type Ir.OText);
  Alcotest.(check string) "bare json type" "unknown" (Codegen_ts.ts_output_type (Ir.OJson None))
```

Register: `Alcotest.test_case "validator" \`Quick test_validator;`

- [ ] **Step 2: Confirm it fails**

Run: `dune build 2>&1 | head -20` → expect `Codegen_ts.gen_validator` / `ts_output_type` unbound.

- [ ] **Step 3: Add to `lib/codegen_ts.ml`** (append)

```ocaml
(* --- output type --- *)

let ts_output_type (out : Ir.output) : string =
  match out with
  | Ir.OText | Ir.OMarkdown -> "string"
  | Ir.OJson None -> "unknown"
  | Ir.OJson (Some fields) ->
      let field (f : Ir.schema_field) =
        Printf.sprintf "%s%s: %s" f.Ir.fname (if f.required then "" else "?")
          (ts_of_schema_ty f.fty)
      in
      "{ " ^ String.concat "; " (List.map field fields) ^ " }"

(* --- runtime validator --- *)

(* Format a range bound as a TS number literal. *)
let num (f : float) : string =
  if Float.is_integer f then string_of_int (int_of_float f) else Printf.sprintf "%g" f

(* Lines that throw if [acc] (assumed present) doesn't match [fty]/[range]. *)
let rec check_lines (acc : string) (fty : Ir.schema_ty) (range : (float * float) option)
    (label : string) : string list =
  let err msg = Printf.sprintf "throw new Error(%s)" (Yojson.Safe.to_string (`String (label ^ ": " ^ msg))) in
  match fty with
  | Ir.SString -> [ Printf.sprintf "if (typeof %s !== \"string\") %s;" acc (err "expected string") ]
  | Ir.SBool -> [ Printf.sprintf "if (typeof %s !== \"boolean\") %s;" acc (err "expected boolean") ]
  | Ir.SInt | Ir.SFloat ->
      let base = [ Printf.sprintf "if (typeof %s !== \"number\") %s;" acc (err "expected number") ] in
      (match range with
       | Some (lo, hi) ->
           base @ [ Printf.sprintf "if (%s < %s || %s > %s) %s;" acc (num lo) acc (num hi) (err "out of range") ]
       | None -> base)
  | Ir.SEnum opts ->
      let arr = "[" ^ String.concat ", " (List.map (fun o -> Yojson.Safe.to_string (`String o)) opts) ^ "]" in
      [ Printf.sprintf "if (!%s.includes(%s)) %s;" arr acc (err "invalid enum value") ]
  | Ir.SList t ->
      let inner = check_lines "v" t None label in
      [ Printf.sprintf "if (!Array.isArray(%s)) %s;" acc (err "expected array");
        Printf.sprintf "for (const v of %s) { %s }" acc (String.concat " " inner) ]

let gen_validator (tname : string) (fields : Ir.schema_field list) : string =
  let block (f : Ir.schema_field) =
    let acc = Printf.sprintf "x[%s]" (Yojson.Safe.to_string (`String f.Ir.fname)) in
    let lines = check_lines acc f.fty f.range f.fname in
    if f.required then
      let presence =
        Printf.sprintf "if (%s === undefined || %s === null) throw new Error(%s);" acc acc
          (Yojson.Safe.to_string (`String (f.fname ^ ": required")))
      in
      "  " ^ String.concat "\n  " (presence :: lines)
    else
      Printf.sprintf "  if (%s !== undefined && %s !== null) {\n    %s\n  }" acc acc
        (String.concat "\n    " lines)
  in
  Printf.sprintf "function validate%s(x: any): %s {\n%s\n  return x as %s;\n}" tname tname
    (String.concat "\n" (List.map block fields))
    tname
```

- [ ] **Step 4: Build and test — verify green**

Run: `dune build && dune runtest --force 2>&1 | grep -E "tests run|FAIL"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/codegen_ts.ml test/test_codegen.ml
git commit -m "feat(codegen): TS output type + zero-dep runtime validator emitter

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: `generate` — assemble the full `.ts` (per-target call)

**Files:**
- Modify: `lib/codegen_ts.ml`
- Test: `test/test_codegen.ml`

- [ ] **Step 1: Write the failing test**

Add to `test/test_codegen.ml` and register:

```ocaml
let gen src target =
  match Compile.frontend src with
  | Error _ -> Alcotest.fail "frontend failed"
  | Ok (checked, fragments) -> Codegen_ts.generate checked fragments ~target ~model:None

let test_generate_openai () =
  let src =
    {|agent "researcher" { input { ticker: string } goal "analyze {{ticker}}"
       output json { rating: enum("buy","sell") } }|}
  in
  let ts = gen src `OpenAI in
  Alcotest.(check bool) "inputs type" true (contains ts "export interface ResearcherInputs");
  Alcotest.(check bool) "output type" true (contains ts "export type ResearcherOutput");
  Alcotest.(check bool) "fn signature" true
    (contains ts "export async function researcher(inputs: ResearcherInputs");
  Alcotest.(check bool) "validator called" true (contains ts "validateResearcherOutput(");
  Alcotest.(check bool) "openai endpoint" true (contains ts "api.openai.com/v1/chat/completions");
  Alcotest.(check bool) "openai auth" true (contains ts "Authorization");
  Alcotest.(check bool) "interpolates input" true (contains ts "${inputs.ticker}")

let test_generate_text_and_providers () =
  let text_ts = gen {|agent "a" { goal "g" output markdown }|} `OpenAI in
  Alcotest.(check bool) "text returns string" true (contains text_ts "Promise<string>");
  Alcotest.(check bool) "text no validator" false (contains text_ts "function validate");
  let anth = gen {|agent "a" { goal "g" }|} `Anthropic in
  Alcotest.(check bool) "anthropic header" true (contains anth "x-api-key");
  Alcotest.(check bool) "anthropic version" true (contains anth "anthropic-version");
  let gem = gen {|agent "a" { goal "g" }|} `Gemini in
  Alcotest.(check bool) "gemini model in url" true (contains gem "models/gemini-2.5-flash:generateContent")
```

Register both: `Alcotest.test_case "generate openai" \`Quick test_generate_openai;` and `Alcotest.test_case "generate text+providers" \`Quick test_generate_text_and_providers;`

- [ ] **Step 2: Confirm it fails**

Run: `dune build 2>&1 | head -20` → expect `Codegen_ts.generate` unbound.

- [ ] **Step 3: Add `generate` (and a per-target call helper) to `lib/codegen_ts.ml`** (append)

```ocaml
(* --- inputs type --- *)

let ts_inputs_type (inputs : Sema.checked_input list) : string =
  if inputs = [] then "Record<string, never>"
  else
    let field (i : Sema.checked_input) =
      (* an input with a default is optional *)
      let opt = match i.Sema.ci_default with Some _ -> "?" | None -> "" in
      Printf.sprintf "%s%s: %s" i.Sema.ci_name opt (ts_of_ast_ty i.Sema.ci_ty)
    in
    "{ " ^ String.concat "; " (List.map field inputs) ^ " }"

(* --- per-target request + extraction --- *)

type target = [ `OpenAI | `Anthropic | `Gemini ]

(* (endpoint expr, header lines, extract expr for the reply text) *)
let call_pieces (target : target) (model : string) : string * string * string =
  match target with
  | `OpenAI ->
      ( "\"https://api.openai.com/v1/chat/completions\"",
        "      \"content-type\": \"application/json\",\n\
        \      \"Authorization\": `Bearer ${key}`,",
        "j.choices?.[0]?.message?.content" )
  | `Anthropic ->
      ( "\"https://api.anthropic.com/v1/messages\"",
        "      \"content-type\": \"application/json\",\n\
        \      \"x-api-key\": key,\n\
        \      \"anthropic-version\": \"2023-06-01\",",
        "(j.content ?? []).find((b: any) => b?.type === \"text\")?.text" )
  | `Gemini ->
      ( Printf.sprintf
          "`https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent?key=${key}`"
          model,
        "      \"content-type\": \"application/json\",",
        "j.candidates?.[0]?.content?.parts?.[0]?.text" )

let env_var = function
  | `OpenAI -> "OPENAI_API_KEY"
  | `Anthropic -> "ANTHROPIC_API_KEY"
  | `Gemini -> "GEMINI_API_KEY"

let generate (checked : Sema.checked) (fragments : Resolve.fragments) ~(target : target)
    ~(model : string option) : string =
  let ir = template_ir checked fragments in
  let default_model =
    match target with
    | `OpenAI -> Backend_openai.default_model
    | `Anthropic -> Backend_anthropic.default_model
    | `Gemini -> Backend_gemini.default_model
  in
  let model = match model with Some m -> m | None -> default_model in
  let request =
    match target with
    | `OpenAI -> Backend_openai.render ~no_content_user:"" ~model ir
    | `Anthropic -> Backend_anthropic.render ~no_content_user:"" ~model ir
    | `Gemini -> Backend_gemini.render ~no_content_user:"" ir
  in
  let pascal_name = pascal checked.Sema.name in
  let fn_name = camel checked.Sema.name in
  let in_t = Printf.sprintf "%sInputs" pascal_name in
  let out_t = Printf.sprintf "%sOutput" pascal_name in
  let out_ts = ts_output_type ir.Ir.out in
  let endpoint, headers, extract = call_pieces target model in
  let buf = Buffer.create 1024 in
  let p fmt = Printf.ksprintf (fun s -> Buffer.add_string buf s; Buffer.add_char buf '\n') fmt in
  p "// Generated by promptc — do not edit.";
  p "export interface %s %s" in_t (ts_inputs_type checked.Sema.inputs);
  p "export type %s = %s;" out_t out_ts;
  (* validator (typed json only) *)
  (match ir.Ir.out with
   | Ir.OJson (Some fields) -> p "%s" (gen_validator out_t fields)
   | _ -> ());
  p "export async function %s(inputs: %s, apiKey?: string): Promise<%s> {" fn_name in_t out_t;
  p "  const key = apiKey ?? (globalThis as any).process?.env?.%s ?? \"\";" (env_var target);
  p "  const body = %s;" (yojson_to_ts request);
  p "  const res = await fetch(%s, {" endpoint;
  p "    method: \"POST\",";
  p "    headers: {\n%s\n    }," headers;
  p "    body: JSON.stringify(body),";
  p "  });";
  p "  const j: any = await res.json();";
  p "  if (j.error) throw new Error(j.error.message ?? \"API error\");";
  p "  const text = %s;" extract;
  (match ir.Ir.out with
   | Ir.OJson (Some _) -> p "  return validate%s(JSON.parse(text));" out_t
   | Ir.OJson None -> p "  return JSON.parse(text);"
   | Ir.OText | Ir.OMarkdown -> p "  return text;");
  p "}";
  Buffer.contents buf
```

- [ ] **Step 4: Build and test — verify green**

Run: `dune build && dune runtest --force 2>&1 | grep -E "tests run|FAIL"` then `bash scripts/check-corpus.sh`
Expected: PASS — both `generate` cases pass; corpus `25/25`.

- [ ] **Step 5: Commit**

```bash
git add lib/codegen_ts.ml test/test_codegen.ml
git commit -m "feat(codegen): generate assembles the full typed TS client per target

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: CLI wiring (`codegen` command) + cram golden

**Files:**
- Modify: `lib/driver.ml`
- Modify: `bin/main.ml`
- Create: `test/cram/codegen.t`

- [ ] **Step 1: Add the failing cram**

Create `test/cram/codegen.t`:

```
Generate a typed TypeScript client (OpenAI default target):

  $ promptc codegen researcher.prompt | head -3

Codegen for a bad target is a usage error:

  $ promptc codegen researcher.prompt --target bogus
  [124]
```

(The first command's output is filled by auto-promote in Step 5; the second asserts the cmdliner enum rejects an unknown target.)

- [ ] **Step 2: Confirm it fails**

Run: `dune runtest 2>&1 | grep -A3 codegen | head -20`
Expected: FAIL — `codegen` is an unknown subcommand.

- [ ] **Step 3: Add `run_codegen` to `lib/driver.ml`** (append after `run_compile`)

```ocaml
let run_codegen (file : string) (target : [ `OpenAI | `Anthropic | `Gemini ])
    (model : string option) (output : string option) : int =
  match read_file file with
  | exception Sys_error msg -> prerr_endline msg; 2
  | src -> (
      let resolver = fs_resolver (Filename.dirname file) in
      match Compile.frontend ~resolver src with
      | Error ds -> print_diags file ds; 1
      | Ok (checked, fragments) ->
          let ts = Codegen_ts.generate checked fragments ~target ~model in
          (match output with
           | None -> print_string ts
           | Some path ->
               let oc = open_out path in
               output_string oc ts;
               close_out oc);
          0)
```

- [ ] **Step 4: Add the `codegen` command to `bin/main.ml`**

Add an output arg after `model_arg`:

```ocaml
let output_arg =
  let doc = "Write generated code to FILE instead of stdout." in
  Arg.(value & opt (some string) None & info [ "output"; "o" ] ~docv:"FILE" ~doc)
```

Add the command (after `run_cmd`):

```ocaml
let codegen_cmd =
  let doc = "Generate a typed TypeScript client for a .prompt file." in
  let term = Term.(const Driver.run_codegen $ file_arg $ target_arg $ model_arg $ output_arg) in
  Cmd.v (Cmd.info "codegen" ~doc) term
```

Register it in the group:

```ocaml
  exit (Cmd.eval' (Cmd.group info [ compile_cmd; check_cmd; run_cmd; codegen_cmd ]))
```

- [ ] **Step 5: Capture the golden + verify**

Run: `dune runtest --auto-promote 2>&1 | tail -3`, then `dune runtest` again (must be clean).
Then read `test/cram/codegen.t` and confirm the first block shows the generated header + `export interface ResearcherInputs` lines (researcher.prompt is `output markdown`, so the function returns `Promise<string>`).

- [ ] **Step 6: Manual TypeScript type-check (local only; not a CI test)**

Run (node/tsc is available locally; this is a one-time correctness check, NOT committed to the suite since CI has no node):
```bash
dune build
./_build/default/bin/main.exe codegen test/cram/researcher.prompt --target openai -o /tmp/researcher.ts
npx --yes tsc --noEmit --strict --lib es2022,dom /tmp/researcher.ts && echo "TS OK"
# also try a typed-json agent:
printf 'agent "r" { input { ticker: string } goal "rate {{ticker}}" output json { rating: enum("buy","hold","sell") score: int(0..100) tags: list<string> } }\n' > /tmp/r.prompt
./_build/default/bin/main.exe codegen /tmp/r.prompt --target anthropic -o /tmp/r.ts
npx --yes tsc --noEmit --strict --lib es2022,dom /tmp/r.ts && echo "TS OK (typed)"
```
Expected: both print `TS OK`. If `tsc` reports an error, fix the generator (do not weaken the test). If `node`/`tsc` is unavailable in your environment, skip this step and rely on the unit + golden tests.

- [ ] **Step 7: Corpus guard**

Run: `bash scripts/check-corpus.sh`
Expected: `25/25`.

- [ ] **Step 8: Commit**

```bash
git add lib/driver.ml bin/main.ml test/cram/codegen.t
git commit -m "feat(cli): promptc codegen — emit a typed TypeScript client

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review (completed by plan author)

**Spec coverage:**
- `codegen` command with `--target`/`--model`/`-o`, default openai/stdout — Task 5. ✔
- Hook after `frontend`; template `Bind.bound` with fragments resolved + input holes; `Lower.lower`; `Backend_<p>.render ~no_content_user:""` — Task 1 (`template_ir`) + Task 4 (`generate`). ✔
- Type mapping (enum union, list `[]`, optional `?`, text→string, bare json→unknown) — Tasks 1 + 3. ✔
- Zero-dep runtime validator (required/type/enum/list/range, throws) — Task 3. ✔
- Request body as TS literal with `{{name}}`→`${inputs.name}` — Task 2. ✔
- Per-provider endpoint/headers/extract; Gemini model in URL; `--model` override — Task 4 (`call_pieces`, `generate`). ✔
- Zero-dep client: `fetch` + `apiKey` param defaulting to `(globalThis as any).process?.env?.<KEY>` (type-checks without `@types/node`) — Task 4. ✔
- Testing: unit (mapping/validator/generate), cram golden, manual `tsc` check, corpus 25/25 — Tasks 1–5. ✔

**Placeholder scan:** No TBD/TODO; every code step shows complete OCaml/TS. The cram first-block output is captured via the repo's standard `--auto-promote` (Step 5), with an explicit read-and-verify and a separate hand-written exit-code assertion.

**Type consistency:** `target = [ \`OpenAI | \`Anthropic | \`Gemini ]` matches the cmdliner `target_arg` enum and `run_codegen`. `Codegen_ts.generate checked fragments ~target ~model` is called identically in the unit test (`gen`) and the driver. `ts_of_schema_ty`/`ts_of_ast_ty`/`ts_output_type`/`gen_validator`/`yojson_to_ts`/`template_ir`/`pascal`/`camel` names are consistent across tasks and tests. Reused `Backend_<p>.render`/`default_model` signatures match the model-selection cut (OpenAI/Anthropic take `?model`; Gemini does not — model goes in the URL via `call_pieces`).
