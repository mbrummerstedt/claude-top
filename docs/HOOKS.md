# Hooks

Two guardrails, both driven by the same engine the CLI uses. Neither is installed for you.

## What they do

**`session-start`** prints a warning when a session opens on a machine that is already
oversubscribed, so a fifteenth session is a decision rather than an accident. It says
nothing on a machine that is coping, which is most of the time and is the point: a hook
that speaks every session is a hook you turn off, and then it is not there on the day it
matters.

**`pre-tool-use`** caps test-runner workers while load is above twice the core count. A
single `vitest` run defaults to one worker per core and can saturate a machine on its own.
The reference capture caught nine of them at roughly 29% each, which is most of a ten-core
laptop spent by one command nobody thought was expensive.

## Installing them

Add to `~/.claude/settings.json`, with the binary path spelled out in full:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          { "type": "command", "command": "/usr/local/bin/claude-top --hook session-start" }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "/usr/local/bin/claude-top --hook pre-tool-use",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

Check them before you trust them. They read a hook payload on stdin and answer on stdout:

```bash
echo '{"tool_name":"Bash","tool_input":{"command":"npx vitest run"}}' \
  | claude-top --hook pre-tool-use
```

On a busy machine that prints an `updatedInput` carrying the rewritten command. On a calm
one it prints nothing, which is the answer meaning "change nothing".

## What the cap does and does not touch

The rewrite is deliberately too narrow rather than nearly right, because the cost of a
wrong rewrite is a command that does not run.

| Command | Result |
|---|---|
| `npx vitest run` | `npx vitest run --maxWorkers=2` |
| `pnpm exec jest` | `pnpm exec jest --maxWorkers=2` |
| `pytest -n auto` | `pytest -n 2` |
| `pytest -n 1` | untouched, someone already chose less |
| `npx vitest run --maxWorkers=4` | untouched, the author chose a cap |
| `pytest tests/` | untouched, `-n` needs xdist and may not be installed |
| `npm test` | untouched, the underlying runner is unknown |
| `grep -r vitest .` | untouched, mentioning a runner is not running one |

The runner is identified from the executable position, never from the command text, which
is the same rule that keeps a shell script mentioning `docker` out of the Docker bucket.
Only the segment holding the runner is rewritten, so a build step either side of a `&&`
survives untouched.

The cap is a quarter of the cores, at least one, and it applies only while load is above
twice the core count.

Every rewrite announces itself through `systemMessage`. A hook that silently changes what
you asked for is a hook you stop trusting the first time you notice.

## Cost

`pre-tool-use` runs before every Bash call, so it reads load through `sysctl` and never
samples. It takes about 70ms, nearly all of which is process launch.

`session-start` reads the newest row from the sampler's database when there is one less
than five minutes old, and otherwise reports load alone. It never samples: a four second
pause at session start would land on the machine least able to afford it.

Without the sampler installed the warning still fires, but it can only report load, not
which sessions are responsible. `Scripts/install-agent.sh` is what gives it the detail.

## Not here yet

A reap on `SessionEnd`, stopping the processes and Compose project of the session that is
exiting. The mechanism exists and the safety rules are settled and tested, but whether it
should happen automatically at all is still an open question in the design notes. Until
that is answered, reaping stays manual through `claude-top --reap`.
