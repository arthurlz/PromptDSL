An agent inherits steps + output from a template and overrides the goal:

  $ printf 'template Rater {\n  step { summarize }\n  output json { rating: enum("buy","sell") why: string }\n}\n' > s.prompt
  $ printf 'import "s.prompt" as s\nagent "a" extends s.Rater {\n  input { topic: string }\n  goal "Rate {{topic}}."\n}\n' > a.prompt
  $ promptc compile a.prompt --set topic=TSLA --emit prose
  You are "a".
  Goal: Rate TSLA.
  
  Steps:
  1. Summarize the findings
  
  Return ONLY JSON matching this schema:
    rating: enum(buy, sell)
    why: string

An unknown template is reported and exits 1:

  $ printf 'import "s.prompt" as s\nagent "a" extends s.Nope { goal "g" }\n' > nope.prompt
  $ promptc compile nope.prompt
  nope.prompt:2:11: error: unknown template 's.Nope'
  [1]
