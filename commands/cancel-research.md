---
description: "Cancel an active deep research session"
allowed-tools:
  - Bash(test -f .claude/deep-research.local.md *)
  - Bash(rm -f .claude/deep-research.local.md .claude/deep-research.lock)
  - Bash(kill *)
  - Bash(pkill *)
  - Bash(cat research/*/agent-pids.txt *)
  - Read
---

Check if a research session is active:

```bash
test -f .claude/deep-research.local.md && echo "ACTIVE" || echo "NONE"
```

If active, read `.claude/deep-research.local.md` to get the current phase and research ID.

Then kill any running agent processes and remove the state file:

```bash
# Read the research_id from state file
RESEARCH_ID=$(sed -n 's/^research_id: *//p' .claude/deep-research.local.md | head -1)

# Kill running agent processes and their children if PID file exists
PID_FILE="research/${RESEARCH_ID}/agent-pids.txt"
if [ -f "$PID_FILE" ]; then
  for pid in $(cat "$PID_FILE"); do
    pkill -TERM -P "$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
  done
  sleep 1
  for pid in $(cat "$PID_FILE"); do
    pkill -KILL -P "$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  done
  rm -f "$PID_FILE"
fi

# Remove state file and lock file
rm -f .claude/deep-research.local.md .claude/deep-research.lock
```

Report: "Research council cancelled (was at phase: X, research ID: Y). Running agent processes have been terminated."

If no research session was active, report: "No active research session found."
