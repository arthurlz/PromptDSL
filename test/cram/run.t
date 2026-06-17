run without an API key errors and exits 2:

  $ printf 'agent "a" { goal "g" }\n' > a.prompt
  $ env -u OPENAI_API_KEY promptc run a.prompt
  OPENAI_API_KEY is not set
  [2]

run on a missing file exits 2 (key set; fails before any network):

  $ OPENAI_API_KEY=x promptc run no-such.prompt
  no-such.prompt: No such file or directory
  [2]

run --target anthropic without ANTHROPIC_API_KEY exits 2:

  $ env -u ANTHROPIC_API_KEY promptc run a.prompt --target anthropic
  ANTHROPIC_API_KEY is not set
  [2]

run --target gemini without GEMINI_API_KEY exits 2:

  $ env -u GEMINI_API_KEY promptc run a.prompt --target gemini
  GEMINI_API_KEY is not set
  [2]
