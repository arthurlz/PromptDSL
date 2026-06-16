# promptc run (Runtime) — Design

**Date:** 2026-06-15
**Status:** Design — awaiting review

## Context

`requirements.md` and the roadmap call for turning the compiler into a
**compiler + runtime**: `promptc run agent.prompt --set ...` should actually call
the LLM and print the result (the roadmap's "Score: 87 / Summary: …"). Today
`promptc compile` produces an OpenAI Chat Completions request as JSON; this cut
adds a thin runtime that POSTs that request to OpenAI and prints the model's reply.

It is unblocked by inputs (compile-time `--set` binding). Provider is **OpenAI**
(the only backend); a multi-provider `run` is deferred to the multi-backend cut.

**Testability note:** the real network call can't be exercised in CI / this
environment (no API key, and we must not spend real tokens). The design therefore
makes the transport an **injected function**, so the full run flow (build → send →
parse → format) is unit-tested with a fake transport returning canned JSON; only
the ~5-line `curl` transport itself is untested and is exercised manually.

## Decisions (locked)

| Decision | Choice |
| --- | --- |
| Transport | Shell out to `curl` (POST to `https://api.openai.com/v1/chat/completions`), injected as a function for testing. |
| API key | `OPENAI_API_KEY` env var (unset → error, exit 2). |
| Model | The existing compiled default (`gpt-4o-mini`). |
| Mode | Synchronous (one request; no streaming). |
| User message | **content-or-empty**: the bound `@content` value if the agent has one, else `""`. Never the literal `{{input}}`. |
| Output | Print `choices[0].message.content`; if that content parses as JSON, pretty-print it, else print it raw. |
| Errors | no key → exit 2; compile error → diagnostics, exit 1; transport failure / non-JSON response → exit 1; response contains an `error` object → print `error.message`, exit 1. |

## Surface

```
export OPENAI_API_KEY=sk-...
promptc run earnings-analyst.prompt --set ticker=TSLA
# -> the model's reply (pretty JSON if the agent's output is json, else text)
```

`run` reuses the existing `--set k=v` (repeatable) for input binding. No new flags.

## Pipeline

```
promptc run <file> --set... 
  → compile_request (frontend → bind → lower → OpenAI request JSON, user = content-or-empty)
  → Runtime.execute ~transport:(curl_transport ~api_key) request
       → transport (POST) → parse response JSON → format_response
  → print output / diagnostics
```

## Components

- **`lib/backend_openai.ml`** — `render` gains `?(no_content_user = "{{input}}")`; the
  user message for `content = None` uses `no_content_user`. `compile_string` keeps the
  default (`"{{input}}"`, the compiled-template placeholder); the run path passes `""`.
- **`lib/compile.ml`** — `compile_request ?(values=[]) ?(resolver=default_resolver) (src)
  : (Yojson.Safe.t, Error.t list) result` = `frontend` → `Bind.bind` → `Lower.lower` →
  `Backend_openai.render ~no_content_user:"" ir`.
- **`lib/runtime.ml`** (NEW):
  - `type transport = string -> (string, string) result` — request body (JSON string)
    → raw response body, or an error string.
  - `curl_transport ~api_key : transport` — writes the body to a temp file and runs
    `curl -sS -X POST <endpoint> -H "Authorization: Bearer <key>" -H "Content-Type:
    application/json" -d @<file>`, capturing stdout; a curl failure (non-zero / no
    output) → `Error`. (The only untested piece.)
  - `format_response : Yojson.Safe.t -> (string, string) result` — if the response has
    an `error` object → `Error error.message`; else extract `choices[0].message.content`
    (missing → `Error "unexpected response shape"`); if the content parses as JSON,
    return it pretty-printed, else return it raw. **Pure.**
  - `execute ~transport (request : Yojson.Safe.t) : (string, string) result` —
    `transport (to_string request)` → parse raw as JSON (non-JSON → error) →
    `format_response`. **Testable with a fake transport.**
- **`lib/driver.ml`** — `run_run (file) (sets) : int`: parse `--set` (reuse `parse_set`);
  read `OPENAI_API_KEY` (unset → message, exit 2); read file (Sys_error → exit 2);
  `compile_request` (Failure → diagnostics, exit 1); `Runtime.execute
  ~transport:(Runtime.curl_transport ~api_key)` (Error → stderr, exit 1; Ok s → print, 0).
- **`bin/main.ml`** — a `run` subcommand (`promptc run <file> --set k=v`), wired like
  `compile`.

## Error handling

All errors to stderr, output to stdout. Exit codes per the decisions table. The
`error.message` from an OpenAI error body is surfaced verbatim (e.g. invalid key,
rate limit, model errors).

## Testing

- **`render ~no_content_user:""`** → a no-content agent's user message is `""`.
- **`compile_request`** → an `@content` agent's request user message is the bound
  value; a no-content agent's is `""` (not `{{input}}`).
- **`format_response`** (pure): a `choices[0].message.content` of plain text → printed
  raw; a JSON-string content → pretty-printed; an `error` object → `Error` with its
  message; a missing-choices shape → `Error`.
- **`execute` with a fake transport** returning canned JSON → end-to-end output without
  network (the key testability win).
- **cram (no network):** `promptc run a.prompt` with `OPENAI_API_KEY` unset → the
  "not set" diagnostic and `[2]`; `run` on a missing file → `[2]`.
- **Manual (documented in the spec/README):** with a real `OPENAI_API_KEY`,
  `promptc run examples/... --set ...` returns a real completion. Not in CI.

## Out of scope (later cuts)

Streaming; multi-provider `run` (Anthropic/Gemini — the multi-backend cut); retry /
timeout / temperature / model flags; multiple choices; tool-call execution; token/cost
accounting; caching.
