# promptc Model Selection (`--model`) — Design

**Date:** 2026-06-17
**Status:** Design — awaiting review

## Context

`compile --target` (④) and `run --target` (⑤) let the user pick a provider, but each
target's model is a hardcoded literal: `gpt-4o-mini` (OpenAI body), `claude-haiku-4-5-20251001`
(Anthropic body), and `gemini-2.5-flash` (Gemini — in the **URL**, since `generateContent`
takes no model in the body). This cut adds a `--model` flag so the user can override the model
per invocation, on both `compile` and `run`, for all three providers. The default (flag
omitted) reproduces today's behavior exactly.

**Surface decision (locked in brainstorming):** a **`--model` CLI flag only** — no DSL
`model:` field. Models are provider-specific and `--target` already selects the provider at
invocation time, so the model belongs at the same layer. A DSL field would bake a
provider-specific id into the `.prompt` and conflict with choosing `--target` at invocation.

**Scope (locked):** both `compile` and `run`. One caveat (below): on `compile --target gemini`
the emitted body carries no model, so `--model` is a no-op there — it only changes the live
`run` URL.

## Decisions (locked)

| Decision | Choice |
| --- | --- |
| Surface | `--model MODEL` flag on `compile` and `run`. No DSL field. |
| Default | Flag omitted → the target's built-in default (unchanged from ④/⑤). |
| Single source of truth | Per-target default becomes an exposed constant in each backend; `Runtime`'s provider record references it. |
| Validation | None — `--model` is a free string, passed through. Provider APIs validate at `run`; a model that doesn't match the target is the user's call (surfaces as a provider error at run). |
| Gemini compile caveat | `compile --target gemini` body has no `model` field, so `--model` does not change its `--emit json` output; it affects only the live `run` URL. OpenAI/Anthropic compile output does reflect `--model`. |

## Surface

```
promptc compile a.prompt --target anthropic --model claude-opus-4-8 --emit json
promptc run a.prompt --target openai --model gpt-4o --set ticker=TSLA
```

`--model` is optional; omitted → the per-target default.

## Components

- **`lib/backend_openai.ml`** — add `let default_model = "gpt-4o-mini"`; change
  `render ?(no_content_user = "{{input}}") (ir)` to also take
  `?(model = default_model)`, and use `model` for the body's `"model"` field (replacing the
  literal).
- **`lib/backend_anthropic.ml`** — add `let default_model = "claude-haiku-4-5-20251001"`;
  `render` gains `?(model = default_model)`, used for the body `"model"`.
- **`lib/backend_gemini.ml`** — add `let default_model = "gemini-2.5-flash"`. `render` is
  **unchanged** (the `generateContent` body has no `model` field). The constant exists so the
  runtime URL has a single source for the default.
- **`lib/compile.ml`** —
  - `compile_string` gains `?model` (`string option`), forwarded to the chosen renderer as
    `?model` (OpenAI/Anthropic; Gemini ignores it — its body has no model).
  - `compile_request` gains `?model` likewise (forwarded with `~no_content_user:""`).
- **`lib/runtime.ml`** — the `provider` record gains `default_model : string`; `endpoint`
  changes from `string -> string` to `model:string -> api_key:string -> string`.
  - `openai` — `default_model = Backend_openai.default_model`; `endpoint ~model:_ ~api_key:_ ->`
    the static URL.
  - `anthropic` — `default_model = Backend_anthropic.default_model`; static URL.
  - `gemini` — `default_model = Backend_gemini.default_model`;
    `endpoint ~model ~api_key:_ -> ".../v1beta/models/" ^ model ^ ":generateContent?key=" ^ key`
    (the api_key still goes in the query as today).
  - `curl_transport` gains `~model`, passed to `provider.endpoint`.
  - `execute` is unchanged.
- **`lib/driver.ml`** —
  - `run_compile` gains a trailing `model : string option` param, threaded into
    `compile_string ?model`.
  - `run_run` gains a trailing `model : string option` param: resolve
    `let model = match model with Some m -> m | None -> provider.Runtime.default_model in`,
    then pass it into both `Compile.compile_request ?model:(Some model)` (body) and
    `Runtime.curl_transport ~provider ~model ~api_key` (URL). (For OpenAI/Anthropic the resolved
    default equals the backend default, so omitting `--model` is byte-identical to ⑤.)
- **`bin/main.ml`** — add
  `let model_arg = Arg.(value & opt (some string) None & info ["model"] ~docv:"MODEL" ~doc)`;
  append `$ model_arg` to both `compile_cmd` and `run_cmd` terms (argument order matches the
  driver signatures).

## Data flow

```
compile: run_compile file emit sets target model_opt
           → compile_string ~target ?model:model_opt
               → Backend_{openai,anthropic}.render ?model  (body "model")
               → Backend_gemini.render                      (no model in body)

run:     run_run file sets target model_opt
           → model = model_opt ?? provider.default_model
           → compile_request ~target ?model:(Some model)    (body, OpenAI/Anthropic)
           → curl_transport ~provider ~model ~api_key       (Gemini URL uses model)
           → execute
```

## Error handling

No new error paths. `--model` is a valid optional string for cmdliner. An unknown/mismatched
model is rejected by the provider at `run` and surfaces through the existing `error.message`
extraction; at `compile` it is simply emitted in the body.

## Testing

- **`compile_request ~model:(Some "gpt-4o")`** (OpenAI) → body `"model"` is `"gpt-4o"`;
  **omitted** → `"gpt-4o-mini"`. Same for Anthropic with a Claude id.
- **`compile_string ~target:`Anthropic ~model:(Some "claude-opus-4-8")`** → body `"model"`
  reflects the override.
- **`Runtime.gemini.endpoint ~model:"gemini-2.0-flash" ~api_key:"K"`** contains
  `/v1beta/models/gemini-2.0-flash:generateContent?key=K`; **`Runtime.openai.endpoint`** is the
  static completions URL regardless of `~model`.
- **`Runtime.<p>.default_model`** equals the corresponding `Backend_<p>.default_model`.
- **cram:** `compile a.prompt --target openai --model gpt-4o --emit json | head -2` shows
  `"model": "gpt-4o"`; `compile a.prompt --emit json | head -2` (no flag) still shows
  `gpt-4o-mini`.
- Corpus `scripts/check-corpus.sh` stays 25/25 (no-flag path unchanged).

## Out of scope (later cuts)

A DSL `model:` field; validating the model against the target / a known catalog; per-model
defaults for `max_tokens`/effort; streaming; the other ⑤ "out of scope" items (retry/timeout,
token accounting, key-out-of-argv hardening).
