# promptc Multi-Backend (Anthropic + Gemini compile targets) — Design

**Date:** 2026-06-17
**Status:** Design — awaiting review

## Context

The roadmap's final cut turns the single-provider compiler into a multi-backend one:
`promptc compile <file> --target openai|anthropic|gemini` emits a valid request body
for the chosen provider. The provider-agnostic `Ir.t` was designed for exactly this —
today only `Backend_openai.render : Ir.t -> Yojson.Safe.t` is provider-specific, so the
cut is two sibling renderers plus a flag that selects one.

**Scope (locked in brainstorming):**

- Add **both** Anthropic and Gemini as `compile` targets. OpenAI stays the default.
- `--target` drives **`compile` only**. `run` stays OpenAI-only this cut (a multi-provider
  `run` needs per-provider endpoints, auth env vars, and response parsing — a separate cut).
- This cut emits request **bodies** only; it does not call any provider, so it is fully
  unit-testable with no network and no API keys.

All provider request shapes and model IDs below were verified against current provider
docs on 2026-06-17 (Anthropic Messages API + Structured Outputs; Gemini `generateContent`).

## Decisions (locked)

| Decision | Choice |
| --- | --- |
| Targets | `openai` (default), `anthropic`, `gemini`. |
| Flag | `compile --target (openai\|anthropic\|gemini)`, default `openai`. `check` / `run` unchanged. |
| Default models | OpenAI `gpt-4o-mini` (existing); Anthropic `claude-haiku-4-5-20251001`; Gemini `gemini-2.5-flash`. Hardcoded per target (matching how the model is hardcoded today). |
| Anthropic `max_tokens` | Required by the API → fixed default `1024`. |
| Prose backend | `Backend_prose.render` is provider-neutral and unchanged; it is the system text for all three targets. |
| Structured output | Per-provider equivalent of the typed `output json {fields}` schema (details below). |
| `--emit` interaction | `--emit json` / `both` emit the **target's** body; `--emit prose` is target-independent. |
| Out of scope | `--model` flag / DSL `model` field; multi-provider `run`; streaming; token/cost accounting; tool calls. |

## Surface

```
promptc compile agent.prompt                      # OpenAI body (default, unchanged)
promptc compile agent.prompt --target anthropic   # Anthropic Messages body
promptc compile agent.prompt --target gemini       # Gemini generateContent body
promptc compile agent.prompt --target gemini --emit both   # prose + Gemini body
```

Back-compat: omitting `--target` reproduces today's exact OpenAI output, so the corpus
and existing golden tests are unaffected.

## Request shapes (verified 2026-06-17)

### OpenAI (unchanged)

```json
{ "model": "gpt-4o-mini",
  "messages": [ {"role":"system","content":"<prose>"},
                {"role":"user","content":"<content-or-{{input}}>"} ],
  "response_format": { "type":"json_schema",
    "json_schema": { "name":"output", "schema": {<object>} } } }
```

`response_format` is present for `output json` (typed → `json_schema`; untyped →
`{"type":"json_object"}`); absent for `text` / `markdown`.

### Anthropic (Messages API)

- `POST https://api.anthropic.com/v1/messages`
- Headers (documented in spec, not part of the emitted body): `content-type: application/json`,
  `anthropic-version: 2023-06-01`, `x-api-key: $ANTHROPIC_API_KEY`.
- `system` is a **top-level** string (not a message). `model` + `max_tokens` + `messages` required.
- Structured output uses the current production `output_config.format` (no beta header);
  the schema is **standard lowercase JSON Schema**, identical to OpenAI's — so the two
  backends share the schema builder.

```json
{ "model": "claude-haiku-4-5-20251001",
  "max_tokens": 1024,
  "system": "<prose>",
  "messages": [ {"role":"user","content":"<content-or-{{input}}>"} ],
  "output_config": { "format": { "type":"json_schema", "schema": {<object>} } } }
```

- `output json {fields}` (typed) → include `output_config`.
- untyped `json` / `text` / `markdown` → **omit** `output_config` (Anthropic has no
  `json_object` mode; the prose system text already instructs the format).

### Gemini (`generateContent`)

- `POST https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$GEMINI_API_KEY`
- The model lives in the **URL path**, so the emitted **body carries no model field**
  (a `model` key is not a valid `generateContent` body field). The spec documents the URL.
- `systemInstruction` and `contents` use `parts[].text`. Schema types are **UPPERCASE**.

```json
{ "systemInstruction": { "parts": [ {"text":"<prose>"} ] },
  "contents": [ {"role":"user","parts":[ {"text":"<content-or-{{input}}>"} ]} ],
  "generationConfig": { "responseMimeType":"application/json",
                        "responseSchema": {<UPPERCASE object>} } }
```

- `output json {fields}` (typed) → `responseMimeType` + `responseSchema`.
- untyped `json` → `generationConfig` with `responseMimeType:"application/json"` only.
- `text` / `markdown` → **omit** `generationConfig`.

## Type → schema mapping

| `Ir.schema_ty` | OpenAI / Anthropic (shared, lowercase) | Gemini (uppercase) |
| --- | --- | --- |
| `SString` | `{"type":"string"}` | `{"type":"STRING"}` |
| `SInt` | `{"type":"integer"}` | `{"type":"INTEGER"}` |
| `SBool` | `{"type":"boolean"}` | `{"type":"BOOLEAN"}` |
| `SFloat` | `{"type":"number"}` | `{"type":"NUMBER"}` |
| `SEnum opts` | `{"type":"string","enum":[…]}` | `{"type":"STRING","enum":[…]}` |
| `SList t` | `{"type":"array","items":<t>}` | `{"type":"ARRAY","items":<t>}` |
| range `(lo,hi)` | `"minimum"`/`"maximum"` (int → `Int`, else `Float`) | `"minimum"`/`"maximum"` (same) |
| object | `{type:"object", properties, required, "additionalProperties":false}` | `{type:"OBJECT", properties, required}` (no `additionalProperties`) |

The lowercase object/range builder is **shared** by OpenAI and Anthropic. Gemini has its
own type renderer (uppercase, no `additionalProperties`) but reuses the same `Ir` data.

## Components

- **`lib/backend_common.ml`** (NEW) — the shared, provider-neutral pieces lifted out of
  `backend_openai.ml`:
  - `user_message ?(no_content_user = "{{input}}") (ir : Ir.t) : string` — `ir.content`
    or the placeholder.
  - `json_of_ty : Ir.schema_ty -> Yojson.Safe.t` — lowercase type JSON.
  - `with_range : Ir.schema_field -> Yojson.Safe.t -> Yojson.Safe.t` — append
    `minimum`/`maximum` (int bounds as `Int`, else `Float`).
  - `schema_object : Ir.schema_field list -> Yojson.Safe.t` — the
    `{type:object, properties (with range), required, additionalProperties:false}` object,
    shared by OpenAI's `response_format` and Anthropic's `output_config.format`.
- **`lib/backend_openai.ml`** (refactor, behavior identical) — `render` uses
  `Backend_common.user_message`; `response_format fields` wraps
  `Backend_common.schema_object fields` as `{type:json_schema, json_schema:{name:output, schema:<object>}}`.
  Output byte-for-byte unchanged (guarded by existing goldens).
- **`lib/backend_anthropic.ml`** (NEW) — `render : Ir.t -> Yojson.Safe.t` produces the
  Messages body above; typed json adds `output_config.format` wrapping
  `Backend_common.schema_object`; untyped/text/markdown omit it.
- **`lib/backend_gemini.ml`** (NEW) — `render : Ir.t -> Yojson.Safe.t` produces the
  `generateContent` body above with its own uppercase `gemini_of_ty` /
  `gemini_schema_object` (no `additionalProperties`); range as `minimum`/`maximum`.
- **`lib/compile.ml`** — `compile_string` gains `?(target = `OpenAI)` and dispatches the
  JSON renderer: `OpenAI -> Backend_openai.render` / `Anthropic -> Backend_anthropic.render`
  / `Gemini -> Backend_gemini.render`. Prose is unchanged. (`compile_request`, used by
  `run`, stays OpenAI-only and is untouched.)
- **`lib/driver.ml`** — `run_compile` gains a `target` parameter, threaded into
  `compile_string ~target`.
- **`bin/main.ml`** — `compile` gains `--target` (`Arg.enum [openai;anthropic;gemini]`,
  default `openai`), wired into `Driver.run_compile`.

## Error handling

`--target` is a closed enum; cmdliner rejects unknown values with its standard usage error
(exit 2). No new runtime error paths — every target renders any valid `Ir.t` total over the
`output` and `schema_ty` variants (warning-8 keeps the matches exhaustive).

## Testing

Unit (alcotest), per new backend (`backend_anthropic`, `backend_gemini`), asserting exact
request JSON:

- **text** agent → no structured-output field; correct system/user placement.
- **untyped json** agent → Anthropic: no `output_config`; Gemini: `responseMimeType` only.
- **typed json** agent exercising `enum`, `list`, and a `range` field → schema matches the
  mapping table (lowercase for Anthropic, UPPERCASE for Gemini; `additionalProperties:false`
  present for Anthropic, absent for Gemini; `minimum`/`maximum` present).
- **no-content** agent → user message / first part is `{{input}}`.
- **OpenAI refactor guard** → existing OpenAI unit + golden tests stay green (byte-identical).

cram (golden, no network):

- `compile --target anthropic` and `--target gemini` on a representative typed-json agent.
- `--target openai` (and the default) produce today's output (regression guard).

Corpus: `scripts/check-corpus.sh` stays 25/25 (default target unchanged).

## Out of scope (later cuts)

A `--model` flag or DSL `model:` field; multi-provider `run` (calling Anthropic/Gemini);
streaming; multiple candidates; tool/function calling; token/cost accounting; per-provider
temperature/top_p knobs.
