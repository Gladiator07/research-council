#!/usr/bin/env bash
# Iteration hook — keeps a Claude agent researching until complete.
# Used as a Claude Stop hook.
#
# Environment variables (set by the caller):
#   RESEARCH_REPORT_PATH  — path to the report file
#   RESEARCH_STATE_PATH   — path to iteration state file
#   RESEARCH_MAX_ITERS    — maximum iterations (default: 10)
#   RESEARCH_PROGRESS_LOG — path to progress log (optional)

set -uo pipefail

# Consume stdin (hook input JSON)
HOOK_INPUT=$(cat)

REPORT="${RESEARCH_REPORT_PATH:-}"
STATE="${RESEARCH_STATE_PATH:-}"
MAX_ITERS="${RESEARCH_MAX_ITERS:-10}"
PROGRESS_LOG="${RESEARCH_PROGRESS_LOG:-/dev/null}"

log() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] claude hook: $*" >> "$PROGRESS_LOG"
}

# Safety: if no report path configured, allow exit
if [ -z "$REPORT" ] || [ -z "$STATE" ]; then
  exit 0
fi

# Read current iteration
ITERATION=1
if [ -f "$STATE" ]; then
  ITERATION=$(cat "$STATE" 2>/dev/null || echo "1")
fi

# Validate iteration is numeric
if ! [[ "$ITERATION" =~ ^[0-9]+$ ]]; then
  ITERATION=1
fi

# Check completion marker in report
if [ -f "$REPORT" ] && grep -q "RESEARCH_COMPLETE" "$REPORT" 2>/dev/null; then
  log "Research complete (marker found) at iteration ${ITERATION}"
  exit 0
fi

# Check max iterations
if [ "$ITERATION" -ge "$MAX_ITERS" ]; then
  log "Max iterations (${MAX_ITERS}) reached"
  exit 0
fi

# Increment and save
NEXT=$((ITERATION + 1))
echo "$NEXT" > "$STATE"

log "Requesting iteration ${NEXT}/${MAX_ITERS}"

jq -n --arg reason "Continue your research. Read your current report at ${REPORT}. Identify gaps, unexplored angles, and areas that need more depth. Conduct additional web searches to fill those gaps. Update the report with substantial new findings. When you have exhausted all productive research avenues, add <!-- RESEARCH_COMPLETE --> as the very last line." \
  --arg msg "Research iteration ${NEXT}/${MAX_ITERS}" \
  '{decision: "block", reason: $reason, systemMessage: $msg}'
