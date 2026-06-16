# promptc run (Runtime) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `promptc run <file> --set k=v` that compiles the agent, POSTs the OpenAI request via `curl`, and prints the model's reply.

**Architecture:** `compile_request` reuses the pipeline to produce the OpenAI request JSON with run semantics (user = content-or-empty). A new `runtime` module owns a pure `format_response` and an `execute` that takes an injected `transport` (real one shells out to `curl`), so the flow is unit-testable without network. The CLI gains a `run` subcommand.

**Tech Stack:** OCaml, dune, yojson, cmdliner, `unix` (for the curl subprocess), curl, alcotest.

**Spec:** `docs/superpowers/specs/2026-06-15-run-runtime-design.md`

---

## Conventions

- `dune test` + `./scripts/check-corpus.sh` (stay 25/25).
- Commit on a feature branch (executor sets up). Trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

## Type vocabulary

```
Backend_openai.render : ?no_content_user:string -> Ir.t -> Yojson.Safe.t   (* default "{{input}}" *)
Compile.compile_request : ?values:(string*string) list -> ?resolver:(string->(string,string) result)
                        -> string -> (Yojson.Safe.t, Error.t list) result
Runtime.transport       = string -> (string, string) result   (* request body -> raw response body / error *)
Runtime.format_response : Yojson.Safe.t -> (string, string) result
Runtime.execute         : transport:transport -> Yojson.Safe.t -> (string, string) result
Runtime.curl_transport  : api_key:string -> transport
Driver.run_run          : string -> string list -> int
```

## File map

```
lib/backend_openai.ml  + ?no_content_user param on render
lib/compile.ml         + compile_request (request JSON with no_content_user="")
lib/runtime.ml         NEW: transport, format_response (pure), execute, curl_transport
lib/dune               + `unix` library
lib/driver.ml          + run_run (env key, compile_request, execute, exit codes)
bin/main.ml            + `run` subcommand
test/*                 backends (compile_request), runtime (format/execute), cram (no-network)
```

---

### Task 1: `compile_request` + `render ?no_content_user`

**Files:** Modify `lib/backend_openai.ml`, `lib/compile.ml`, `test/test_backends.ml`.

- [ ] **Step 1: Write the failing test**

Add to `test/test_backends.ml` (before `let suite`) and register `Alcotest.test_case "run request user" `Quick test_run_request_user;`:
```ocaml
let test_run_request_user () =
  (match
     Compile.compile_request ~values:[ ("body", "hi") ]
       {|agent "a" { input { body: string @content } goal "g" }|}
   with
   | Error _ -> Alcotest.fail "compile_request failed"
   | Ok j ->
       let open Yojson.Safe.Util in
       let u = j |> member "messages" |> to_list |> List.rev |> List.hd |> member "content" |> to_string in
       Alcotest.(check string) "content user" "hi" u);
  (match Compile.compile_request {|agent "a" { goal "g" }|} with
   | Error _ -> Alcotest.fail "compile_request failed"
   | Ok j ->
       let open Yojson.Safe.Util in
       let u = j |> member "messages" |> to_list |> List.rev |> List.hd |> member "content" |> to_string in
       Alcotest.(check string) "empty user (not placeholder)" "" u)
```

- [ ] **Step 2: Run to verify it fails**

`dune test 2>&1 | head -12` → `Compile.compile_request` unbound.

- [ ] **Step 3: Parametrize the OpenAI user message**

In `lib/backend_openai.ml`, the user message currently comes from a `user_message ir` helper (`None -> "{{input}}" | Some s -> s`) used inside `render`. Add a `?no_content_user` param to both:
```ocaml
let user_message ?(no_content_user = "{{input}}") (ir : Ir.t) : string =
  match ir.content with None -> no_content_user | Some s -> s
```
and thread it through `render`:
```ocaml
let render ?(no_content_user = "{{input}}") (ir : Ir.t) : Yojson.Safe.t =
```
and at the user-message construction site inside `render`, call `user_message ~no_content_user ir`. (If `render` inlines the match rather than calling `user_message`, just thread `no_content_user` into that inline match. `compile_string` calls `Backend_openai.render ir` with no label, so the default keeps it `"{{input}}"` — unchanged.)

- [ ] **Step 4: Add `compile_request`**

In `lib/compile.ml`, after `compile_string`, add:
```ocaml
let compile_request ?(values = []) ?(resolver = default_resolver) (src : string) :
    (Yojson.Safe.t, Error.t list) result =
  match frontend ~resolver src with
  | Error ds -> Error ds
  | Ok (checked, fragments) -> (
      match Bind.bind ~fragments checked values with
      | Error ds -> Error ds
      | Ok bound -> Ok (Backend_openai.render ~no_content_user:"" (Lower.lower bound)))
```

- [ ] **Step 5: Run to verify it passes**

`dune test 2>&1 | tail -8 && ./scripts/check-corpus.sh`
Expected: `run request user` passes; all prior pass (`compile_string` still emits `{{input}}` for no-content agents — corpus/cram unchanged); corpus 25/25.

- [ ] **Step 6: Commit**

```bash
git add lib/backend_openai.ml lib/compile.ml test/test_backends.ml
git commit -m "feat(run): compile_request builds the OpenAI request with content-or-empty user"
```

---

### Task 2: `runtime` module

**Files:** Create `lib/runtime.ml`; modify `lib/dune`; add `test/test_runtime.ml`; register in `test/test_promptdsl.ml`.

- [ ] **Step 1: Write the failing tests**

`test/test_runtime.ml`:
```ocaml
open Promptdsl

let resp s = Yojson.Safe.from_string s

let test_format_text () =
  match Runtime.format_response (resp {|{"choices":[{"message":{"content":"hello there"}}]}|}) with
  | Ok s -> Alcotest.(check string) "text" "hello there" s
  | Error _ -> Alcotest.fail "unexpected error"

let test_format_json () =
  match Runtime.format_response (resp {|{"choices":[{"message":{"content":"{\"score\":87}"}}]}|}) with
  | Ok s ->
      Alcotest.(check bool) "reparses to same json" true
        (Yojson.Safe.from_string s = `Assoc [ ("score", `Int 87) ])
  | Error _ -> Alcotest.fail "unexpected error"

let test_format_error () =
  match Runtime.format_response (resp {|{"error":{"message":"Invalid API key"}}|}) with
  | Error m -> Alcotest.(check string) "err msg" "Invalid API key" m
  | Ok _ -> Alcotest.fail "expected error"

let test_format_bad_shape () =
  match Runtime.format_response (resp {|{"choices":[]}|}) with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected error"

let test_execute_fake () =
  let transport _ = Ok {|{"choices":[{"message":{"content":"hi"}}]}|} in
  match Runtime.execute ~transport (`Assoc []) with
  | Ok s -> Alcotest.(check string) "fake transport" "hi" s
  | Error _ -> Alcotest.fail "unexpected error"

let test_execute_transport_error () =
  let transport _ = Error "network down" in
  match Runtime.execute ~transport (`Assoc []) with
  | Error m -> Alcotest.(check string) "transport err" "network down" m
  | Ok _ -> Alcotest.fail "expected error"

let suite =
  ( "runtime",
    [ Alcotest.test_case "format text" `Quick test_format_text;
      Alcotest.test_case "format json" `Quick test_format_json;
      Alcotest.test_case "format error" `Quick test_format_error;
      Alcotest.test_case "format bad shape" `Quick test_format_bad_shape;
      Alcotest.test_case "execute fake" `Quick test_execute_fake;
      Alcotest.test_case "execute transport error" `Quick test_execute_transport_error ] )
```
Append `Test_runtime.suite` to the runner list in `test/test_promptdsl.ml`.

- [ ] **Step 2: Run to verify it fails**

`dune test 2>&1 | head -10` → `Unbound module Runtime`.

- [ ] **Step 3: Add `unix` to the library**

In `lib/dune`, change `(libraries yojson)` to `(libraries yojson unix)`.

- [ ] **Step 4: Implement `runtime`**

`lib/runtime.ml`:
```ocaml
let endpoint = "https://api.openai.com/v1/chat/completions"

type transport = string -> (string, string) result

(* Turn an OpenAI response into the text to print, or an error. Pure. *)
let format_response (resp : Yojson.Safe.t) : (string, string) result =
  let open Yojson.Safe.Util in
  match member "error" resp with
  | `Null -> (
      match member "choices" resp with
      | `List (c :: _) -> (
          match c |> member "message" |> member "content" with
          | `String content -> (
              match Yojson.Safe.from_string content with
              | exception _ -> Ok content
              | j -> Ok (Yojson.Safe.pretty_to_string j))
          | _ -> Error "unexpected response shape (no message content)")
      | _ -> Error "unexpected response shape (no choices)")
  | err -> (
      match member "message" err with
      | `String m -> Error m
      | _ -> Error "API error")

let execute ~(transport : transport) (request : Yojson.Safe.t) : (string, string) result =
  match transport (Yojson.Safe.to_string request) with
  | Error e -> Error e
  | Ok raw -> (
      match Yojson.Safe.from_string raw with
      | exception _ -> Error "invalid JSON response from API"
      | resp -> format_response resp)

(* Shell out to curl. The only piece not exercised by unit tests. *)
let curl_transport ~(api_key : string) : transport =
 fun body ->
  let tmp = Filename.temp_file "promptc" ".json" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove tmp with _ -> ())
    (fun () ->
      let oc = open_out tmp in
      output_string oc body;
      close_out oc;
      let cmd =
        Printf.sprintf "curl -sS -X POST %s -H %s -H %s -d @%s"
          (Filename.quote endpoint)
          (Filename.quote ("Authorization: Bearer " ^ api_key))
          (Filename.quote "Content-Type: application/json")
          (Filename.quote tmp)
      in
      let ic = Unix.open_process_in cmd in
      let out = In_channel.input_all ic in
      match Unix.close_process_in ic with
      | Unix.WEXITED 0 -> Ok out
      | _ -> Error (if out = "" then "curl request failed" else out))
```

- [ ] **Step 5: Run to verify it passes**

`dune build 2>&1 | head && dune test 2>&1 | tail -8 && ./scripts/check-corpus.sh`
Expected: the 6 `runtime` cases pass; all prior pass; corpus 25/25.

- [ ] **Step 6: Commit**

```bash
git add lib/runtime.ml lib/dune test/test_runtime.ml test/test_promptdsl.ml
git commit -m "feat(run): runtime module (format_response, execute, curl_transport)"
```

---

### Task 3: `run` CLI + driver + cram

**Files:** Modify `lib/driver.ml`, `bin/main.ml`; create `test/cram/run.t`.

- [ ] **Step 1: Add `run_run` to the driver**

In `lib/driver.ml`, add (it reuses `parse_set`, `read_file`, `print_diags`, `fs_resolver` already in the file):
```ocaml
let run_run (file : string) (sets : string list) : int =
  match Sys.getenv_opt "OPENAI_API_KEY" with
  | None | Some "" ->
      prerr_endline "OPENAI_API_KEY is not set";
      2
  | Some api_key -> (
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
              let resolver = fs_resolver (Filename.dirname file) in
              match Compile.compile_request ~values ~resolver src with
              | Error ds -> print_diags file ds; 1
              | Ok request -> (
                  match
                    Runtime.execute ~transport:(Runtime.curl_transport ~api_key) request
                  with
                  | Ok out -> print_string out; print_newline (); 0
                  | Error m -> prerr_endline m; 1))))
```

- [ ] **Step 2: Add the `run` subcommand to the CLI**

In `bin/main.ml`, add (next to `compile_cmd`/`check_cmd`, reusing `file_arg`/`set_arg`):
```ocaml
let run_cmd =
  let doc = "Compile a .prompt file and run it against the OpenAI API." in
  let term = Term.(const Driver.run_run $ file_arg $ set_arg) in
  Cmd.v (Cmd.info "run" ~doc) term
```
and add `run_cmd` to the `Cmd.group` command list (alongside `compile_cmd`, `check_cmd`).

- [ ] **Step 3: Build + manual checks (no network)**

```bash
dune build 2>&1 | head
printf 'agent "a" { goal "g" }\n' > /tmp/run_a.prompt
env -u OPENAI_API_KEY dune exec promptc -- run /tmp/run_a.prompt; echo "exit=$?"
```
Expected: `OPENAI_API_KEY is not set`, `exit=2`. And:
```bash
OPENAI_API_KEY=x dune exec promptc -- run /tmp/no_such.prompt; echo "exit=$?"
```
Expected: a `No such file or directory` message, `exit=2`. (A real call needs a real key; not run here.)

- [ ] **Step 4: Add the cram test (no network)**

`test/cram/run.t`:
```
run without an API key errors and exits 2:

  $ printf 'agent "a" { goal "g" }\n' > a.prompt
  $ env -u OPENAI_API_KEY promptc run a.prompt
  OPENAI_API_KEY is not set
  [2]

run on a missing file exits 2 (key set, fails before any network):

  $ OPENAI_API_KEY=x promptc run no-such.prompt
  [2]
```

- [ ] **Step 5: Record golden + verify**

```bash
dune runtest --auto-promote 2>&1 | tail -5
dune runtest 2>&1; echo "exit=$?"
```
Review `git diff test/cram/run.t`: first block shows `OPENAI_API_KEY is not set` + `[2]`; second shows a `no-such.prompt: No such file or directory` line + `[2]`. Confirm the other cram goldens are UNCHANGED. Re-run `dune runtest` → clean, exit 0.

- [ ] **Step 6: Final check**

```bash
dune runtest --force 2>&1 | tail -4
./scripts/check-corpus.sh
```
Expected: all unit + cram pass; corpus 25/25.

- [ ] **Step 7: Commit**

```bash
git add lib/driver.ml bin/main.ml test/cram/run.t
git commit -m "feat(run): promptc run subcommand; no-network cram coverage"
```

---

## Self-Review

**Spec coverage:**
- curl transport + endpoint + injected for tests → Task 2 (`curl_transport`, `transport` type).
- `OPENAI_API_KEY` (unset → exit 2) → Task 3 (`run_run`).
- content-or-empty user message → Task 1 (`render ?no_content_user`, `compile_request` passes `""`).
- print `choices[0].message.content`, pretty-if-json → Task 2 (`format_response`).
- error/exit codes (no key 2; compile 1; transport/non-JSON 1; `error` object 1; missing file 2) → Task 3 (`run_run`) + Task 2 (`execute`/`format_response`).
- testing: pure `format_response`, fake-transport `execute`, `compile_request` user message → Tasks 1–2; no-network cram → Task 3; real call manual → noted in spec.
- model default / sync / single backend → inherited from `compile_request` (uses existing `Backend_openai.render`).

**Placeholder scan:** none — full code per step; cram via `--auto-promote` with review criteria; the only untested piece (`curl_transport`) is explicitly called out and exercised manually in Task 3 Step 3.

**Type consistency:** `Backend_openai.render ?no_content_user`; `Compile.compile_request : … (Yojson.Safe.t, Error.t list) result`; `Runtime.transport = string -> (string,string) result`, `format_response : Yojson.Safe.t -> (string,string) result`, `execute : transport:transport -> Yojson.Safe.t -> (string,string) result`, `curl_transport : api_key:string -> transport`; `Driver.run_run : string -> string list -> int` wired in `bin/main.ml` like `compile_cmd`. `lib/dune` gains `unix` (Task 2) before `runtime.ml` uses `Unix`/`In_channel`.
