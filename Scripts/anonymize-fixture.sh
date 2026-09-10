#!/usr/bin/env bash
# Strip identifying details from a captured fixture.
#
# Captures come off a real machine. `ps.txt` is every command line running at that moment,
# which means internal hostnames, git remotes, account names and repository names that
# describe unshipped work. This repository is public and git history is forever, so a
# capture is anonymized before its first commit, never after.
#
# Two passes:
#
#   1. A name mapping, read from Scripts/anonymize-map.json, which is NOT tracked in git.
#      The mapping is the reverse lookup for the whole exercise: publishing it would undo
#      the anonymization. Copy anonymize-map.example.json and fill it in locally.
#   2. Generic scrubbers for URLs, hostnames, email addresses, IPs and git forge paths.
#      These need no configuration and catch what a hand-written mapping will miss.
#
# Both passes preserve structure: path shapes, worktree hash suffixes, container naming
# patterns and every count stay exactly as captured, so the fixture keeps its test value.
#
# Usage: Scripts/anonymize-fixture.sh <fixture-dir> [map-file]
set -euo pipefail

DIR="${1:?usage: anonymize-fixture.sh <fixture-dir> [map-file]}"
MAP="${2:-$(dirname "$0")/anonymize-map.json}"
[ -d "$DIR" ] || { echo "no such directory: $DIR" >&2; exit 1; }

python3 - "$DIR" "$MAP" <<'PY'
import json, pathlib, re, sys

d = pathlib.Path(sys.argv[1])
map_path = pathlib.Path(sys.argv[2])

if map_path.exists():
    cfg = json.loads(map_path.read_text())
else:
    print(f"note: no mapping at {map_path}, running generic scrubbers only")
    cfg = {}

names = cfg.get("names", {})
# Case-insensitive substring replacements applied as a final pass. Structural renames in
# "names" are exact-match, but captures hold transformed variants of the same words:
# dash-encoded scratchpad paths, underscore-separated database names, and strings docker
# truncated with an ellipsis. Token-level redaction catches all of them.
redact = cfg.get("redact", {})

# Longest keys first, so a name that is a prefix of another is never partly rewritten.
def apply_names(text: str) -> str:
    for old, new in sorted(names.items(), key=lambda kv: -len(kv[0])):
        text = re.sub(re.escape(old), new, text)
    return text

SCRUBBERS = [
    # Any URL keeps its shape but loses its host and path.
    (re.compile(r'https?://[^\s"\'<>|,)]+'), 'https://example.invalid/redacted'),
    # Git forge owner/repo paths, including inside API calls.
    (re.compile(r'/repos/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+'), '/repos/OWNER/REPO'),
    (re.compile(r'(git@|github\.com[:/])[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+'), r'\1OWNER/REPO'),
    # Email addresses.
    (re.compile(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'), 'user@example.invalid'),
    # Non-loopback IPv4.
    (re.compile(r'\b(?!127\.0\.0\.1|0\.0\.0\.0)(?:\d{1,3}\.){3}\d{1,3}\b'), '10.0.0.1'),
    # Anything that looks like a credential flag, value dropped.
    (re.compile(r'(--(?:token|password|secret|api[-_]?key|domain)[= ])\S+'), r'\1REDACTED'),
    # Home directory, in case a capture ran without the capture-time rewrite.
    (re.compile(r'/Users/[A-Za-z0-9_.-]+'), '/Users/USER'),
    # Dash-encoded home paths, as used in scratchpad directory names:
    # /private/tmp/claude-501/-Users-someone-git-repositories-foo-...
    (re.compile(r'-Users-[A-Za-z0-9_.]+-'), '-Users-USER-'),
]

def apply_redactions(text: str) -> str:
    for term, replacement in sorted(redact.items(), key=lambda kv: -len(kv[0])):
        text = re.sub(re.escape(term), replacement, text, flags=re.IGNORECASE)
    return text

def scrub(text: str) -> str:
    for pattern, replacement in SCRUBBERS:
        text = pattern.sub(replacement, text)
    return text

changed = []
for f in sorted(d.iterdir()):
    if not f.is_file():
        continue
    before = f.read_text()
    after = apply_redactions(scrub(apply_names(before)))
    if after != before:
        f.write_text(after)
        changed.append(f.name)

print("rewrote:", ", ".join(changed) if changed else "(nothing)")

# Refuse to finish if anything the mapping was meant to remove survived.
leftovers = sorted({
    term for f in d.iterdir() if f.is_file()
    for term in list(names) + list(redact)
    if term and term.lower() in f.read_text().lower()
})
if leftovers:
    print("REFUSING: identifying terms still present: " + ", ".join(leftovers), file=sys.stderr)
    sys.exit(1)
print("anonymization check: clean")
PY
