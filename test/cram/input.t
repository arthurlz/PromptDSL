Inputs are substituted at compile time:

  $ printf 'agent "x" {\n  input { ticker: string  note: string @content }\n  goal "Analyze {{ticker}}."\n}\n' > in.prompt
  $ promptc compile in.prompt --set ticker=TSLA --set note=hello --emit both
  === PROSE ===
  You are "x".
  Goal: Analyze TSLA.
  
  ## Input
  hello
  === JSON ===
  {
    "model": "gpt-4o-mini",
    "messages": [
      {
        "role": "system",
        "content": "You are \"x\".\nGoal: Analyze TSLA.\n\n## Input\nhello\n"
      },
      { "role": "user", "content": "hello" }
    ]
  }

Missing a required input is an error:

  $ promptc compile in.prompt --emit prose
  in.prompt:2:11: error: missing required input 'ticker' (use --set ticker=...)
  in.prompt:2:27: error: missing required input 'note' (use --set note=...)
  [1]
