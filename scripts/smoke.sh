#!/bin/sh
# make smoke — three real one-shots against a model, numbers only.
#
# The check that counts after a SwiftAgentKit change: does the engine still
# answer, read a repo, and edit a file through sak's public-API use of it?
# Prints turns, tool calls, input tokens and seconds for each, so a before/
# after comparison is two runs of this script.
#
#   make smoke                       # the saved/default model (Ollama)
#   SAK_MODEL=glm-5.2:cloud make smoke
#   SAK=.build/release/sak make smoke   # a specific binary
set -eu

SAK="${SAK:-$(dirname "$0")/../.build/release/sak}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
[ -x "$SAK" ] || { echo "smoke: no binary at $SAK — run make build first" >&2; exit 2; }

summarize() {   # name, json
    printf '%s' "$2" | python3 -c '
import json, sys
name = sys.argv[1]
try:
    r = json.load(sys.stdin)
except Exception:
    print(name.ljust(10), "no JSON - failed"); sys.exit(1)
u = r.get("usage", {})
ok = "ok=" + str(r.get("ok")).lower()
print(name.ljust(10), ok.ljust(9), "exit=%s" % r.get("exit_code"), "turns=%-3s" % r.get("turns", "?"),
      "tools=%-3s" % r.get("tool_calls", 0), "in=%-7s" % u.get("input_tokens", 0), "out=%-5s" % u.get("output_tokens", 0),
      "window=%-7s" % r.get("context_window", 0), "%ss" % r.get("elapsed_seconds", "?"), r.get("model", ""))
sys.exit(0 if r.get("ok") else 1)
' "$1"
}

status=0
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# 1. A question: no tools, one turn.
out="$(cd "$work" && "$SAK" --json -q "Reply with the single word ok." </dev/null 2>/dev/null || true)"
summarize question "$out" || status=1

# 2. Read-only review of this repo: list, search, read — no edits possible.
out="$(cd "$REPO" && "$SAK" -r --json -q "In two sentences, what does this repository do? Read the README first." </dev/null 2>/dev/null || true)"
summarize review "$out" || status=1

# 3. An edit, approved up front, in a throwaway folder.
out="$(cd "$work" && "$SAK" -y --json -q "Create a file named hello.txt containing exactly the word hello, then stop." </dev/null 2>/dev/null || true)"
summarize edit "$out" || status=1
if [ "$(cat "$work/hello.txt" 2>/dev/null | tr -d '[:space:]')" = "hello" ]; then
    echo "edit       wrote hello.txt ✓"
else
    echo "edit       hello.txt missing or wrong ✗"; status=1
fi

exit $status
