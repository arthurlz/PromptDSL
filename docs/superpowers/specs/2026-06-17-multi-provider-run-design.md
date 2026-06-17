# promptc Multi-provider `run` — Design

**Date:** 2026-06-17
**Status:** Design — awaiting review

## Context

`promptc run` (cut ③) calls **OpenAI** and prints the reply; `compile --target` (cut ④)
can already *emit* Anthropic and Gemini request bodies but not *run* them. This cut closes
that gap: `promptc run <file> --target openai|anthropic|gemini` calls the chosen provider
and prints its reply. It mirrors `compile --target`; OpenAI stays the default.

The ④ request renderers (`Backend_anthropic`, `Backend_gemini`) already produce valid
request bodies. The new work is the **runtime** side: per-provider endpoint, auth, env var,
and **response parsing** (the three providers return the reply in different shapes).

OCaml has no official Anthropic/Gemini SDK, so raw `curl` (as the existing OpenAI `run`
already uses) is the correct transport. All provider request/response shapes, headers, and
model IDs below were verified against current provider docs on 2026-06-17 (Anthropic Messages
API; Gemini `generateContent`).

**Testability:** as in ③, the transport is an **injected function**, so the full flow
(build → send → parse → extract → format) is unit-tested with a fake transport returning
canned JSON. Only the per-provider `curl` transport is untested and exercised manually.

## Decisions (locked)

| Decision | Choice |
| --- | --- |
| Targets | `openai` (default), `anthropic`, `gemini` — same enum as `compile`. |
| Flag | `run --target (openai\|anthropic\|gemini)`, default `openai`. `compile`/`check` unchanged. |
| Env var per target | `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` / `GEMINI_API_KEY` (unset/empty → exit 2, provider-specific message). |
| Transport | `curl` POST, injected for tests (as ③). Key rides in `-H` (OpenAI/Anthropic) or the URL (Gemini) — visible in `ps`, consistent with the existing OpenAI transport; no stdin/config hardening this cut. |
| Models | The compiled defaults from ④: `gpt-4o-mini` / `claude-haiku-4-5-20251001` / `gemini-2.5-flash` (Gemini's lives in the URL). |
| User message | **content-or-empty**: the bound `@content`, else `""` (never the `{{input}}` placeholder). Same rule as ③, now for all three. |
| Output | Per provider: extract the reply text; if it parses as JSON, pretty-print it, else print raw (③'s behavior, now provider-neutral). |
| Errors | no key → exit 2; compile error → diagnostics, exit 1; transport failure / non-JSON response → exit 1; response has an `error` object → print `error.message`, exit 1. (Same as ③.) |

## Verified provider facts (2026-06-17)

| Provider | Endpoint | Auth | Reply text path | Error path |
| --- | --- | --- | --- | --- |
| OpenAI | `https://api.openai.com/v1/chat/completions` | header `Authorization: Bearer $KEY` | `choices[0].message.content` | `error.message` |
| Anthropic | `https://api.anthropic.com/v1/messages` | headers `x-api-key: $KEY` + `anthropic-version: 2023-06-01` | first `content[]` block with `type:"text"` → its `text` | top-level `error.message` |
| Gemini | `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$KEY` | key in URL query | `candidates[0].content.parts[0].text` | top-level `error.message` |

All three error envelopes expose the human message at `error.message`, so the error branch is
shared; only the success-text path differs.

## Surface

```
export ANTHROPIC_API_KEY=sk-ant-...
promptc run earnings-analyst.prompt --target anthropic --set ticker=TSLA
# -> Claude's reply (pretty JSON if the agent's output is json, else text)
```

`run` reuses `--set k=v` (repeatable). No new flags beyond `--target`.

## Components

- **`lib/runtime.ml`** — replace the OpenAI-hardcoded constants with a `provider` record and
  three values:

  ```ocaml
  type provider = {
    env_var  : string;
    endpoint : string -> string;                         (* api_key -> URL *)
    headers  : string -> (string * string) list;          (* api_key -> extra headers *)
    extract  : Yojson.Safe.t -> (string, string) result;  (* response -> reply text | error *)
  }
  ```

  - `openai` — `endpoint` ignores the key (static URL); `headers k = [("Authorization","Bearer "^k)]`;
    `extract` = error-object → `error.message`, else `choices[0].message.content` (missing → error).
  - `anthropic` — static URL; `headers k = [("x-api-key",k); ("anthropic-version","2023-06-01")]`;
    `extract` = error-object → `error.message`, else the first `content[]` block whose `type` is
    `"text"` → its `text` (none → error).
  - `gemini` — `endpoint k = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=" ^ k`;
    `headers _ = []`; `extract` = error-object → `error.message`, else
    `candidates[0].content.parts[0].text` (missing → error).
  - `pretty_if_json : string -> string` (NEW, shared) — pretty-print the reply if it parses as
    JSON, else return it unchanged. (Lifted out of today's `format_response`.)
  - `execute ~(provider : provider) ~transport (request : Yojson.Safe.t) : (string,string) result`
    — `transport (to_string request)` → parse raw as JSON (non-JSON → error) →
    `provider.extract` → `pretty_if_json`.
  - `curl_transport ~provider ~api_key : transport` — writes the body to a temp file and runs
    `curl -sS -X POST <provider.endpoint api_key> -H "Content-Type: application/json"
    -H <each provider.headers entry> -d @<file>`; non-zero / empty → `Error`. (The only untested
    piece.)
- **`lib/compile.ml`** — `compile_request` gains
  `?(target : [ `OpenAI | `Anthropic | `Gemini ] = `OpenAI)` and dispatches the renderer
  (`Backend_openai.render` / `Backend_anthropic.render` / `Backend_gemini.render`), each with
  `~no_content_user:""`.
- **`lib/backend_anthropic.ml`, `lib/backend_gemini.ml`** — `render` gains
  `?(no_content_user = "{{input}}")` (mirroring OpenAI), threaded into
  `Backend_common.user_message ~no_content_user`. The ④ compile path keeps the default, so
  `compile --target` output is unchanged.
- **`lib/driver.ml`** — `run_run` gains the `target` parameter: pick the provider, read
  `provider.env_var` (unset/empty → message naming that var, exit 2), parse `--set`, read file,
  `compile_request ~values ~resolver ~target` (Error → diagnostics, exit 1),
  `Runtime.execute ~provider ~transport:(Runtime.curl_transport ~provider ~api_key)` (Error →
  stderr, exit 1; Ok → print, 0).
- **`bin/main.ml`** — the existing `target_conv`/`target_arg` (from ④) are reused; the `run`
  command's term gains `$ target_arg`, wired into `Driver.run_run`.

## Error handling

All errors to stderr, output to stdout. Exit codes per the decisions table — identical to ③,
now keyed to the selected provider's env var and `error.message`.

## Testing

- **`extract` (pure), per provider:** a normal success response → the reply text; a typed-JSON
  reply string → pretty-printed by `pretty_if_json`; an `error` object → `Error error.message`;
  a missing/malformed success shape → `Error`. (Anthropic: a `content` array whose first block
  is `text`. Gemini: `candidates[0].content.parts[0].text`.)
- **`execute` with a fake transport**, per provider, returning canned JSON → end-to-end reply
  with no network.
- **`compile_request ~target`** → the request body is the chosen provider's shape with the user
  message = bound `@content` (or `""` when none), not `{{input}}`.
- **cram (no network):** `promptc run a.prompt --target anthropic` with `ANTHROPIC_API_KEY`
  unset → "ANTHROPIC_API_KEY is not set" and `[2]`; likewise `--target gemini` →
  "GEMINI_API_KEY is not set"; default (`--target openai`) keeps ③'s "OPENAI_API_KEY is not set".
- **Manual (documented):** with a real key, `promptc run examples/... --target anthropic`
  returns a real completion. Not in CI.

Corpus (`scripts/check-corpus.sh`) is unaffected (run/compile output for the default path is
unchanged) and must stay 25/25.

## Out of scope (later cuts)

`--model` flag / DSL `model:` field; streaming; retry / timeout; multiple candidates;
tool-call execution; token/cost accounting; moving the API key out of `curl` argv (stdin /
`--config` hardening).
