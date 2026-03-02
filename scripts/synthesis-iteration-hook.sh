#!/usr/bin/env bash
# Synthesis iteration hook — gives the synthesis agent one chance to review
# and improve its report. Unlike the research iteration hook, this does NOT
# instruct the agent to do new research or web searches.
#
# Environment variables (set by the caller):
#   RESEARCH_REPORT_PATH  — path to the final report file
#   RESEARCH_STATE_PATH   — path to iteration state file
#   RESEARCH_MAX_ITERS    — maximum iterations (default: 2)
#   RESEARCH_PROGRESS_LOG — path to progress log (optional)

set -uo pipefail

# Consume stdin (hook input JSON)
HOOK_INPUT=$(cat)

REPORT="${RESEARCH_REPORT_PATH:-}"
STATE="${RESEARCH_STATE_PATH:-}"
MAX_ITERS="${RESEARCH_MAX_ITERS:-2}"
PROGRESS_LOG="${RESEARCH_PROGRESS_LOG:-/dev/null}"

log() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] synthesis hook: $*" >> "$PROGRESS_LOG"
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

# Check if report exists and has completion marker
if [ -f "$REPORT" ] && grep -q "RESEARCH_COMPLETE" "$REPORT" 2>/dev/null; then
  log "Synthesis complete (marker found) at iteration ${ITERATION}"
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

log "Requesting synthesis review iteration ${NEXT}/${MAX_ITERS}"

jq -n --arg reason "Review your synthesis report at ${REPORT}. Check for: missing key findings from the source reports, weak areas that need more detail, places where agent disagreements weren't fully analyzed, and source deduplication issues. Improve the report where needed. When the synthesis is comprehensive and complete, add <!-- RESEARCH_COMPLETE --> as the very last line." \
  --arg msg "Synthesis review ${NEXT}/${MAX_ITERS}" \
  '{decision: "block", reason: $reason, systemMessage: $msg}'
