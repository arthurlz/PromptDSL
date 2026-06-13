# promptc

A Prompt DSL compiler. Write a structured `.prompt` file describing an agent's
goal and steps, and compile it to a human-readable prompt and an OpenAI Chat
Completions request.

## Build

    opam install dune menhir yojson cmdliner alcotest
    dune build

## Usage

    dune exec promptc -- compile examples/researcher.prompt --emit prose
    dune exec promptc -- compile examples/researcher.prompt --emit json
    dune exec promptc -- compile examples/researcher.prompt --emit both
    dune exec promptc -- check examples/researcher.prompt

## Language

    agent "researcher" {
      goal "analyze TSLA earnings"

      step { search "TSLA earnings" }
      step { summarize }

      output json {
        ticker:  string
        rating:  enum("buy", "hold", "sell")
        summary: string
      }
    }

- Actions: `search`, `summarize`, `extract`, `translate`, `classify`, `instruct "..."`.
- Output: `text` | `markdown` | `json` (with an optional typed schema).
- Field types: `string`, `int`, `bool`, `enum(...)`, `list<T>`; suffix `?` marks a field optional.

## OpenAI output notes

- The JSON backend targets the Chat Completions API and defaults to `model:
  "gpt-4o-mini"`; the user message is a `{{input}}` placeholder you fill in.
- A typed `output json { ... }` becomes a `response_format` of type
  `json_schema`; a bare `output json` uses `json_object`; `text`/`markdown`
  emit no `response_format`. (The schema is non-strict, so optional `?` fields
  are allowed — OpenAI's *strict* structured outputs would require every field.)

## Tests

    dune test
