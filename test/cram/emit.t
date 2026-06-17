Compile to both prose and JSON:

  $ promptc compile researcher.prompt --emit both
  === PROSE ===
  You are "researcher".
  Goal: analyze TSLA earnings
  
  Steps:
  1. Search for: TSLA earnings
  2. Summarize the findings
  
  Return ONLY JSON matching this schema:
    ticker: string
    rating: enum(buy, hold, sell)
    summary: string
  === JSON ===
  {
    "model": "gpt-4o-mini",
    "messages": [
      {
        "role": "system",
        "content": "You are \"researcher\".\nGoal: analyze TSLA earnings\n\nSteps:\n1. Search for: TSLA earnings\n2. Summarize the findings\n\nReturn ONLY JSON matching this schema:\n  ticker: string\n  rating: enum(buy, hold, sell)\n  summary: string\n"
      },
      { "role": "user", "content": "{{input}}" }
    ],
    "response_format": {
      "type": "json_schema",
      "json_schema": {
        "name": "output",
        "schema": {
          "type": "object",
          "properties": {
            "ticker": { "type": "string" },
            "rating": { "type": "string", "enum": [ "buy", "hold", "sell" ] },
            "summary": { "type": "string" }
          },
          "required": [ "ticker", "rating", "summary" ],
          "additionalProperties": false
        }
      }
    }
  }

A missing file is reported on stderr and exits 2:

  $ promptc compile no-such-file.prompt
  no-such-file.prompt: No such file or directory
  [2]

The --model flag overrides the default model in the request:

  $ promptc compile researcher.prompt --model gpt-4o --emit json | head -2
  {
    "model": "gpt-4o",
