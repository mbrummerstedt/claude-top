#!/usr/bin/env bash
# Capture a sanitized snapshot of the machine for use as a test fixture.
#
# Sanitizing is not optional. Process environments routinely contain API keys,
# OAuth tokens and database passwords. This script keeps an explicit allowlist of
# environment variables and discards everything else before anything touches disk.
#
# Usage: Scripts/capture-fixture.sh <output-dir>
set -euo pipefail

OUT="${1:?usage: capture-fixture.sh <output-dir>}"
mkdir -p "$OUT"

# Environment variables the attribution engine actually reads. Nothing else is kept.
ENV_ALLOWLIST='^(CLAUDE_CODE_MESSAGING_SOCKET|CLAUDE_CODE_HOST_SESSION_ID|CLAUDE_CODE_ENTRYPOINT|CLAUDE_CODE_SESSION_ID|PWD)='

scrub() { sed -e "s#/Users/$(whoami)#/Users/USER#g"; }

# 1. Process table. TIME is cumulative CPU time, which is what the CPU% diff needs.
ps -Ao pid=,ppid=,uid=,pcpu=,rss=,time=,etime=,command= | scrub > "$OUT/ps.txt"

# 2. Per-process environment, allowlisted down to the vars we read.
: > "$OUT/procenv.txt"
for pid in $(ps -Ao pid= | tr -d ' '); do
  line=$(ps eww -p "$pid" -o command= 2>/dev/null | tail -1) || continue
  [ -z "$line" ] && continue
  kept=$(printf '%s' "$line" | tr ' ' '\n' | grep -E "$ENV_ALLOWLIST" | tr '\n' ' ') || true
  [ -z "$kept" ] && continue
  printf '%s %s\n' "$pid" "$kept" | scrub >> "$OUT/procenv.txt"
done

# 3. Live session roster. The `name` field is the opening user prompt: always dropped.
if command -v claude >/dev/null 2>&1; then
  claude agents --json 2>/dev/null \
    | python3 -c 'import json,sys
try: rows=json.load(sys.stdin)
except Exception: rows=[]
for r in rows: r.pop("name",None)
print(json.dumps(rows,indent=2))' | scrub > "$OUT/agents.json" || echo '[]' > "$OUT/agents.json"
fi

# 4. Containers plus the compose labels that map them back to a worktree.
if command -v docker >/dev/null 2>&1; then
  docker ps --format '{{json .}}' 2>/dev/null | scrub > "$OUT/docker-ps.jsonl" || : > "$OUT/docker-ps.jsonl"
  : > "$OUT/docker-labels.jsonl"
  ids=$(docker ps -q 2>/dev/null | tr '\n' ' ')
  if [ -n "$ids" ]; then
    # shellcheck disable=SC2086
    docker inspect $ids 2>/dev/null | python3 -c 'import json,sys
try: rows=json.load(sys.stdin)
except Exception: rows=[]
for r in rows:
    print(json.dumps({"id": r.get("Id","")[:12],
                      "name": (r.get("Name") or "").lstrip("/"),
                      "image": (r.get("Config") or {}).get("Image",""),
                      "labels": (r.get("Config") or {}).get("Labels") or {}}))' | scrub >> "$OUT/docker-labels.jsonl" || true
  fi
fi

# 5. Machine totals.
{
  echo "ncpu=$(sysctl -n hw.ncpu)"
  echo "memtotal_bytes=$(sysctl -n hw.memsize)"
  echo "loadavg=$(sysctl -n vm.loadavg | tr -d '{}')"
  echo "captured_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$OUT/machine.txt"

echo "captured to $OUT"
grep -c . "$OUT"/ps.txt "$OUT"/procenv.txt 2>/dev/null || true

# Guard: fail loudly if anything token-shaped survived.
if grep -rqiE '(^|[^A-Za-z0-9-])(sk-[A-Za-z0-9]{16}|ghp_[A-Za-z0-9]{20}|xox[baprs]-[A-Za-z0-9-]{10}|AKIA[0-9A-Z]{16})|BEGIN [A-Z ]*PRIVATE KEY' "$OUT"; then
  echo "REFUSING: secret-shaped content found in fixture. Not safe to commit." >&2
  exit 1
fi
echo "secret scan: clean"
