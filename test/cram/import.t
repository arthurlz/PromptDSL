A def from an imported lib is substituted at compile time:

  $ printf 'def disclaimer = "Informational, not advice."\n' > fin.prompt
  $ printf 'import "fin.prompt" as fin\nagent "r" {\n  input { ticker: string }\n  goal "Analyze {{ticker}}. {{fin.disclaimer}}"\n}\n' > r.prompt
  $ promptc compile r.prompt --set ticker=TSLA --emit prose
  You are "r".
  Goal: Analyze TSLA. Informational, not advice.

A missing import is reported and exits 1:

  $ printf 'import "nope.prompt" as x\nagent "r" { goal "g {{x.y}}" }\n' > missing_import.prompt
  $ promptc compile missing_import.prompt
  missing_import.prompt:1:1: error: cannot import "nope.prompt": ./nope.prompt: No such file or directory
  [1]
