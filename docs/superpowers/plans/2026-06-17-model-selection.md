# Model Selection (`--model`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `compile`/`run --target <p> --model <id>` override the per-target default model; omitting `--model` reproduces today's output exactly.

**Architecture:** Lift each provider's hardcoded model into an exposed `Backend_*.default_model` constant. `Backend_{openai,anthropic}.render` gain `?model` (body field); Gemini's body has no model, so the constant only feeds the runtime URL. `compile_string`/`compile_request` gain `?model`; the `Runtime` provider record gains `default_model` and an `endpoint ~model:~api_key:`; `run_run` resolves `cli ?? default` and threads it into the body and the Gemini URL. A `--model` cmdliner flag drives both commands.

**Tech Stack:** OCaml 5.4, dune, yojson, cmdliner, alcotest, cram. warning-8 (non-exhaustive match) is an error.

**Spec:** `docs/superpowers/specs/2026-06-17-model-selection-design.md`

**OCaml note for the implementer:** an optional parameter `?model` may be supplied at a call site either as `~model:v` (bare value, auto-wrapped to `Some v`) or `?model:opt` (forward an existing `string option`). Both are used below.

**Conventions:** Build `dune build`; tests `dune runtest --force 2>&1 | grep -E "tests run|FAIL"`; corpus `bash scripts/check-corpus.sh` (stay `25/25`). The `promptdsl` library auto-includes `lib/*.ml` — no dune edits.

---

## File Structure

- `lib/backend_openai.ml`, `lib/backend_anthropic.ml` (MODIFY) — add `default_model` constant; `render` gains `?model` for the body.
- `lib/backend_gemini.ml` (MODIFY) — add `default_model` constant only (`render` unchanged; body has no model).
- `lib/compile.ml` (MODIFY) — `compile_string` + `compile_request` gain `?model`, forwarded to the OpenAI/Anthropic renderers.
- `lib/runtime.ml` (MODIFY) — provider record gains `default_model`; `endpoint` becomes `~model:~api_key:`; `curl_transport` gains `~model`.
- `lib/driver.ml` (MODIFY) — Task 3 pins `run_run` to the default model; Task 4 adds the `--model` params to `run_run` and `run_compile`.
- `bin/main.ml` (MODIFY) — add `model_arg`, wire into both commands.
- `test/test_backends.ml`, `test/test_runtime.ml` (MODIFY) — unit tests.
- `test/cram/emit.t` (MODIFY) — a `--model` golden.

---

## Task 1: Backend `default_model` constants + `?model` on the body renderers

**Files:**
- Modify: `lib/backend_openai.ml`, `lib/backend_anthropic.ml`, `lib/backend_gemini.ml`
- Test: `test/test_backends.ml`

- [ ] **Step 1: Write the failing test**

Add to `test/test_backends.ml` above `let suite` (`ir_with` already exists):

```ocaml
(* --model overrides the body model for OpenAI/Anthropic; Gemini exposes the
   default as a constant (its body carries no model). *)
let test_model_override () =
  let open Yojson.Safe.Util in
  let ir = ir_with Ir.OText in
  Alcotest.(check string) "openai default" "gpt-4o-mini"
    (Backend_openai.render ir |> member "model" |> to_string);
  Alcotest.(check string) "openai override" "gpt-4o"
    (Backend_openai.render ~model:"gpt-4o" ir |> member "model" |> to_string);
  Alcotest.(check string) "anthropic default" "claude-haiku-4-5-20251001"
    (Backend_anthropic.render ir |> member "model" |> to_string);
  Alcotest.(check string) "anthropic override" "claude-opus-4-8"
    (Backend_anthropic.render ~model:"claude-opus-4-8" ir |> member "model" |> to_string);
  Alcotest.(check string) "gemini default_model const" "gemini-2.5-flash"
    Backend_gemini.default_model
```

Register in `suite`:

```ocaml
      Alcotest.test_case "model override" `Quick test_model_override;
```

- [ ] **Step 2: Run the build to confirm it fails**

Run: `dune build 2>&1 | head -20`
Expected: FAIL — `Backend_openai.render` has no `model` label and `Backend_gemini.default_model` is unbound.

- [ ] **Step 3: `lib/backend_openai.ml` — add constant + `?model`**

Insert a constant before `let render` (after the `response_format` function, i.e. after its closing line):

```ocaml
let default_model = "gpt-4o-mini"
```

Change the `render` signature line from:

```ocaml
let render ?(no_content_user = "{{input}}") (ir : Ir.t) : Yojson.Safe.t =
```

to:

```ocaml
let render ?(no_content_user = "{{input}}") ?(model = default_model) (ir : Ir.t) : Yojson.Safe.t =
```

and change the body's model line from:

```ocaml
    [ ("model", `String "gpt-4o-mini");
```

to:

```ocaml
    [ ("model", `String model);
```

- [ ] **Step 4: `lib/backend_anthropic.ml` — add constant + `?model`**

Insert a constant before `let render` (after the `output_config` function's closing line):

```ocaml
let default_model = "claude-haiku-4-5-20251001"
```

Change the `render` signature line from:

```ocaml
let render ?(no_content_user = "{{input}}") (ir : Ir.t) : Yojson.Safe.t =
```

to:

```ocaml
let render ?(no_content_user = "{{input}}") ?(model = default_model) (ir : Ir.t) : Yojson.Safe.t =
```

and change the body's model line from:

```ocaml
    [ ("model", `String "claude-haiku-4-5-20251001");
```

to:

```ocaml
    [ ("model", `String model);
```

- [ ] **Step 5: `lib/backend_gemini.ml` — add the constant only**

Insert, immediately after the two leading comment lines (the `POST ...` / `The model is in the URL ...` comment) and before `let rec gemini_of_ty`:

```ocaml
let default_model = "gemini-2.5-flash"
```

Do NOT change `render` (the `generateContent` body has no `model` field).

- [ ] **Step 6: Build, test, corpus — verify green**

Run: `dune build && dune runtest --force 2>&1 | grep -E "tests run|FAIL"` then `bash scripts/check-corpus.sh`
Expected: PASS — `model override` passes; existing backend/cram tests stay green (default args reproduce the old output); corpus `25/25`.

- [ ] **Step 7: Commit**

```bash
git add lib/backend_openai.ml lib/backend_anthropic.ml lib/backend_gemini.ml test/test_backends.ml
git commit -m "feat(backend): per-target default_model constants + render ?model

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: `?model` through `compile_string` and `compile_request`

**Files:**
- Modify: `lib/compile.ml:48-79`
- Test: `test/test_backends.ml`

- [ ] **Step 1: Write the failing test**

Add to `test/test_backends.ml` above `let suite`:

```ocaml
(* compile_string / compile_request forward ?model to the OpenAI/Anthropic renderers. *)
let test_compile_model () =
  let open Yojson.Safe.Util in
  (match Compile.compile_request ~model:"gpt-4o" {|agent "a" { goal "g" }|} with
   | Error _ -> Alcotest.fail "compile_request failed"
   | Ok j -> Alcotest.(check string) "req override" "gpt-4o" (j |> member "model" |> to_string));
  (match Compile.compile_request {|agent "a" { goal "g" }|} with
   | Error _ -> Alcotest.fail "compile_request failed"
   | Ok j -> Alcotest.(check string) "req default" "gpt-4o-mini" (j |> member "model" |> to_string));
  match
    Compile.compile_string ~target:`Anthropic ~model:"claude-opus-4-8"
      {|agent "a" { goal "g" }|}
  with
  | Compile.Failure _ -> Alcotest.fail "compile_string failed"
  | Compile.Success o ->
      Alcotest.(check string) "str override" "claude-opus-4-8"
        (o.Compile.json |> member "model" |> to_string)
```

Register in `suite`:

```ocaml
      Alcotest.test_case "compile model" `Quick test_compile_model;
```

- [ ] **Step 2: Run the build to confirm it fails**

Run: `dune build 2>&1 | head -20`
Expected: FAIL — `compile_request`/`compile_string` have no `model` label.

- [ ] **Step 3: Add `?model` to `compile_string`**

In `lib/compile.ml`, change the `compile_string` signature line from:

```ocaml
let compile_string ?(values = []) ?(resolver = default_resolver)
    ?(target : [ `OpenAI | `Anthropic | `Gemini ] = `OpenAI) (src : string) : outcome =
```

to:

```ocaml
let compile_string ?(values = []) ?(resolver = default_resolver)
    ?(target : [ `OpenAI | `Anthropic | `Gemini ] = `OpenAI) ?model (src : string) : outcome =
```

and change its renderer dispatch from:

```ocaml
            match target with
            | `OpenAI -> Backend_openai.render ir
            | `Anthropic -> Backend_anthropic.render ir
            | `Gemini -> Backend_gemini.render ir
```

to:

```ocaml
            match target with
            | `OpenAI -> Backend_openai.render ?model ir
            | `Anthropic -> Backend_anthropic.render ?model ir
            | `Gemini -> Backend_gemini.render ir
```

- [ ] **Step 4: Add `?model` to `compile_request`**

In `lib/compile.ml`, change the `compile_request` signature line from:

```ocaml
let compile_request ?(values = []) ?(resolver = default_resolver)
    ?(target : [ `OpenAI | `Anthropic | `Gemini ] = `OpenAI) (src : string) :
    (Yojson.Safe.t, Error.t list) result =
```

to:

```ocaml
let compile_request ?(values = []) ?(resolver = default_resolver)
    ?(target : [ `OpenAI | `Anthropic | `Gemini ] = `OpenAI) ?model (src : string) :
    (Yojson.Safe.t, Error.t list) result =
```

and change its renderer dispatch from:

```ocaml
            (match target with
             | `OpenAI -> Backend_openai.render ~no_content_user:"" ir
             | `Anthropic -> Backend_anthropic.render ~no_content_user:"" ir
             | `Gemini -> Backend_gemini.render ~no_content_user:"" ir))
```

to:

```ocaml
            (match target with
             | `OpenAI -> Backend_openai.render ?model ~no_content_user:"" ir
             | `Anthropic -> Backend_anthropic.render ?model ~no_content_user:"" ir
             | `Gemini -> Backend_gemini.render ~no_content_user:"" ir))
```

- [ ] **Step 5: Build, test, corpus — verify green**

Run: `dune build && dune runtest --force 2>&1 | grep -E "tests run|FAIL"` then `bash scripts/check-corpus.sh`
Expected: PASS — `compile model` passes; the existing `compile_request targets` / `compile_string target` tests still pass (no `?model` → defaults); corpus `25/25`.

- [ ] **Step 6: Commit**

```bash
git add lib/compile.ml test/test_backends.ml
git commit -m "feat(compile): thread ?model through compile_string/compile_request

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Runtime `default_model` + `endpoint ~model:` (behavior-preserving)

**Files:**
- Modify: `lib/runtime.ml`
- Modify: `lib/driver.ml` (`run_run` body)
- Test: `test/test_runtime.ml`

- [ ] **Step 1: Write the failing test**

Add to `test/test_runtime.ml` above `let suite`:

```ocaml
let test_endpoints () =
  Alcotest.(check string) "openai endpoint static"
    "https://api.openai.com/v1/chat/completions"
    (Runtime.openai.Runtime.endpoint ~model:"ignored" ~api_key:"K");
  Alcotest.(check string) "gemini endpoint embeds model + key"
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=K"
    (Runtime.gemini.Runtime.endpoint ~model:"gemini-2.0-flash" ~api_key:"K");
  Alcotest.(check string) "gemini default_model" "gemini-2.5-flash"
    Runtime.gemini.Runtime.default_model
```

Register in `suite`:

```ocaml
      Alcotest.test_case "endpoints" `Quick test_endpoints;
```

- [ ] **Step 2: Run the build to confirm it fails**

Run: `dune build 2>&1 | head -20`
Expected: FAIL — `endpoint` doesn't accept `~model`/`~api_key`, and `default_model` is not a field.

- [ ] **Step 3: Update the `provider` record and the three values in `lib/runtime.ml`**

Change the record definition from:

```ocaml
type provider = {
  env_var : string;
  endpoint : string -> string;                          (* api_key -> URL *)
  headers : string -> (string * string) list;            (* api_key -> extra headers *)
  extract : Yojson.Safe.t -> (string, string) result;    (* response JSON -> reply text | error *)
}
```

to:

```ocaml
type provider = {
  env_var : string;
  default_model : string;                                (* built-in model when --model omitted *)
  endpoint : model:string -> api_key:string -> string;   (* URL (Gemini embeds the model) *)
  headers : string -> (string * string) list;            (* api_key -> extra headers *)
  extract : Yojson.Safe.t -> (string, string) result;    (* response JSON -> reply text | error *)
}
```

Change the `openai` value from:

```ocaml
let openai : provider =
  { env_var = "OPENAI_API_KEY";
    endpoint = (fun _ -> "https://api.openai.com/v1/chat/completions");
    headers = (fun k -> [ ("Authorization", "Bearer " ^ k) ]);
    extract = openai_extract }
```

to:

```ocaml
let openai : provider =
  { env_var = "OPENAI_API_KEY";
    default_model = Backend_openai.default_model;
    endpoint = (fun ~model:_ ~api_key:_ -> "https://api.openai.com/v1/chat/completions");
    headers = (fun k -> [ ("Authorization", "Bearer " ^ k) ]);
    extract = openai_extract }
```

Change the `anthropic` value from:

```ocaml
let anthropic : provider =
  { env_var = "ANTHROPIC_API_KEY";
    endpoint = (fun _ -> "https://api.anthropic.com/v1/messages");
    headers = (fun k -> [ ("x-api-key", k); ("anthropic-version", "2023-06-01") ]);
    extract = anthropic_extract }
```

to:

```ocaml
let anthropic : provider =
  { env_var = "ANTHROPIC_API_KEY";
    default_model = Backend_anthropic.default_model;
    endpoint = (fun ~model:_ ~api_key:_ -> "https://api.anthropic.com/v1/messages");
    headers = (fun k -> [ ("x-api-key", k); ("anthropic-version", "2023-06-01") ]);
    extract = anthropic_extract }
```

Change the `gemini` value from:

```ocaml
let gemini : provider =
  { env_var = "GEMINI_API_KEY";
    endpoint =
      (fun k ->
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key="
        ^ k);
    headers = (fun _ -> []);
    extract = gemini_extract }
```

to:

```ocaml
let gemini : provider =
  { env_var = "GEMINI_API_KEY";
    default_model = Backend_gemini.default_model;
    endpoint =
      (fun ~model ~api_key ->
        "https://generativelanguage.googleapis.com/v1beta/models/" ^ model
        ^ ":generateContent?key=" ^ api_key);
    headers = (fun _ -> []);
    extract = gemini_extract }
```

- [ ] **Step 4: Add `~model` to `curl_transport`**

Change the `curl_transport` signature line from:

```ocaml
let curl_transport ~(provider : provider) ~(api_key : string) : transport =
```

to:

```ocaml
let curl_transport ~(provider : provider) ~(model : string) ~(api_key : string) : transport =
```

and change the endpoint call inside the `cmd` construction from:

```ocaml
          ([ "curl"; "-sS"; "-X"; "POST"; Filename.quote (provider.endpoint api_key) ]
```

to:

```ocaml
          ([ "curl"; "-sS"; "-X"; "POST"; Filename.quote (provider.endpoint ~model ~api_key) ]
```

- [ ] **Step 5: Pin `driver.ml`'s `run_run` to the default model (keep build green, behavior identical)**

In `lib/driver.ml`, inside `run_run`, the `| Some api_key -> (` branch currently leads into `let rec parse ...`. Add a `let model = ...` binding right after `| Some api_key -> (` and before `let rec parse`:

```ocaml
  | Some api_key -> (
      let model = provider.Runtime.default_model in
```

Then change the transport line from:

```ocaml
                      ~transport:(Runtime.curl_transport ~provider ~api_key)
```

to:

```ocaml
                      ~transport:(Runtime.curl_transport ~provider ~model ~api_key)
```

(Do NOT change the `compile_request` call yet — Task 4 adds `?model` there. With `model = provider.default_model`, the Gemini URL is still `gemini-2.5-flash` and OpenAI/Anthropic are untouched, so `run` behavior is identical to ⑤.)

- [ ] **Step 6: Build, test, corpus — verify green**

Run: `dune build && dune runtest --force 2>&1 | grep -E "tests run|FAIL"` then `bash scripts/check-corpus.sh`
Expected: PASS — `endpoints` passes; all existing runtime tests (which use the fake-transport `exec`, not `endpoint`) stay green; corpus `25/25`.

- [ ] **Step 7: Commit**

```bash
git add lib/runtime.ml lib/driver.ml test/test_runtime.ml
git commit -m "feat(runtime): provider default_model + endpoint ~model (Gemini URL)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: `--model` flag on `compile` and `run`

**Files:**
- Modify: `lib/driver.ml` (`run_run`, `run_compile`)
- Modify: `bin/main.ml`
- Test: `test/cram/emit.t`

- [ ] **Step 1: Add the failing cram case**

Append to `test/cram/emit.t`:

```
The --model flag overrides the default model in the request:

  $ promptc compile researcher.prompt --model gpt-4o --emit json | head -2
  {
    "model": "gpt-4o",
```

- [ ] **Step 2: Run cram to confirm it fails**

Run: `dune runtest 2>&1 | grep -A4 "model flag" | head -20`
Expected: FAIL — `--model` is an unknown option on `compile` (cmdliner usage error), so the expected output doesn't match.

- [ ] **Step 3: Thread `--model` into `run_run`**

In `lib/driver.ml`, change the `run_run` signature from:

```ocaml
let run_run (file : string) (sets : string list)
    (target : [ `OpenAI | `Anthropic | `Gemini ]) : int =
```

to:

```ocaml
let run_run (file : string) (sets : string list)
    (target : [ `OpenAI | `Anthropic | `Gemini ]) (model_opt : string option) : int =
```

Change the model binding added in Task 3 from:

```ocaml
      let model = provider.Runtime.default_model in
```

to:

```ocaml
      let model =
        match model_opt with Some m -> m | None -> provider.Runtime.default_model
      in
```

Change the `compile_request` call from:

```ocaml
              match Compile.compile_request ~values ~resolver ~target src with
```

to:

```ocaml
              match Compile.compile_request ~values ~resolver ~target ?model:(Some model) src with
```

- [ ] **Step 4: Thread `--model` into `run_compile`**

In `lib/driver.ml`, change the `run_compile` signature from:

```ocaml
let run_compile (file : string) (emit : [ `Prose | `Json | `Both ]) (sets : string list)
    (target : [ `OpenAI | `Anthropic | `Gemini ]) : int =
```

to:

```ocaml
let run_compile (file : string) (emit : [ `Prose | `Json | `Both ]) (sets : string list)
    (target : [ `OpenAI | `Anthropic | `Gemini ]) (model : string option) : int =
```

and change its `compile_string` call from:

```ocaml
          match Compile.compile_string ~values ~resolver ~target src with
```

to:

```ocaml
          match Compile.compile_string ~values ~resolver ~target ?model src with
```

- [ ] **Step 5: Add the `--model` flag in `bin/main.ml`**

Add an arg after `target_arg`:

```ocaml
let model_arg =
  let doc = "Model id to use, overriding the target's default (e.g. $(b,--model gpt-4o))." in
  Arg.(value & opt (some string) None & info [ "model" ] ~docv:"MODEL" ~doc)
```

Change the `compile_cmd` term from:

```ocaml
  let term = Term.(const Driver.run_compile $ file_arg $ emit_arg $ set_arg $ target_arg) in
```

to:

```ocaml
  let term = Term.(const Driver.run_compile $ file_arg $ emit_arg $ set_arg $ target_arg $ model_arg) in
```

Change the `run_cmd` term from:

```ocaml
  let term = Term.(const Driver.run_run $ file_arg $ set_arg $ target_arg) in
```

to:

```ocaml
  let term = Term.(const Driver.run_run $ file_arg $ set_arg $ target_arg $ model_arg) in
```

- [ ] **Step 6: Build, run the full suite — verify green**

Run: `dune build && dune runtest 2>&1 | grep -E "tests run|FAIL"` (then a second `dune runtest` must be clean).
Expected: PASS — the new `--model` cram case shows `"model": "gpt-4o"`; the existing `emit.t` default case still shows `gpt-4o-mini`.

- [ ] **Step 7: Smoke-test the CLI**

Run:
```bash
dune build && \
./_build/default/bin/main.exe compile test/cram/researcher.prompt --target anthropic --model claude-opus-4-8 --emit json | head -2 && \
echo "---" && \
env -u OPENAI_API_KEY ./_build/default/bin/main.exe run test/cram/researcher.prompt --model gpt-4o; echo "exit=$?"
```
Expected: the compile output shows `"model": "claude-opus-4-8"`; the `run` (no key) still prints `OPENAI_API_KEY is not set` and `exit=2` (proving `--model` parses on `run`).

- [ ] **Step 8: Corpus guard**

Run: `bash scripts/check-corpus.sh`
Expected: `25/25`.

- [ ] **Step 9: Commit**

```bash
git add lib/driver.ml bin/main.ml test/cram/emit.t
git commit -m "feat(cli): --model overrides the per-target default on compile and run

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review (completed by plan author)

**Spec coverage:**
- `--model` flag on compile + run, default = built-in — Tasks 1–4. ✔
- Single source of truth (`Backend_*.default_model`, referenced by `Runtime.provider.default_model`) — Task 1 (constants) + Task 3 (provider references). ✔
- Threading: backend `?model` (Task 1), compile `?model` (Task 2), runtime endpoint `~model` + curl `~model` (Task 3), run resolve + body/URL (Task 4). ✔
- Gemini compile caveat (body has no model; URL only) — Gemini `render` is left unchanged (Task 1 Step 5), so `compile --target gemini` body is unaffected; `run`'s URL uses the model (Task 3/4). ✔
- No validation / no new error paths — `--model` is `opt (some string) None`; nothing rejects mismatches. ✔
- Testing: body override (Task 1/2), endpoint URL embeds model (Task 3), cram `--model` (Task 4), corpus 25/25 (Tasks 1–4). ✔

**Placeholder scan:** No TBD/TODO; every code step shows complete before/after text; the cram case is deterministic and hand-written.

**Type consistency:** `?model` is `string option` throughout (`compile_string`, `compile_request`, `run_compile`, `run_run`, `model_arg`); supplied as `~model:v` in tests and forwarded as `?model` / `?model:(Some model)` from drivers. `provider.endpoint : model:string -> api_key:string -> string` matches its sole caller `curl_transport` (`~model ~api_key`) and the unit test. `provider.default_model` is read in `run_run` and the `endpoints` test. `Backend_gemini.default_model` is the one Gemini default, referenced by `Runtime.gemini`.
