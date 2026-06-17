The Anthropic Messages request for a typed-json agent:

  $ promptc compile researcher.prompt --target anthropic --emit json
  {
    "model": "claude-haiku-4-5-20251001",
    "max_tokens": 1024,
    "system": "You are \"researcher\".\nGoal: analyze TSLA earnings\n\nSteps:\n1. Search for: TSLA earnings\n2. Summarize the findings\n\nReturn ONLY JSON matching this schema:\n  ticker: string\n  rating: enum(buy, hold, sell)\n  summary: string\n",
    "messages": [ { "role": "user", "content": "{{input}}" } ],
    "output_config": {
      "format": {
        "type": "json_schema",
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

The Gemini generateContent request:

  $ promptc compile researcher.prompt --target gemini --emit json
  {
    "systemInstruction": {
      "parts": [
        {
          "text": "You are \"researcher\".\nGoal: analyze TSLA earnings\n\nSteps:\n1. Search for: TSLA earnings\n2. Summarize the findings\n\nReturn ONLY JSON matching this schema:\n  ticker: string\n  rating: enum(buy, hold, sell)\n  summary: string\n"
        }
      ]
    },
    "contents": [ { "role": "user", "parts": [ { "text": "{{input}}" } ] } ],
    "generationConfig": {
      "responseMimeType": "application/json",
      "responseSchema": {
        "type": "OBJECT",
        "properties": {
          "ticker": { "type": "STRING" },
          "rating": { "type": "STRING", "enum": [ "buy", "hold", "sell" ] },
          "summary": { "type": "STRING" }
        },
        "required": [ "ticker", "rating", "summary" ]
      }
    }
  }

The default target is still OpenAI:

  $ promptc compile researcher.prompt --emit json | head -2
  {
    "model": "gpt-4o-mini",
