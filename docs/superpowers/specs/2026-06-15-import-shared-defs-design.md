# import + Shared Text Fragments (Design)

**Date:** 2026-06-15
**Status:** Design — awaiting review

## Context

Phase 1 dogfooding (`FINDINGS.md`) found cross-file repetition: 13/25 agents
duplicated structure or content. The `repeated:import` slice (6/25) was *content*
— the same disclaimer ("Informational, not financial advice.") and output rubric
copied verbatim across every agent in a domain cluster. Because the DSL is
one-agent-per-file, that repetition lives across separate files, so de-duplicating
it fundamentally requires a cross-file mechanism — a small module system.

This is the first cut of the "reuse" theme. It is scoped to **`import` + shared
text fragments**. Structural reuse (`template`/`extends`, the 9/25 `repeated:template`
slice) is a deliberate follow-up that will build on the import machinery created
here.

## Decisions (locked)

| Decision | Choice |
| --- | --- |
| Importable unit | **Named text fragments only** — `def name = "..."`. No shared inputs/schema/steps this cut. |
| Reference syntax | **Namespaced**: `import "path" as alias` → reference `{{alias.name}}`. No collision with input `{{name}}`. |
| File kinds | Two grammars (shared lexer): **agent file** = `import* agent`; **lib file** = `def*` only. |
| Imported files | Must be **def-only** — no `agent`, no nested `import`. **Single level** (no transitive imports, no cycles). |
| Local defs | **Not allowed** in agent files this cut (defs live only in imported libs; always referenced as `{{alias.name}}`). |
| Path resolution | Relative to the **main agent file's directory**. |
| Fragments | **Plain text** — no nested `{{}}` interpolation inside a fragment this cut. |
| Substitution | Compile-time, alongside inputs (fragments are constants; no `--set` needed). |
| Backward compatibility | Agents with no `import` compile exactly as today. |

## Language surface

```
# finance.prompt   (lib file: def-only)
def disclaimer = "Informational, not financial advice."
def rubric     = "Rate buy/hold/sell with a one-line rationale."
```
```
# earnings-analyst.prompt   (agent file)
import "finance.prompt" as fin

agent "earnings-analyst" {
  input { ticker: string }
  goal "Analyze {{ticker}}'s earnings. {{fin.disclaimer}}"
  step { instruct "{{fin.rubric}}" }
  output json { rating: enum("buy","hold","sell"); rationale: string }
}
```
```
promptc compile earnings-analyst.prompt --set ticker=TSLA
# {{ticker}} -> TSLA (input), {{fin.disclaimer}}/{{fin.rubric}} -> fragment text
```

- `def <name> = "<text>"` — a top-level named text fragment. Lib files contain only defs.
- `import "<path>" as <alias>` — agent-file top-level; loads the file, exposes its
  defs under `alias`. Path is relative to the main agent file's directory.
- Reference `{{alias.name}}` in `goal` / `step` arg / `instruct` text.
- **Reference rule:** a `{{x}}` whose name contains a `.` is a fragment reference
  (split into `alias`/`name`); otherwise it is an input. `Interp` is unchanged —
  it still extracts the raw `{{...}}` string; sema/bind interpret the dot.

## Pipeline

```
parse (agent file -> {af_imports; af_agent})
  -> resolve_imports (loader reads each lib, parses def-only, collects alias.name -> text)
  -> sema (validate the agent + that every {{alias.name}} ref resolves)
  -> bind (substitute inputs AND fragments)
  -> lower -> {prose, openai} backends
```

- **`resolve_imports`** (new `lib/resolve.ml`): for each `import "p" as a`, call the
  loader to get `p`'s contents, parse it with the **lib grammar**, and collect its
  defs as `a.name -> text`. Errors: file not found, target is not def-only, duplicate
  alias, duplicate def name within a lib.
- **loader/resolver:** `string (path) -> (string, string) result` (contents or error
  message). Threaded into `compile_string` and `check` as `?(resolver = …)`. The
  default resolver errors on any import (so a no-import agent compiled from a bare
  string still works). The driver supplies a filesystem resolver rooted at the main
  file's directory; tests supply an in-memory map.
- **sema:** the existing `{{ref}}`-declared check is extended — a bare name must be a
  declared input; a dotted `alias.name` must be a resolved fragment. `check` runs
  parse → resolve → sema (no bind), so undeclared/unknown refs are caught without
  values.
- **bind:** the `{{x}}` lookup tries inputs (bare name), then fragments
  (`alias.name`). Fragments are constants, so they need no `--set`.

## Module impact

```
lib/ast.ml        + def_decl, import_decl; program for an agent file becomes
                    { af_imports : import_decl list; af_agent : agent_block };
                    a lib file parses to def_decl list
lib/lexer.mll     + `def`, `import`, `as` keywords
lib/parser.mly    + two %start symbols (agent-file program, lib-file library);
                    import rule, def rule
lib/resolve.ml    NEW: load + parse libs, collect fragments, validate import errors
lib/sema.ml       extend the {{ref}} check to accept resolved alias.name fragments
lib/bind.ml       fragment substitution in the {{x}} lookup
lib/compile.ml    parse -> resolve -> sema -> bind; compile_string/check gain ?resolver
lib/driver.ml     filesystem resolver rooted at the main file's directory
test/*            new alcotest + cram coverage
```

This changes `Compile.parse`'s return type (`agent_block` -> agent-file record). The
implementation plan updates the existing parser/sema test call sites accordingly.

## Error handling

All diagnostics carry spans where a source location exists:
- import file not found (loader error) / target is not def-only / duplicate import
  alias / duplicate def name in a lib;
- reference to an unknown alias, or an unknown def within a known alias;
- (existing) unknown bare input reference.

## Testing

- **parser:** an agent file with `import` + agent; a lib file (def-only) via the lib grammar.
- **resolve:** in-memory loader — found, not-found, target-not-def-only, duplicate alias/def.
- **sema:** `{{fin.disclaimer}}` with `fin` imported and `disclaimer` defined → ok;
  unknown alias and unknown def → errors.
- **bind:** fragment substitution into goal/step text (alongside an input).
- **cram:** a real lib file + an agent that imports it, `compile` golden; plus a
  **backward-compat** case proving a no-import agent is byte-identical to today.

## Out of scope (later cuts)

`template`/`extends` (structural reuse); transitive/nested imports and cycle
handling; local defs in agent files; nested `{{}}` interpolation inside fragments;
importing shared `input` declarations, output schemas, or steps.
