# Multi-Backend (Anthropic + Gemini compile targets) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `promptc compile <file> --target openai|anthropic|gemini`, emitting a valid request body for the chosen provider; OpenAI stays the default and its output is unchanged.

**Architecture:** `Ir.t` is provider-agnostic. Extract the provider-neutral JSON helpers into a new `Backend_common`, add two sibling renderers (`Backend_anthropic`, `Backend_gemini`), and thread a `target` polymorphic-variant through `Compile.compile_string` → `Driver.run_compile` → a cmdliner `--target` flag. `run` is untouched (OpenAI-only this cut).

**Tech Stack:** OCaml 5.4, dune, Menhir/ocamllex (unchanged here), yojson (`Yojson.Safe.t`), cmdliner, alcotest, cram. Warning-8 (non-exhaustive match) is an error, so every `match ir.out`/`schema_ty` must cover all variants.

**Spec:** `docs/superpowers/specs/2026-06-17-multi-backend-design.md`

**Conventions for the implementer:**
- Build: `dune build`. Unit tests: `dune test` (or `dune runtest`). The `test_promptdsl` executable auto-includes every `.ml` in `test/`; suites are registered in `test/test_promptdsl.ml`.
- The `promptdsl` library (`lib/dune`) has no explicit `modules` field, so new `lib/*.ml` files are picked up automatically — **no dune edits needed**.
- Cram goldens are captured, not hand-written: add the command lines, then run `dune runtest --auto-promote` to fill the expected output, then read the captured block and verify it matches the spec before committing.
- Corpus guard: `bash scripts/check-corpus.sh` must stay 25/25.

---

## File Structure

- `lib/backend_common.ml` (NEW) — provider-neutral helpers lifted out of `backend_openai.ml`: `user_message`, lowercase `json_of_ty`, `with_range`, and `schema_object` (the `{type:object, properties, required, additionalProperties:false}` builder shared by OpenAI + Anthropic).
- `lib/backend_openai.ml` (MODIFY) — re-expressed in terms of `Backend_common`; output byte-identical.
- `lib/backend_anthropic.ml` (NEW) — `render : Ir.t -> Yojson.Safe.t` → Anthropic Messages body.
- `lib/backend_gemini.ml` (NEW) — `render : Ir.t -> Yojson.Safe.t` → Gemini `generateContent` body, with its own UPPERCASE type map.
- `lib/compile.ml` (MODIFY) — `compile_string` gains `?target` and dispatches the JSON renderer.
- `lib/driver.ml` (MODIFY) — `run_compile` gains a `target` parameter.
- `bin/main.ml` (MODIFY) — `compile` gains `--target`.
- `test/test_backends.ml` (MODIFY) — unit tests for the two new backends + the shared builder.
- `test/cram/target.t` (NEW) — golden goldens for `--target anthropic` / `--target gemini` and the default regression.

---

## Task 1: Extract `Backend_common`, refactor OpenAI (no behavior change)

**Files:**
- Create: `lib/backend_common.ml`
- Modify: `lib/backend_openai.ml`
- Test: `test/test_backends.ml`

- [ ] **Step 1: Write a failing test for the shared schema builder**

Add to `test/test_backends.ml` (anywhere above `let suite`):

```ocaml
(* Backend_common.schema_object builds the lowercase JSON-Schema object shared
   by OpenAI and Anthropic. *)
let test_common_schema_object () =
  let open Yojson.Safe.Util in
  let fields =
    [ { Ir.fname = "rating"; fty = Ir.SEnum [ "buy"; "sell" ]; required = true; range = None };
      { Ir.fname = "note"; fty = Ir.SString; required = false; range = None } ]
  in
  let s = Backend_common.schema_object fields in
  Alcotest.(check string) "object type" "object" (s |> member "type" |> to_string);
  Alcotest.(check bool) "additionalProperties false" false
    (s |> member "additionalProperties" |> to_bool);
  Alcotest.(check (list string)) "required" [ "rating" ]
    (s |> member "required" |> to_list |> List.map to_string);
  Alcotest.(check string) "enum is lowercase string" "string"
    (s |> member "properties" |> member "rating" |> member "type" |> to_string)
```

Register it in the `suite` list:

```ocaml
      Alcotest.test_case "common schema_object" `Quick test_common_schema_object;
```

- [ ] **Step 2: Run the build to confirm it fails**

Run: `dune build 2>&1 | head -20`
Expected: FAIL — `Unbound module Backend_common`.

- [ ] **Step 3: Create `lib/backend_common.ml`**

```ocaml
open Ir

(* The user message / first content part: the agent's bound @content, or the
   placeholder for an agent with no input. Shared by every backend. *)
let user_message ?(no_content_user = "{{input}}") (ir : Ir.t) : string =
  match ir.content with None -> no_content_user | Some s -> s

(* Standard (lowercase) JSON Schema type for a field type. *)
let rec json_of_ty = function
  | SString -> `Assoc [ ("type", `String "string") ]
  | SInt -> `Assoc [ ("type", `String "integer") ]
  | SBool -> `Assoc [ ("type", `String "boolean") ]
  | SFloat -> `Assoc [ ("type", `String "number") ]
  | SEnum opts ->
      `Assoc
        [ ("type", `String "string");
          ("enum", `List (List.map (fun s -> `String s) opts)) ]
  | SList t -> `Assoc [ ("type", `String "array"); ("items", json_of_ty t) ]

(* Append minimum/maximum to a property when the field has a range. Integer
   bounds are emitted as JSON integers, others as numbers. Provider-neutral:
   reused verbatim by the Gemini backend. *)
let with_range (f : Ir.schema_field) (base : Yojson.Safe.t) : Yojson.Safe.t =
  match (f.range, base) with
  | None, _ -> base
  | Some (lo, hi), `Assoc kvs ->
      let num v = match f.fty with Ir.SInt -> `Int (int_of_float v) | _ -> `Float v in
      `Assoc (kvs @ [ ("minimum", num lo); ("maximum", num hi) ])
  | Some _, j -> j

(* The {type:object, properties, required, additionalProperties:false} object,
   shared by OpenAI's response_format and Anthropic's output_config.format. *)
let schema_object (fields : Ir.schema_field list) : Yojson.Safe.t =
  let props =
    List.map (fun (f : Ir.schema_field) -> (f.fname, with_range f (json_of_ty f.fty))) fields
  in
  let required =
    List.filter_map
      (fun (f : Ir.schema_field) -> if f.required then Some (`String f.fname) else None)
      fields
  in
  `Assoc
    [ ("type", `String "object");
      ("properties", `Assoc props);
      ("required", `List required);
      ("additionalProperties", `Bool false) ]
```

- [ ] **Step 4: Refactor `lib/backend_openai.ml` to use `Backend_common`**

Replace the entire file contents with:

```ocaml
open Ir

let response_format (fields : Ir.schema_field list) : Yojson.Safe.t =
  `Assoc
    [ ("type", `String "json_schema");
      ( "json_schema",
        `Assoc
          [ ("name", `String "output");
            ("schema", Backend_common.schema_object fields) ] ) ]

let render ?(no_content_user = "{{input}}") (ir : Ir.t) : Yojson.Safe.t =
  let base =
    [ ("model", `String "gpt-4o-mini");
      ( "messages",
        `List
          [ `Assoc
              [ ("role", `String "system");
                ("content", `String (Backend_prose.render ir)) ];
            `Assoc
              [ ("role", `String "user");
                ("content", `String (Backend_common.user_message ~no_content_user ir)) ] ] ) ]
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

- [ ] **Step 5: Run the build and full test suite — verify green and byte-identical**

Run: `dune build && dune test 2>&1 | tail -20`
Expected: PASS — the new `common schema_object` case passes AND every existing OpenAI/prose/run case still passes (the OpenAI request is unchanged). Also run `bash scripts/check-corpus.sh` → `25/25`.

- [ ] **Step 6: Commit**

```bash
git add lib/backend_common.ml lib/backend_openai.ml test/test_backends.ml
git commit -m "refactor(backend): extract Backend_common (user_message, schema_object)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: `Backend_anthropic`

**Files:**
- Create: `lib/backend_anthropic.ml`
- Test: `test/test_backends.ml`

- [ ] **Step 1: Write the failing tests**

Add to `test/test_backends.ml`:

```ocaml
(* Anthropic Messages body: top-level system, single user message, model +
   max_tokens, output_config.format only for a typed schema. *)
let test_anthropic () =
  let open Yojson.Safe.Util in
  let j = Backend_anthropic.render sample_ir in
  Alcotest.(check string) "model" "claude-haiku-4-5-20251001"
    (j |> member "model" |> to_string);
  Alcotest.(check int) "max_tokens" 1024 (j |> member "max_tokens" |> to_int);
  Alcotest.(check bool) "system is top-level" true (has_member j "system");
  let roles =
    j |> member "messages" |> to_list
    |> List.map (fun m -> m |> member "role" |> to_string)
  in
  Alcotest.(check (list string)) "only a user message" [ "user" ] roles;
  Alcotest.(check string) "format type" "json_schema"
    (j |> member "output_config" |> member "format" |> member "type" |> to_string);
  let schema = j |> member "output_config" |> member "format" |> member "schema" in
  Alcotest.(check bool) "additionalProperties present (shared builder)" true
    (has_member schema "additionalProperties");
  Alcotest.(check string) "enum is lowercase string" "string"
    (schema |> member "properties" |> member "rating" |> member "type" |> to_string)

let test_anthropic_gating () =
  Alcotest.(check bool) "text: no output_config" false
    (has_member (Backend_anthropic.render (ir_with Ir.OText)) "output_config");
  Alcotest.(check bool) "markdown: no output_config" false
    (has_member (Backend_anthropic.render (ir_with Ir.OMarkdown)) "output_config");
  Alcotest.(check bool) "bare json: no output_config" false
    (has_member (Backend_anthropic.render (ir_with (Ir.OJson None))) "output_config")

let test_anthropic_no_content () =
  let open Yojson.Safe.Util in
  let j = Backend_anthropic.render (ir_with Ir.OText) in
  let u =
    j |> member "messages" |> to_list |> List.hd |> member "content" |> to_string
  in
  Alcotest.(check string) "no-content user is placeholder" "{{input}}" u
```

Register in `suite`:

```ocaml
      Alcotest.test_case "anthropic" `Quick test_anthropic;
      Alcotest.test_case "anthropic gating" `Quick test_anthropic_gating;
      Alcotest.test_case "anthropic no content" `Quick test_anthropic_no_content;
```

- [ ] **Step 2: Run the build to confirm it fails**

Run: `dune build 2>&1 | head -20`
Expected: FAIL — `Unbound module Backend_anthropic`.

- [ ] **Step 3: Create `lib/backend_anthropic.ml`**

```ocaml
open Ir

(* https://api.anthropic.com/v1/messages
   Headers (not part of this body): content-type: application/json,
   anthropic-version: 2023-06-01, x-api-key: $ANTHROPIC_API_KEY. *)

(* Structured output uses the current production output_config.format
   (no beta header); schema is standard lowercase JSON Schema, shared with OpenAI. *)
let output_config (fields : Ir.schema_field list) : Yojson.Safe.t =
  `Assoc
    [ ( "format",
        `Assoc
          [ ("type", `String "json_schema");
            ("schema", Backend_common.schema_object fields) ] ) ]

let render (ir : Ir.t) : Yojson.Safe.t =
  let base =
    [ ("model", `String "claude-haiku-4-5-20251001");
      ("max_tokens", `Int 1024);
      ("system", `String (Backend_prose.render ir));
      ( "messages",
        `List
          [ `Assoc
              [ ("role", `String "user");
                ("content", `String (Backend_common.user_message ir)) ] ] ) ]
  in
  let fields =
    match ir.out with
    | OJson (Some fields) -> base @ [ ("output_config", output_config fields) ]
    | OJson None | OText | OMarkdown -> base
  in
  `Assoc fields
```

- [ ] **Step 4: Run the build and tests — verify green**

Run: `dune build && dune test 2>&1 | tail -20`
Expected: PASS — the three anthropic cases pass; everything else stays green.

- [ ] **Step 5: Commit**

```bash
git add lib/backend_anthropic.ml test/test_backends.ml
git commit -m "feat(backend): Anthropic Messages request renderer

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: `Backend_gemini`

**Files:**
- Create: `lib/backend_gemini.ml`
- Test: `test/test_backends.ml`

- [ ] **Step 1: Write the failing tests**

Add to `test/test_backends.ml`:

```ocaml
(* Gemini generateContent body: systemInstruction/contents use parts[].text,
   responseSchema uses UPPERCASE types and has no additionalProperties, and the
   model is NOT in the body (it lives in the URL). *)
let test_gemini () =
  let open Yojson.Safe.Util in
  let j = Backend_gemini.render sample_ir in
  let sys =
    j |> member "systemInstruction" |> member "parts" |> to_list |> List.hd
    |> member "text" |> to_string
  in
  Alcotest.(check bool) "system carries the goal" true (contains sys "Goal: analyze TSLA");
  Alcotest.(check bool) "no model field in body" false (has_member j "model");
  let gc = j |> member "generationConfig" in
  Alcotest.(check string) "mime" "application/json"
    (gc |> member "responseMimeType" |> to_string);
  let schema = gc |> member "responseSchema" in
  Alcotest.(check string) "object UPPERCASE" "OBJECT" (schema |> member "type" |> to_string);
  Alcotest.(check string) "enum UPPERCASE STRING" "STRING"
    (schema |> member "properties" |> member "rating" |> member "type" |> to_string);
  Alcotest.(check bool) "no additionalProperties" false
    (has_member schema "additionalProperties")

let test_gemini_gating () =
  let open Yojson.Safe.Util in
  Alcotest.(check bool) "text: no generationConfig" false
    (has_member (Backend_gemini.render (ir_with Ir.OText)) "generationConfig");
  Alcotest.(check bool) "markdown: no generationConfig" false
    (has_member (Backend_gemini.render (ir_with Ir.OMarkdown)) "generationConfig");
  let gc = Backend_gemini.render (ir_with (Ir.OJson None)) |> member "generationConfig" in
  Alcotest.(check string) "bare json: mime only" "application/json"
    (gc |> member "responseMimeType" |> to_string);
  Alcotest.(check bool) "bare json: no responseSchema" false
    (has_member gc "responseSchema")

let test_gemini_range_and_list () =
  let open Yojson.Safe.Util in
  let ir =
    { Ir.agent_name = "a"; objective = "g"; instructions = [];
      out = Ir.OJson (Some [
        { Ir.fname = "score"; fty = Ir.SInt; required = true; range = Some (0., 100.) };
        { Ir.fname = "tags"; fty = Ir.SList Ir.SString; required = false; range = None } ]);
      content = None }
  in
  let props =
    Backend_gemini.render ir |> member "generationConfig" |> member "responseSchema"
    |> member "properties"
  in
  Alcotest.(check string) "int UPPERCASE" "INTEGER"
    (props |> member "score" |> member "type" |> to_string);
  Alcotest.(check int) "min" 0 (props |> member "score" |> member "minimum" |> to_int);
  Alcotest.(check int) "max" 100 (props |> member "score" |> member "maximum" |> to_int);
  Alcotest.(check string) "list UPPERCASE ARRAY" "ARRAY"
    (props |> member "tags" |> member "type" |> to_string);
  Alcotest.(check string) "items UPPERCASE STRING" "STRING"
    (props |> member "tags" |> member "items" |> member "type" |> to_string)
```

Register in `suite`:

```ocaml
      Alcotest.test_case "gemini" `Quick test_gemini;
      Alcotest.test_case "gemini gating" `Quick test_gemini_gating;
      Alcotest.test_case "gemini range and list" `Quick test_gemini_range_and_list;
```

- [ ] **Step 2: Run the build to confirm it fails**

Run: `dune build 2>&1 | head -20`
Expected: FAIL — `Unbound module Backend_gemini`.

- [ ] **Step 3: Create `lib/backend_gemini.ml`**

```ocaml
open Ir

(* POST https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$GEMINI_API_KEY
   The model is in the URL, so it is NOT part of this body. *)

(* Gemini responseSchema uses UPPERCASE OpenAPI-style type names. *)
let rec gemini_of_ty = function
  | SString -> `Assoc [ ("type", `String "STRING") ]
  | SInt -> `Assoc [ ("type", `String "INTEGER") ]
  | SBool -> `Assoc [ ("type", `String "BOOLEAN") ]
  | SFloat -> `Assoc [ ("type", `String "NUMBER") ]
  | SEnum opts ->
      `Assoc
        [ ("type", `String "STRING");
          ("enum", `List (List.map (fun s -> `String s) opts)) ]
  | SList t -> `Assoc [ ("type", `String "ARRAY"); ("items", gemini_of_ty t) ]

(* No additionalProperties (Gemini's schema subset does not support it);
   minimum/maximum are the same as everywhere, so reuse Backend_common.with_range. *)
let gemini_schema_object (fields : Ir.schema_field list) : Yojson.Safe.t =
  let props =
    List.map
      (fun (f : Ir.schema_field) ->
        (f.fname, Backend_common.with_range f (gemini_of_ty f.fty)))
      fields
  in
  let required =
    List.filter_map
      (fun (f : Ir.schema_field) -> if f.required then Some (`String f.fname) else None)
      fields
  in
  `Assoc
    [ ("type", `String "OBJECT");
      ("properties", `Assoc props);
      ("required", `List required) ]

let render (ir : Ir.t) : Yojson.Safe.t =
  let base =
    [ ( "systemInstruction",
        `Assoc [ ("parts", `List [ `Assoc [ ("text", `String (Backend_prose.render ir)) ] ]) ] );
      ( "contents",
        `List
          [ `Assoc
              [ ("role", `String "user");
                ( "parts",
                  `List [ `Assoc [ ("text", `String (Backend_common.user_message ir)) ] ] ) ] ] ) ]
  in
  let gen_config =
    match ir.out with
    | OJson (Some fields) ->
        Some
          (`Assoc
             [ ("responseMimeType", `String "application/json");
               ("responseSchema", gemini_schema_object fields) ])
    | OJson None -> Some (`Assoc [ ("responseMimeType", `String "application/json") ])
    | OText | OMarkdown -> None
  in
  let fields =
    match gen_config with Some g -> base @ [ ("generationConfig", g) ] | None -> base
  in
  `Assoc fields
```

- [ ] **Step 4: Run the build and tests — verify green**

Run: `dune build && dune test 2>&1 | tail -20`
Expected: PASS — the three gemini cases pass; everything else stays green.

- [ ] **Step 5: Commit**

```bash
git add lib/backend_gemini.ml test/test_backends.ml
git commit -m "feat(backend): Gemini generateContent request renderer

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Wire `--target` through compile → driver → CLI, plus cram

**Files:**
- Modify: `lib/compile.ml:48-56` (`compile_string`)
- Modify: `lib/driver.ml:65-89` (`run_compile`)
- Modify: `bin/main.ml`
- Create: `test/cram/target.t`
- Test: `test/test_backends.ml`

- [ ] **Step 1: Write a failing unit test for `compile_string ~target`**

Add to `test/test_backends.ml`:

```ocaml
(* compile_string dispatches the JSON renderer by target; prose is unchanged. *)
let test_compile_string_target () =
  let open Yojson.Safe.Util in
  let src = {|agent "r" { goal "g" output json { x: string } }|} in
  let model outcome =
    match outcome with
    | Compile.Failure _ -> Alcotest.fail "unexpected failure"
    | Compile.Success o -> o.Compile.json
  in
  let oa = model (Compile.compile_string ~target:`OpenAI src) in
  Alcotest.(check string) "openai model" "gpt-4o-mini" (oa |> member "model" |> to_string);
  let an = model (Compile.compile_string ~target:`Anthropic src) in
  Alcotest.(check string) "anthropic model" "claude-haiku-4-5-20251001"
    (an |> member "model" |> to_string);
  let ge = model (Compile.compile_string ~target:`Gemini src) in
  Alcotest.(check bool) "gemini has contents" true (has_member ge "contents");
  (* default target is OpenAI *)
  let def = model (Compile.compile_string src) in
  Alcotest.(check string) "default model" "gpt-4o-mini" (def |> member "model" |> to_string)
```

Register in `suite`:

```ocaml
      Alcotest.test_case "compile_string target" `Quick test_compile_string_target;
```

- [ ] **Step 2: Run the build to confirm it fails**

Run: `dune build 2>&1 | head -20`
Expected: FAIL — `compile_string` has no `~target` label (type error / unknown label).

- [ ] **Step 3: Add `?target` to `compile_string` in `lib/compile.ml`**

Replace the `compile_string` function (currently `lib/compile.ml:48-56`) with:

```ocaml
let compile_string ?(values = []) ?(resolver = default_resolver)
    ?(target : [ `OpenAI | `Anthropic | `Gemini ] = `OpenAI) (src : string) : outcome =
  match frontend ~resolver src with
  | Error ds -> Failure ds
  | Ok (checked, fragments) -> (
      match Bind.bind ~fragments checked values with
      | Error ds -> Failure ds
      | Ok bound ->
          let ir = Lower.lower bound in
          let json =
            match target with
            | `OpenAI -> Backend_openai.render ir
            | `Anthropic -> Backend_anthropic.render ir
            | `Gemini -> Backend_gemini.render ir
          in
          Success { prose = Backend_prose.render ir; json })
```

(`compile_request`, used by `run`, is unchanged — it stays OpenAI-only.)

- [ ] **Step 4: Run unit tests — verify green**

Run: `dune build && dune test 2>&1 | tail -20`
Expected: PASS — `compile_string target` passes; all others green.

- [ ] **Step 5: Thread `target` through `Driver.run_compile`**

In `lib/driver.ml`, change the signature and the `compile_string` call. Replace the header line of `run_compile`:

```ocaml
let run_compile (file : string) (emit : [ `Prose | `Json | `Both ]) (sets : string list)
    (target : [ `OpenAI | `Anthropic | `Gemini ]) : int =
```

and inside it replace the `Compile.compile_string ~values ~resolver src` call with:

```ocaml
          match Compile.compile_string ~values ~resolver ~target src with
```

(Everything else in `run_compile` is unchanged.)

- [ ] **Step 6: Add the `--target` flag in `bin/main.ml`**

Add a converter + arg near `emit_conv`/`emit_arg`:

```ocaml
let target_conv =
  Arg.enum [ ("openai", `OpenAI); ("anthropic", `Anthropic); ("gemini", `Gemini) ]

let target_arg =
  let doc = "Which provider request to emit: openai (default), anthropic, or gemini." in
  Arg.(value & opt target_conv `OpenAI & info [ "target" ] ~docv:"PROVIDER" ~doc)
```

and extend the `compile_cmd` term to pass it (note the argument order must match `run_compile`):

```ocaml
let compile_cmd =
  let doc = "Compile a .prompt file to a prompt and/or a provider request." in
  let term = Term.(const Driver.run_compile $ file_arg $ emit_arg $ set_arg $ target_arg) in
  Cmd.v (Cmd.info "compile" ~doc) term
```

- [ ] **Step 7: Build and smoke-test the CLI**

Run:
```bash
dune build && \
./_build/default/bin/main.exe compile test/cram/researcher.prompt --target anthropic --emit json | head -3 && \
./_build/default/bin/main.exe compile test/cram/researcher.prompt --target gemini --emit json | head -3 && \
./_build/default/bin/main.exe compile test/cram/researcher.prompt --emit json | head -2
```
Expected: the anthropic output starts with `"model": "claude-haiku-4-5-20251001"`; the gemini output starts with `"systemInstruction"`; the default starts with `"model": "gpt-4o-mini"`. An invalid `--target foo` exits non-zero with a cmdliner usage error (try it: `./_build/default/bin/main.exe compile test/cram/researcher.prompt --target foo; echo $?` → non-zero).

- [ ] **Step 8: Add the cram golden file**

Create `test/cram/target.t` with just the command lines (leave the output to auto-promote):

```
The Anthropic Messages request for a typed-json agent:

  $ promptc compile researcher.prompt --target anthropic --emit json

The Gemini generateContent request:

  $ promptc compile researcher.prompt --target gemini --emit json

The default target is still OpenAI:

  $ promptc compile researcher.prompt --emit json | head -2
```

- [ ] **Step 9: Capture and verify the golden output**

Run: `dune runtest --auto-promote 2>&1 | tail -5` then `dune runtest` (second run must be clean).
Then **read `test/cram/target.t`** and verify against the spec:
- anthropic block: top-level `"model": "claude-haiku-4-5-20251001"`, `"max_tokens": 1024`, top-level `"system"`, a single `"role": "user"` message with `"content": "{{input}}"`, and `"output_config"` → `"format"` → `"type": "json_schema"` with a lowercase-typed `schema` that has `"additionalProperties": false`.
- gemini block: `"systemInstruction"` with `parts[].text`, `"contents"` with a user `parts[].text` of `"{{input}}"`, `"generationConfig"` with `"responseMimeType": "application/json"` and a `"responseSchema"` whose `"type"` is `"OBJECT"` and whose `rating` property type is `"STRING"`; **no** `"model"` key anywhere in the body.
- default block: first two lines are `{` and `  "model": "gpt-4o-mini",`.

If anything is off, fix the backend and re-run `dune runtest --auto-promote`.

- [ ] **Step 10: Corpus regression guard**

Run: `bash scripts/check-corpus.sh`
Expected: `25/25` valid (default target is unchanged, so the corpus is unaffected).

- [ ] **Step 11: Commit**

```bash
git add lib/compile.ml lib/driver.ml bin/main.ml test/test_backends.ml test/cram/target.t
git commit -m "feat(cli): compile --target openai|anthropic|gemini

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review (completed by plan author)

**Spec coverage:**
- Both targets added (Tasks 2, 3); `--target` flag with `openai` default (Task 4) — ✔ Decisions: Targets, Flag.
- Default models `gpt-4o-mini` / `claude-haiku-4-5-20251001` / `gemini-2.5-flash` — ✔ (Tasks 1/2/3 literals; gemini's is in the URL comment + cram verification).
- Anthropic `max_tokens: 1024` — ✔ Task 2.
- Prose backend untouched, used as system text for all three — ✔ (all renders call `Backend_prose.render`).
- Structured output per provider incl. text/untyped-json gating — ✔ (Tasks 2/3 gating tests; spec rules matched).
- Type→schema mapping incl. enum/list/range, lowercase vs UPPERCASE, additionalProperties present/absent — ✔ (Tasks 1/3 + unit tests).
- `--emit` interaction (json/both emit target body; prose target-independent) — ✔ (compile_string only swaps `json`; prose unchanged).
- `check`/`run` unchanged, run stays OpenAI — ✔ (compile_request untouched; no `--target` on run/check).
- Error handling via cmdliner enum — ✔ Task 4 Step 7 verifies non-zero on bad value.
- Testing: per-backend unit (text/untyped/typed/no-content), OpenAI refactor guard, cram goldens, corpus 25/25 — ✔ Tasks 1–4.

**Placeholder scan:** No TBD/TODO; every code step shows complete code; cram output is captured via the repo's standard `--auto-promote` with an explicit verification checklist (not a vague "write tests").

**Type consistency:** `target` is the same polymorphic variant `[ `OpenAI | `Anthropic | `Gemini ]` in `compile_string`, `run_compile`, and the cmdliner enum. `Backend_common.{user_message,json_of_ty,with_range,schema_object}` names match across Tasks 1–4. `render` signatures: OpenAI `?no_content_user`, Anthropic/Gemini `Ir.t -> Yojson.Safe.t` (consistent with spec Components and with `compile_string`'s calls, which use defaults).
