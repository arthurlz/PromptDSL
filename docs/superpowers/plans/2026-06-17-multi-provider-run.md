# Multi-provider `run` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `promptc run <file> --target openai|anthropic|gemini` calls the chosen provider and prints its reply; OpenAI stays the default and its behavior is unchanged.

**Architecture:** Replace the OpenAI-hardcoded bits of `runtime.ml` with a `provider` record (env var, endpoint, headers, response-extractor) and three values. `compile_request` gains a `target` and dispatches the ④ backend renderers (with an empty user message for the no-content case). `run_run` + the `run` CLI gain `--target`, mirroring `compile`. The transport stays an injected `curl` shell-out so the whole flow is unit-tested without network.

**Tech Stack:** OCaml 5.4, dune, yojson (`Yojson.Safe`), `Unix.open_process_in` for curl, cmdliner, alcotest, cram. Warning-8 (non-exhaustive match) is an error.

**Spec:** `docs/superpowers/specs/2026-06-17-multi-provider-run-design.md`

**Conventions for the implementer:**
- Build: `dune build`. Unit tests: `dune runtest --force 2>&1 | grep -E "tests run|FAIL"`. Corpus: `bash scripts/check-corpus.sh` (must stay `25/25`).
- The `promptdsl` library auto-includes `lib/*.ml`; no dune edits needed.
- Provider-record field access from outside `runtime.ml` is qualified: `provider.Runtime.env_var` (driver.ml does not `open Runtime`).

---

## File Structure

- `lib/runtime.ml` (MODIFY) — introduce `provider` record + `openai`/`anthropic`/`gemini` values + shared `pretty_if_json`; refactor `execute`/`curl_transport` to take `~provider`. Removes the OpenAI-only `endpoint` constant and `format_response`.
- `lib/backend_anthropic.ml`, `lib/backend_gemini.ml` (MODIFY) — `render` gains `?(no_content_user = "{{input}}")`.
- `lib/compile.ml` (MODIFY) — `compile_request` gains `?target`, dispatches the renderer with `~no_content_user:""`.
- `lib/driver.ml` (MODIFY) — Task 1 pins `run_run` to `Runtime.openai`; Task 4 generalizes it to take `target`.
- `bin/main.ml` (MODIFY) — `run` command's term gains the existing `target_arg`.
- `test/test_runtime.ml` (MODIFY) — rewrite onto the `~provider` API; add Anthropic/Gemini extract tests.
- `test/test_backends.ml` (MODIFY) — add `compile_request ~target` tests.
- `test/cram/run.t` (MODIFY) — add the Anthropic/Gemini "not set" cases.

---

## Task 1: Provider record + OpenAI provider (refactor, no behavior change)

**Files:**
- Modify: `lib/runtime.ml`
- Modify: `lib/driver.ml:60`
- Test: `test/test_runtime.ml`

- [ ] **Step 1: Rewrite the runtime tests onto the new `~provider` API (failing)**

Replace the **entire contents** of `test/test_runtime.ml` with:

```ocaml
open Promptdsl

(* Run the full execute path with a fake transport that returns canned JSON. *)
let exec provider raw =
  Runtime.execute ~provider ~transport:(fun _ -> Ok raw) (`Assoc [])

let test_openai_text () =
  match exec Runtime.openai {|{"choices":[{"message":{"content":"hello there"}}]}|} with
  | Ok s -> Alcotest.(check string) "text" "hello there" s
  | Error _ -> Alcotest.fail "unexpected error"

let test_openai_json () =
  match exec Runtime.openai {|{"choices":[{"message":{"content":"{\"score\":87}"}}]}|} with
  | Ok s ->
      Alcotest.(check bool) "reparses to same json" true
        (Yojson.Safe.from_string s = `Assoc [ ("score", `Int 87) ])
  | Error _ -> Alcotest.fail "unexpected error"

let test_openai_error () =
  match exec Runtime.openai {|{"error":{"message":"Invalid API key"}}|} with
  | Error m -> Alcotest.(check string) "err msg" "Invalid API key" m
  | Ok _ -> Alcotest.fail "expected error"

let test_openai_bad_shape () =
  match exec Runtime.openai {|{"choices":[]}|} with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected error"

let test_execute_transport_error () =
  match
    Runtime.execute ~provider:Runtime.openai
      ~transport:(fun _ -> Error "network down") (`Assoc [])
  with
  | Error m -> Alcotest.(check string) "transport err" "network down" m
  | Ok _ -> Alcotest.fail "expected error"

let suite =
  ( "runtime",
    [ Alcotest.test_case "openai text" `Quick test_openai_text;
      Alcotest.test_case "openai json" `Quick test_openai_json;
      Alcotest.test_case "openai error" `Quick test_openai_error;
      Alcotest.test_case "openai bad shape" `Quick test_openai_bad_shape;
      Alcotest.test_case "execute transport error" `Quick test_execute_transport_error ] )
```

- [ ] **Step 2: Run the build to confirm it fails**

Run: `dune build 2>&1 | head -20`
Expected: FAIL — `Runtime.openai` unbound and/or `execute` has no `~provider` label.

- [ ] **Step 3: Rewrite `lib/runtime.ml`**

Replace the **entire contents** of `lib/runtime.ml` with:

```ocaml
type transport = string -> (string, string) result

type provider = {
  env_var : string;
  endpoint : string -> string;                          (* api_key -> URL *)
  headers : string -> (string * string) list;            (* api_key -> extra headers *)
  extract : Yojson.Safe.t -> (string, string) result;    (* response JSON -> reply text | error *)
}

(* Shared error branch: every provider exposes the human message at error.message. *)
let error_message (err : Yojson.Safe.t) : string =
  match Yojson.Safe.Util.member "message" err with
  | `String m -> m
  | _ -> "API error"

(* OpenAI: choices[0].message.content *)
let openai_extract (resp : Yojson.Safe.t) : (string, string) result =
  let open Yojson.Safe.Util in
  match member "error" resp with
  | `Null -> (
      match member "choices" resp with
      | `List (c :: _) -> (
          match c |> member "message" |> member "content" with
          | `String content -> Ok content
          | _ -> Error "unexpected response shape (no message content)")
      | _ -> Error "unexpected response shape (no choices)")
  | err -> Error (error_message err)

(* Anthropic: first content[] block whose type is "text" -> its text *)
let anthropic_extract (resp : Yojson.Safe.t) : (string, string) result =
  let open Yojson.Safe.Util in
  match member "error" resp with
  | `Null -> (
      match member "content" resp with
      | `List blocks -> (
          match
            List.find_opt (fun b -> member "type" b = `String "text") blocks
          with
          | Some b -> (
              match member "text" b with
              | `String t -> Ok t
              | _ -> Error "unexpected response shape (no text)")
          | None -> Error "unexpected response shape (no text block)")
      | _ -> Error "unexpected response shape (no content)")
  | err -> Error (error_message err)

(* Gemini: candidates[0].content.parts[0].text *)
let gemini_extract (resp : Yojson.Safe.t) : (string, string) result =
  let open Yojson.Safe.Util in
  match member "error" resp with
  | `Null -> (
      match member "candidates" resp with
      | `List (c :: _) -> (
          match c |> member "content" |> member "parts" with
          | `List (p :: _) -> (
              match member "text" p with
              | `String t -> Ok t
              | _ -> Error "unexpected response shape (no text)")
          | _ -> Error "unexpected response shape (no parts)")
      | _ -> Error "unexpected response shape (no candidates)")
  | err -> Error (error_message err)

let openai : provider =
  { env_var = "OPENAI_API_KEY";
    endpoint = (fun _ -> "https://api.openai.com/v1/chat/completions");
    headers = (fun k -> [ ("Authorization", "Bearer " ^ k) ]);
    extract = openai_extract }

let anthropic : provider =
  { env_var = "ANTHROPIC_API_KEY";
    endpoint = (fun _ -> "https://api.anthropic.com/v1/messages");
    headers = (fun k -> [ ("x-api-key", k); ("anthropic-version", "2023-06-01") ]);
    extract = anthropic_extract }

let gemini : provider =
  { env_var = "GEMINI_API_KEY";
    endpoint =
      (fun k ->
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key="
        ^ k);
    headers = (fun _ -> []);
    extract = gemini_extract }

(* If the reply parses as JSON, pretty-print it; otherwise return it unchanged. *)
let pretty_if_json (content : string) : string =
  match Yojson.Safe.from_string content with
  | exception _ -> content
  | j -> Yojson.Safe.pretty_to_string j

let execute ~(provider : provider) ~(transport : transport) (request : Yojson.Safe.t) :
    (string, string) result =
  match transport (Yojson.Safe.to_string request) with
  | Error e -> Error e
  | Ok raw -> (
      match Yojson.Safe.from_string raw with
      | exception _ -> Error "invalid JSON response from API"
      | resp -> Result.map pretty_if_json (provider.extract resp))

(* Shell out to curl. The only piece not exercised by unit tests. *)
let curl_transport ~(provider : provider) ~(api_key : string) : transport =
 fun body ->
  let tmp = Filename.temp_file "promptc" ".json" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove tmp with _ -> ())
    (fun () ->
      let oc = open_out tmp in
      output_string oc body;
      close_out oc;
      let header_args =
        List.concat_map
          (fun (k, v) -> [ "-H"; Filename.quote (k ^ ": " ^ v) ])
          (("Content-Type", "application/json") :: provider.headers api_key)
      in
      let cmd =
        String.concat " "
          ([ "curl"; "-sS"; "-X"; "POST"; Filename.quote (provider.endpoint api_key) ]
          @ header_args
          @ [ "-d"; Filename.quote ("@" ^ tmp) ])
      in
      let ic = Unix.open_process_in cmd in
      let out = In_channel.input_all ic in
      match Unix.close_process_in ic with
      | Unix.WEXITED 0 -> Ok out
      | _ -> Error (if out = "" then "curl request failed" else out))
```

- [ ] **Step 4: Pin `driver.ml`'s call to `Runtime.openai` (keep the build green)**

In `lib/driver.ml`, find the `run_run` body line (currently `lib/driver.ml:60`):

```ocaml
                    Runtime.execute ~transport:(Runtime.curl_transport ~api_key) request
```

Replace it with:

```ocaml
                    Runtime.execute ~provider:Runtime.openai
                      ~transport:(Runtime.curl_transport ~provider:Runtime.openai ~api_key)
                      request
```

(Everything else in `run_run` — the `OPENAI_API_KEY` read, `--set` parsing, file read, `compile_request` — stays exactly as is. Behavior is identical to ③.)

- [ ] **Step 5: Build, test, corpus — verify green and behavior unchanged**

Run: `dune build && dune runtest --force 2>&1 | grep -E "tests run|FAIL"` then `bash scripts/check-corpus.sh`
Expected: all tests pass (the 5 rewritten runtime cases + everything else); corpus `25/25`.

- [ ] **Step 6: Commit**

```bash
git add lib/runtime.ml lib/driver.ml test/test_runtime.ml
git commit -m "refactor(runtime): provider record; OpenAI as a provider value

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Anthropic + Gemini providers (response extraction)

**Files:**
- Test: `test/test_runtime.ml` (the providers themselves already exist from Task 1; this task proves their `extract` end-to-end)

- [ ] **Step 1: Write the failing tests**

Add to `test/test_runtime.ml` above `let suite` (the `exec` helper already exists from Task 1):

```ocaml
let test_anthropic_text () =
  match exec Runtime.anthropic {|{"content":[{"type":"text","text":"hi from claude"}]}|} with
  | Ok s -> Alcotest.(check string) "text" "hi from claude" s
  | Error _ -> Alcotest.fail "unexpected error"

let test_anthropic_json () =
  match exec Runtime.anthropic {|{"content":[{"type":"text","text":"{\"score\":91}"}]}|} with
  | Ok s ->
      Alcotest.(check bool) "reparses to same json" true
        (Yojson.Safe.from_string s = `Assoc [ ("score", `Int 91) ])
  | Error _ -> Alcotest.fail "unexpected error"

let test_anthropic_error () =
  match exec Runtime.anthropic {|{"type":"error","error":{"type":"overloaded_error","message":"overloaded"}}|} with
  | Error m -> Alcotest.(check string) "err msg" "overloaded" m
  | Ok _ -> Alcotest.fail "expected error"

let test_anthropic_bad_shape () =
  match exec Runtime.anthropic {|{"content":[]}|} with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected error"

let test_gemini_text () =
  match exec Runtime.gemini {|{"candidates":[{"content":{"parts":[{"text":"hi from gemini"}]}}]}|} with
  | Ok s -> Alcotest.(check string) "text" "hi from gemini" s
  | Error _ -> Alcotest.fail "unexpected error"

let test_gemini_json () =
  match exec Runtime.gemini {|{"candidates":[{"content":{"parts":[{"text":"{\"score\":75}"}]}}]}|} with
  | Ok s ->
      Alcotest.(check bool) "reparses to same json" true
        (Yojson.Safe.from_string s = `Assoc [ ("score", `Int 75) ])
  | Error _ -> Alcotest.fail "unexpected error"

let test_gemini_error () =
  match exec Runtime.gemini {|{"error":{"code":400,"message":"API key not valid","status":"INVALID_ARGUMENT"}}|} with
  | Error m -> Alcotest.(check string) "err msg" "API key not valid" m
  | Ok _ -> Alcotest.fail "expected error"

let test_gemini_bad_shape () =
  match exec Runtime.gemini {|{"candidates":[]}|} with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected error"
```

Register the eight cases in the `suite` list:

```ocaml
      Alcotest.test_case "anthropic text" `Quick test_anthropic_text;
      Alcotest.test_case "anthropic json" `Quick test_anthropic_json;
      Alcotest.test_case "anthropic error" `Quick test_anthropic_error;
      Alcotest.test_case "anthropic bad shape" `Quick test_anthropic_bad_shape;
      Alcotest.test_case "gemini text" `Quick test_gemini_text;
      Alcotest.test_case "gemini json" `Quick test_gemini_json;
      Alcotest.test_case "gemini error" `Quick test_gemini_error;
      Alcotest.test_case "gemini bad shape" `Quick test_gemini_bad_shape;
```

- [ ] **Step 2: Run the tests — they should pass immediately**

Run: `dune build && dune runtest --force 2>&1 | grep -E "tests run|FAIL"`
Expected: PASS. The `anthropic`/`gemini` provider values and their `extract` functions were written in Task 1, so these tests confirm the extraction shapes (success text, JSON pretty-print, `error.message`, malformed → error) are correct. If any fail, fix the corresponding `*_extract` in `lib/runtime.ml`.

- [ ] **Step 3: Commit**

```bash
git add test/test_runtime.ml
git commit -m "test(runtime): Anthropic + Gemini response extraction

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: `compile_request --target` + empty-user-message renderers

**Files:**
- Modify: `lib/backend_anthropic.ml`
- Modify: `lib/backend_gemini.ml`
- Modify: `lib/compile.ml:65` (`compile_request`)
- Test: `test/test_backends.ml`

- [ ] **Step 1: Write the failing test**

Add to `test/test_backends.ml` above `let suite` (helpers `sample_ir`/`ir_with` exist; this uses `Compile`):

```ocaml
(* compile_request builds each provider's body with the run-time user message
   (bound @content, or "" when none — never the {{input}} placeholder). *)
let test_compile_request_targets () =
  let open Yojson.Safe.Util in
  (match
     Compile.compile_request ~target:`Anthropic ~values:[ ("body", "hi") ]
       {|agent "a" { input { body: string @content } goal "g" }|}
   with
   | Error _ -> Alcotest.fail "anthropic compile_request failed"
   | Ok j ->
       Alcotest.(check string) "anthropic model" "claude-haiku-4-5-20251001"
         (j |> member "model" |> to_string);
       let u = j |> member "messages" |> to_list |> List.hd |> member "content" |> to_string in
       Alcotest.(check string) "anthropic content user" "hi" u);
  (match Compile.compile_request ~target:`Anthropic {|agent "a" { goal "g" }|} with
   | Error _ -> Alcotest.fail "anthropic compile_request failed"
   | Ok j ->
       let u = j |> member "messages" |> to_list |> List.hd |> member "content" |> to_string in
       Alcotest.(check string) "anthropic empty user (not placeholder)" "" u);
  (match
     Compile.compile_request ~target:`Gemini ~values:[ ("body", "hey") ]
       {|agent "a" { input { body: string @content } goal "g" }|}
   with
   | Error _ -> Alcotest.fail "gemini compile_request failed"
   | Ok j ->
       let t =
         j |> member "contents" |> to_list |> List.hd |> member "parts" |> to_list
         |> List.hd |> member "text" |> to_string
       in
       Alcotest.(check string) "gemini content text" "hey" t)
```

Register in the `suite` list:

```ocaml
      Alcotest.test_case "compile_request targets" `Quick test_compile_request_targets;
```

- [ ] **Step 2: Run the build to confirm it fails**

Run: `dune build 2>&1 | head -20`
Expected: FAIL — `compile_request` has no `~target` label.

- [ ] **Step 3: Add `?no_content_user` to the Anthropic renderer**

In `lib/backend_anthropic.ml`, change the `render` signature line:

```ocaml
let render (ir : Ir.t) : Yojson.Safe.t =
```

to:

```ocaml
let render ?(no_content_user = "{{input}}") (ir : Ir.t) : Yojson.Safe.t =
```

and change the user-message construction inside it from:

```ocaml
                ("content", `String (Backend_common.user_message ir)) ] ] ) ]
```

to:

```ocaml
                ("content", `String (Backend_common.user_message ~no_content_user ir)) ] ] ) ]
```

- [ ] **Step 4: Add `?no_content_user` to the Gemini renderer**

In `lib/backend_gemini.ml`, change the `render` signature line:

```ocaml
let render (ir : Ir.t) : Yojson.Safe.t =
```

to:

```ocaml
let render ?(no_content_user = "{{input}}") (ir : Ir.t) : Yojson.Safe.t =
```

and change the user-part construction inside it from:

```ocaml
                  `List [ `Assoc [ ("text", `String (Backend_common.user_message ir)) ] ] ) ] ] ) ]
```

to:

```ocaml
                  `List [ `Assoc [ ("text", `String (Backend_common.user_message ~no_content_user ir)) ] ] ) ] ] ) ]
```

- [ ] **Step 5: Add `?target` to `compile_request` in `lib/compile.ml`**

Replace the existing `compile_request` function (currently `lib/compile.ml:65`) with:

```ocaml
let compile_request ?(values = []) ?(resolver = default_resolver)
    ?(target : [ `OpenAI | `Anthropic | `Gemini ] = `OpenAI) (src : string) :
    (Yojson.Safe.t, Error.t list) result =
  match frontend ~resolver src with
  | Error ds -> Error ds
  | Ok (checked, fragments) -> (
      match Bind.bind ~fragments checked values with
      | Error ds -> Error ds
      | Ok bound ->
          let ir = Lower.lower bound in
          Ok
            (match target with
             | `OpenAI -> Backend_openai.render ~no_content_user:"" ir
             | `Anthropic -> Backend_anthropic.render ~no_content_user:"" ir
             | `Gemini -> Backend_gemini.render ~no_content_user:"" ir))
```

- [ ] **Step 6: Build, test, corpus — verify green**

Run: `dune build && dune runtest --force 2>&1 | grep -E "tests run|FAIL"` then `bash scripts/check-corpus.sh`
Expected: PASS — `compile_request targets` passes; the existing `run request user` test (default target = OpenAI, empty user) still passes; `compile --target` cram goldens are unchanged (those use the `{{input}}` default via `compile_string`, not `compile_request`); corpus `25/25`.

- [ ] **Step 7: Commit**

```bash
git add lib/backend_anthropic.ml lib/backend_gemini.ml lib/compile.ml test/test_backends.ml
git commit -m "feat(compile): compile_request --target with content-or-empty user message

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: `run --target` (driver + CLI + cram)

**Files:**
- Modify: `lib/driver.ml` (`run_run`)
- Modify: `bin/main.ml` (`run_cmd`)
- Test: `test/cram/run.t`

- [ ] **Step 1: Add the failing cram cases**

Append to `test/cram/run.t` (the file already creates `a.prompt` at the top; reuse it):

```
run --target anthropic without ANTHROPIC_API_KEY exits 2:

  $ env -u ANTHROPIC_API_KEY promptc run a.prompt --target anthropic
  ANTHROPIC_API_KEY is not set
  [2]

run --target gemini without GEMINI_API_KEY exits 2:

  $ env -u GEMINI_API_KEY promptc run a.prompt --target gemini
  GEMINI_API_KEY is not set
  [2]
```

- [ ] **Step 2: Run cram to confirm it fails**

Run: `dune runtest 2>&1 | grep -A3 "run.t" | head -30`
Expected: FAIL — `--target` is an unknown option on `run` (cmdliner usage error / wrong exit), so the expected output doesn't match.

- [ ] **Step 3: Generalize `run_run` in `lib/driver.ml`**

Add a helper above `run_run` (after `parse_set`):

```ocaml
let provider_of_target = function
  | `OpenAI -> Runtime.openai
  | `Anthropic -> Runtime.anthropic
  | `Gemini -> Runtime.gemini
```

Replace the `run_run` header line:

```ocaml
let run_run (file : string) (sets : string list) : int =
  match Sys.getenv_opt "OPENAI_API_KEY" with
  | None | Some "" ->
      prerr_endline "OPENAI_API_KEY is not set";
      2
```

with:

```ocaml
let run_run (file : string) (sets : string list)
    (target : [ `OpenAI | `Anthropic | `Gemini ]) : int =
  let provider = provider_of_target target in
  match Sys.getenv_opt provider.Runtime.env_var with
  | None | Some "" ->
      prerr_endline (provider.Runtime.env_var ^ " is not set");
      2
```

Then, in the body, replace the `compile_request` call:

```ocaml
              match Compile.compile_request ~values ~resolver src with
```

with:

```ocaml
              match Compile.compile_request ~values ~resolver ~target src with
```

and replace the `Runtime.execute` call (the Task-1 pinned form):

```ocaml
                    Runtime.execute ~provider:Runtime.openai
                      ~transport:(Runtime.curl_transport ~provider:Runtime.openai ~api_key)
                      request
```

with:

```ocaml
                    Runtime.execute ~provider
                      ~transport:(Runtime.curl_transport ~provider ~api_key)
                      request
```

- [ ] **Step 4: Wire `--target` into the `run` command in `bin/main.ml`**

The `target_arg` value already exists (added in cut ④). Replace the `run_cmd` term:

```ocaml
  let term = Term.(const Driver.run_run $ file_arg $ set_arg) in
```

with (argument order must match `run_run`: file, sets, target):

```ocaml
  let term = Term.(const Driver.run_run $ file_arg $ set_arg $ target_arg) in
```

- [ ] **Step 5: Build and run the cram suite — verify green**

Run: `dune build && dune runtest 2>&1 | grep -E "tests run|FAIL"` (a second `dune runtest` must be clean).
Expected: PASS — the new cram cases print the provider-specific "not set" message and `[2]`; the existing default `run` cases (OpenAI) still pass.

- [ ] **Step 6: Smoke-test the CLI**

Run:
```bash
dune build && \
env -u ANTHROPIC_API_KEY ./_build/default/bin/main.exe run test/cram/researcher.prompt --target anthropic; echo "exit=$?" && \
( ./_build/default/bin/main.exe run test/cram/researcher.prompt --target bogus >/dev/null 2>&1; echo "bad target exit=$?" )
```
Expected: the first prints `ANTHROPIC_API_KEY is not set` and `exit=2`; the bad target prints a cmdliner usage error and a non-zero `bad target exit=` (124).

- [ ] **Step 7: Corpus guard**

Run: `bash scripts/check-corpus.sh`
Expected: `25/25`.

- [ ] **Step 8: Commit**

```bash
git add lib/driver.ml bin/main.ml test/cram/run.t
git commit -m "feat(cli): run --target openai|anthropic|gemini

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review (completed by plan author)

**Spec coverage:**
- `provider` record (env_var/endpoint/headers/extract) + 3 values — Task 1 (openai) + Task 1 defines anthropic/gemini, Task 2 proves them. ✔
- Per-provider response paths (choices / content[].text / candidates[0].content.parts[0].text) and shared `error.message` — Task 1 `*_extract`; Task 2 tests. ✔
- `pretty_if_json` shared post-processing — Task 1. ✔
- `compile_request ?target` + `Backend_anthropic/gemini.render ?no_content_user`, content-or-empty user message — Task 3. ✔
- `run --target` (default openai), per-provider env var, exit codes — Task 4 (driver) + Task 4 (cram for the env-var/exit-2 paths). ✔
- Transport injected; `curl` per provider the only untested piece — Task 1 (`curl_transport ~provider`); execute fake-transport tests in Tasks 1–2. ✔
- cram: each target's "not set" message — Task 4 (anthropic, gemini); OpenAI default already covered by the existing run.t. ✔
- Corpus 25/25 unaffected — checked in Tasks 1, 3, 4. ✔
- `compile`/`check` unchanged, `compile --target` output unchanged — Task 3 Step 6 note (compile_request ≠ compile_string; `?no_content_user` defaults preserve ④). ✔

**Placeholder scan:** No TBD/TODO; every code step shows complete code; cram cases are deterministic (no network) and hand-written, not auto-promoted.

**Type consistency:** `target` is the same polymorphic variant `[ `OpenAI | `Anthropic | `Gemini ]` in `compile_request`, `run_run`, `provider_of_target`, and (from ④) the `target_arg` enum. `provider` record fields (`env_var`, `endpoint`, `headers`, `extract`) and the three values (`Runtime.openai/anthropic/gemini`) are named consistently across Tasks 1–4. `execute ~provider ~transport` and `curl_transport ~provider ~api_key` signatures match every call site (driver + tests).
