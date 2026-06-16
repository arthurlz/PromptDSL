A float input and a ranged int field compile through to JSON:

  $ printf 'agent "a" {\n  input { pe: float }\n  goal "Analyze (P/E {{pe}})."\n  output json { score: int(0..100)  margin: float }\n}\n' > a.prompt
  $ promptc compile a.prompt --set pe=12.5 --emit both
  === PROSE ===
  You are "a".
  Goal: Analyze (P/E 12.5).
  
  Return ONLY JSON matching this schema:
    score: int (0..100)
    margin: float
  === JSON ===
  {
    "model": "gpt-4o-mini",
    "messages": [
      {
        "role": "system",
        "content": "You are \"a\".\nGoal: Analyze (P/E 12.5).\n\nReturn ONLY JSON matching this schema:\n  score: int (0..100)\n  margin: float\n"
      },
      { "role": "user", "content": "" }
    ],
    "response_format": {
      "type": "json_schema",
      "json_schema": {
        "name": "output",
        "schema": {
          "type": "object",
          "properties": {
            "score": { "type": "integer", "minimum": 0, "maximum": 100 },
            "margin": { "type": "number" }
          },
          "required": [ "score", "margin" ],
          "additionalProperties": false
        }
      }
    }
  }

A non-numeric float input is an error:

  $ promptc compile a.prompt --set pe=abc
  a.prompt:2:11: error: input 'pe': expected a number, got "abc"
  [1]
