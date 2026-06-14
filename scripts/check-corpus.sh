#!/usr/bin/env bash
# Validate that every corpus/**/*.prompt is legal DSL (promptc check passes).
set -uo pipefail
cd "$(dirname "$0")/.."   # repo root

dune build bin/main.exe 2>/dev/null || { echo "build failed"; exit 1; }
BIN=_build/default/bin/main.exe

pass=0; fail=0; failed=()
while IFS= read -r f; do
  [ -z "$f" ] && continue
  if "$BIN" check "$f" >/dev/null 2>&1; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); failed+=("$f")
  fi
done < <(find corpus -name '*.prompt' 2>/dev/null)

echo "corpus check: $pass passed, $fail failed"
if (( fail > 0 )); then
  printf '  FAIL: %s\n' "${failed[@]}"
  exit 1
fi
