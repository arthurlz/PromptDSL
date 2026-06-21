# promptc TypeScript Typed Client Codegen — Design

**Date:** 2026-06-17
**Status:** Design — awaiting review

## Context

`promptc` compiles a `.prompt` agent to provider request JSON and can `run` it, but to
*use* an agent from an application you still hand-write the call + response parsing + types.
This cut adds `promptc codegen <file> --target <p>`, which emits a **self-contained,
zero-dependency TypeScript file**: a typed function `agentName(inputs) → Promise<Output>`
that builds the request, calls the provider (global `fetch` + `process.env`), extracts the
reply, validates it, and returns the typed result. This is the "typed LLM function" payoff
that makes the output schema worth declaring — the same idea as BAML's generated client.

**Decisions locked in brainstorming:**
- **Zero-dep callable client** — one `.ts` file, no npm install, no shared runtime package.
- **Generated runtime validator** — hand-written, zero-dep checks that throw on mismatch
  (not a bare cast, not zod).
- **TS only** this cut; **one provider per generated file** (chosen by `--target`).

The per-provider request shapes and response paths were verified against live docs earlier
this session (cuts ④/⑤) and live in `Backend_<p>` / `Runtime.<p>`; the generated TS mirrors
them exactly — no new API facts are invented.

## Decisions (locked)

| Decision | Choice |
| --- | --- |
| Command | `promptc codegen <file> [--target openai\|anthropic\|gemini] [--model <id>] [-o out.ts]`; default target `openai`, default output stdout. Reuses the existing `target_arg`/`model_arg`. |
| Artifact | One self-contained `.ts`: exported `Inputs` type, exported `Output` type, a validator, and an exported `async` function. Uses global `fetch` and `process.env.<KEY>`. |
| Output validation | A generated zero-dep validator: required/type/enum/list-element/numeric-range checks; throws `Error("<field>: …")` on mismatch. `text`/`markdown` → `string` (no validate); bare `output json` (no schema) → `unknown` (parse only). |
| Inputs | `checked.inputs` → a typed `Inputs` object param. An input with a default → optional property (default applied at call time). The `@content` input → the user message; no `@content` → user message `""` (matches `run`). |
| Fragments vs inputs | Fragment refs (`{{alias.def}}`, compile-time `def`s) are resolved at codegen time; **input** refs (`{{name}}`) are left as holes and become `${inputs.name}` in the generated TS. |
| Naming | Agent name → sanitized identifiers: `PascalCase` for `Inputs`/`Output` types, `camelCase` for the function; non-identifier characters replaced. |

## Architecture

New module **`lib/codegen_ts.ml`** with
`generate : Sema.checked -> Resolve.fragments -> target:[ \`OpenAI | \`Anthropic | \`Gemini ]
-> model:string option -> string` (returns the `.ts` source).

It hooks **after `Compile.frontend`** (which returns `(checked, fragments)`); it does **not**
call `Bind.bind` (binding errors on unbound inputs). Steps:

1. **Build a template `Bind.bound` directly** (the record is public) — no interpolation of
   inputs:
   - `b_name = checked.name`
   - `b_goal = Interp.subst frag_lookup checked.goal`
   - `b_steps = checked.steps` with each `arg` run through `Interp.subst frag_lookup`
   - `b_output = checked.output`
   - `b_content = ` `Some "{{<name>}}"` if an input has `@content` (the hole), else
     `if checked.has_input_block then Some "" else None`

   where `frag_lookup` resolves **dotted** (fragment) refs via `Resolve.lookup fragments …`
   (same as `Bind`) but returns `None` for **bare** names — so `Interp.subst` resolves
   fragments and **leaves input holes intact**.
2. **`Lower.lower template_bound`** → a "template `Ir.t`" whose `objective`/`instructions`/
   `content` still contain `{{name}}` holes (reuses `Lower.render_instruction`,
   `Lower.output_to_ir`).
3. **`Backend_<target>.render ~no_content_user:"" template_ir`** → the request `Yojson.Safe.t`
   with `{{name}}` holes preserved in string values, the exact per-provider body shape
   (schema included). `~no_content_user:""` matches the `run`/`compile_request` convention
   (no-`@content` agents get an empty user message, not the `{{input}}` placeholder).
4. **Emit the `.ts`** (details below).

This reuses the entire existing rendering pipeline; the only genuinely new logic is the TS
emitter.

## The TS emitter

- **`Inputs` type** — from `checked.inputs`: `TString`→`string`, `TInt`/`TFloat`→`number`,
  `TBool`→`boolean`, `TEnum[a,b]`→`"a" | "b"`. An input with a default → optional property.
- **`Output` type** — from `checked.output` via the `Ir.schema_ty` mapping: `SString`→`string`,
  `SInt`/`SFloat`→`number`, `SBool`→`boolean`, `SEnum`→union, `SList t`→`T[]`, `required:false`
  →`?`. `text`/`markdown`→`string`; bare json (no schema)→`unknown`.
- **Validator** — `function validate<Name>Output(x: any): <Output>`: for each field, check
  presence when required, `typeof` for scalars, `Array.isArray` + element checks for `list<T>`
  (recursive), enum membership via `includes`, and `minimum`/`maximum` for ranged numeric
  fields; `throw new Error("<field>: …")` on mismatch; `return x` at the end. Emitted only for
  typed `output json`.
- **Request body** — render the step-3 `Yojson.Safe.t` as a **TS expression**: emit objects/
  arrays/numbers/bools as their literal TS form; for a `` `String s `` that contains `{{…}}`,
  emit a **template literal** with each `{{name}}` rewritten to `${inputs.name}` (escaping
  `` ` ``, `\`, and `${`); plain strings emit as JSON string literals. (`{{name}}` here is
  always a declared input — fragments were already resolved in step 1, and sema guarantees no
  other refs.)
- **The function** — `export async function <name>(inputs: <Inputs>): Promise<<Output>>` that
  `fetch`es the per-target endpoint with the per-target headers/key, then extracts + returns:
  - OpenAI: `POST https://api.openai.com/v1/chat/completions`, header
    `authorization: Bearer ${process.env.OPENAI_API_KEY ?? ""}`; reply
    `j.choices?.[0]?.message?.content`.
  - Anthropic: `POST https://api.anthropic.com/v1/messages`, headers
    `x-api-key: ${process.env.ANTHROPIC_API_KEY ?? ""}` + `anthropic-version: 2023-06-01`;
    reply = first `j.content[]` with `type === "text"` → `.text`.
  - Gemini: `POST https://generativelanguage.googleapis.com/v1beta/models/<model>:generateContent?key=${process.env.GEMINI_API_KEY ?? ""}`;
    reply `j.candidates?.[0]?.content?.parts?.[0]?.text`.
  - All: if `j.error` → `throw new Error(j.error.message)`. Then for typed json:
    `return validate<Name>Output(JSON.parse(text))`; bare json: `return JSON.parse(text)`;
    text/markdown: `return text`.

The default model per target comes from `Backend_<p>.default_model`; `--model` overrides it.
For OpenAI/Anthropic the model rides in the body, so it is threaded into
`Backend_openai.render ?model` / `Backend_anthropic.render ?model` in step 3. For Gemini the
model is **not** in the body (`Backend_gemini.render` takes no `?model`); codegen emits it into
the `generateContent` URL instead (using the override or `Backend_gemini.default_model`).

## Components

- **`lib/codegen_ts.ml`** (NEW) — `generate` + private helpers (`ts_type_of_ast_ty`,
  `ts_type_of_schema`, validator emitter, `yojson_to_ts` interpolating emitter, identifier
  sanitizer, per-target call snippet).
- **`lib/driver.ml`** — `run_codegen (file) (target) (model) (output : string option) : int`:
  read file → `Compile.frontend` (Error → diagnostics, exit 1) → `Codegen_ts.generate` →
  write to `output` file or stdout. (`frontend` already returns `(checked, fragments)`.)
- **`bin/main.ml`** — `output_arg` (`-o`/`--output`, `opt (some string) None`) and a
  `codegen_cmd` wired like `compile_cmd`, reusing `target_arg`/`model_arg`.

## Error handling

Codegen-time: a parse/sema error → existing diagnostics, exit 1 (same as `compile`). Runtime
(in the generated client): a provider `error` object → `throw new Error(error.message)`; a
schema-mismatched reply → the validator throws `Error("<field>: …")`; a missing key → empty
bearer/key, the provider rejects, surfaced as the thrown error. No new OCaml error paths.

## Testing

- **Unit (alcotest), `Codegen_ts.generate`:** assert on the generated string for a typed-json
  agent (enum → union, optional `?`, `list<T>` → `T[]`, a validator function present, the
  function signature `async function <name>(inputs: <Name>Inputs): Promise<<Name>Output>`);
  a `text` agent → `Promise<string>` and no validator; per-target spot checks (OpenAI
  `authorization` header / Anthropic `x-api-key` + `anthropic-version` / Gemini model in URL);
  `--model` reflected.
- **cram golden:** `codegen researcher.prompt --target openai|anthropic|gemini` → the `.ts`
  (deterministic; captured via the repo's normal cram flow).
- **TS compile smoke (if available):** if `node`/`tsc` is on PATH, `tsc --noEmit` the generated
  file in one cram/case to prove it type-checks; otherwise rely on golden + structural asserts.
  (The plan checks availability and degrades gracefully — not a hard CI dep.)
- Corpus `scripts/check-corpus.sh` stays 25/25 (codegen is additive; no existing output
  changes).

## Out of scope (later cuts)

Python (or other languages); multiple providers in one generated file; streaming; `zod`
output; an `@promptc/runtime` package / bundling; tool-call execution; retry/timeout;
validating inputs at the TS boundary beyond their static types.
