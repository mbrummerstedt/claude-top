# Security

## Reporting a vulnerability

Open a [private security advisory](https://github.com/mbrummerstedt/claude-top/security/advisories/new)
rather than a public issue. You will get a response within a week.

## What this tool can do

`claude-top` reads other processes' arguments and environments through
`sysctl(KERN_PROCARGS2)`. macOS permits this for processes owned by the same user, which
is the mechanism the whole tool rests on: it is how a session's children can be identified
without wrapping or instrumenting anything.

Process environments routinely hold API keys, database passwords and session tokens. Four
variables are extracted and nothing else is copied out of the read buffer:

- `CLAUDE_CODE_MESSAGING_SOCKET`
- `CLAUDE_CODE_HOST_SESSION_ID`
- `CLAUDE_CODE_ENTRYPOINT`
- `PWD`

A change that widens that set, or that retains a whole environment, is a security change
and will be reviewed as one.

## What it writes

| Path | Contents |
|---|---|
| `~/.claude/state/resources.db` | Rolling 24h of group labels, CPU, memory and counts |
| `~/.claude/state/reap.log` | Every signal sent, with the reason it was selected |
| `~/Library/LaunchAgents/com.claudetop.sampler.plist` | Only if you install the sampler |

Command lines are stored in `proc_detail` for groups above the detail threshold, truncated
to 300 characters. A command line can contain a secret passed as an argument. If that
matters in your environment, do not install the sampler; the one-shot CLI stores nothing.

Your opening prompt is shown in the terminal for sessions with no worktree name, and is
never written to any of the above.

## What it does not do

There is no network code in this project. Nothing is uploaded, and there is no telemetry.

It runs entirely as your own user and needs no elevated privileges. It cannot read
processes belonging to other users, and it does not try.

## Reaping

`--reap` sends signals to processes and stops containers. Selection is by env stamp for
processes and by a Compose `working_dir` label for containers, and by nothing else. It
never selects by path, by parent, by container name, or across sessions. It confirms
interactively and defaults to no.

If you find an input that makes a reap select something outside its own session, that is a
security report, not a bug report. Please use the advisory link above.
