# promptc

A Prompt DSL compiler. Write a structured `.prompt` file describing an agent's
goal, steps, inputs, and output, then **compile** it to a human-readable prompt
and a provider API request, or **run** it against OpenAI, Anthropic, or Gemini.

## Build

    opam install dune menhir yojson cmdliner alcotest
    dune build

Run via `dune exec promptc -- <command> ...` (or the built binary at
`./_build/default/bin/main.exe`).

## Commands

| Command | What it does |
| --- | --- |
| `check <file>` | Parse and semantically check the file; prints `OK` (exit 0) or diagnostics (exit 1). |
| `compile <file>` | Compile to human-readable prose and/or a provider request JSON, and print it. Does **not** call any API. |
| `run <file>` | Compile, then actually call the provider and print the reply. |

### Options (shared by `compile` and `run` unless noted)

- `--emit prose|json|both` — `compile` only; default `prose`. Emit the prose, the
  request JSON, or both.
- `--target openai|anthropic|gemini` — default `openai`. Selects the provider.
- `--model <id>` — override the target's default model
  (`gpt-4o-mini` / `claude-haiku-4-5-20251001` / `gemini-2.5-flash`).
- `--set KEY=VALUE` — bind an `input` variable (repeatable); replaces `{{KEY}}`.

```bash
# Inspect the compiled output (no network, no key)
dune exec promptc -- compile examples/researcher.prompt --emit both
dune exec promptc -- compile agent.prompt --target gemini --emit json
dune exec promptc -- compile agent.prompt --target anthropic --model claude-opus-4-8 --emit json

# Call the provider for real
export OPENAI_API_KEY=sk-...        # or ANTHROPIC_API_KEY / GEMINI_API_KEY
dune exec promptc -- run agent.prompt --set ticker=TSLA
dune exec promptc -- run agent.prompt --target anthropic --set ticker=TSLA
```

`run` reads the key for the chosen target: `openai` → `OPENAI_API_KEY`,
`anthropic` → `ANTHROPIC_API_KEY`, `gemini` → `GEMINI_API_KEY`. A missing key
prints `<VAR> is not set` and exits 2.

## Language

```
agent "researcher" {
  input { ticker: string }                 # compile-time variables (bind with --set)
  goal "analyze {{ticker}} earnings"        # {{...}} is substituted at compile time

  step { search "{{ticker}} earnings" }
  step { summarize }

  output json {                             # text | markdown | json (+ optional schema)
    rating:  enum("buy", "hold", "sell")
    score:   int(0..100)                    # numeric fields may carry a range
    margin:  float
    notes:   string?                        # ? marks an optional field
    tags:    list<string>
  }
}
```

- **Actions:** `search`, `summarize`, `extract`, `translate`, `classify`, `instruct "..."`.
- **Output:** `text` | `markdown` | `json` (with an optional typed schema).
- **Field types:** `string`, `int`, `bool`, `float`, `enum(...)`, `list<T>`; suffix `?`
  marks a field optional; `int`/`float` fields may add a `(lo..hi)` range.
- **Reuse:**
  - `import "lib.prompt" as x` — import definitions from another file.
  - `def name = "..."` — a reusable fragment, referenced as `{{x.name}}`.
  - `agent "y" extends x.Template { ... }` — inherit a template (whole-clause override).
- **`@content`:** mark one input `@content` to use its bound value as the user message
  when running. Without it, the compiled request's user message is the `{{input}}`
  placeholder (and empty at `run` time).

## Provider output notes

The prose backend is provider-neutral; only the request JSON differs per `--target`:

- **OpenAI** — Chat Completions: `messages` (system + user), and for `output json` a
  `response_format` (`json_schema` for a typed schema, `json_object` for bare `json`).
  Reply read from `choices[0].message.content`.
- **Anthropic** — Messages API: system prompt at the top level, `max_tokens`, and for a
  typed schema `output_config.format` (`json_schema`). Headers (`x-api-key`,
  `anthropic-version`) are added by `run`, not part of the emitted body. Reply read from
  the first `content[]` text block.
- **Gemini** — `generateContent`: `systemInstruction` + `contents`, and for a typed schema
  `generationConfig.responseSchema` (UPPERCASE OpenAPI types). The **model lives in the URL**,
  so it is not in the emitted body — `--model` only affects the live `run` URL, not
  `compile --target gemini` output. Reply read from `candidates[0].content.parts[0].text`.

Typed schemas are non-strict, so optional `?` fields are allowed.

## Tests

    dune test                    # unit + cram golden tests
    bash scripts/check-corpus.sh # every corpus/ agent still compiles
