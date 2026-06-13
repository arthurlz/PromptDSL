Compile to prose:

  $ promptc compile researcher.prompt --emit prose
  You are "researcher".
  Goal: analyze TSLA earnings
  
  Steps:
  1. Search for: TSLA earnings
  2. Summarize the findings
  
  Return ONLY JSON matching this schema:
    ticker: string
    rating: enum(buy, hold, sell)
    summary: string

Compile to OpenAI JSON:

  $ promptc compile researcher.prompt --emit json
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
