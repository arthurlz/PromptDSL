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

## Tests

    dune test
