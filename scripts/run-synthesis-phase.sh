#!/usr/bin/env bash
# Phase 3: Synthesis — a single Claude agent reads all refined reports and
# produces the final synthesized report.
#
# Usage: run-synthesis-phase.sh <research_id> <topic> <claude_model> \
#          <report_list> <coverage_note>
#
# Uses a synthesis-specific iteration hook (synthesis-iteration-hook.sh) that
# gives the agent up to 2 review passes. Unlike the research iteration hook,
# the synthesis hook prompts for report review/improvement — not new research.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"
PROJECT_DIR="$(pwd)"

RESEARCH_ID="$1"
TOPIC="$2"
CLAUDE_MODEL="$3"
REPORT_LIST="$4"
COVERAGE_NOTE="${5:-}"

WORKSPACE="${PROJECT_DIR}/research/${RESEARCH_ID}"

# Ensure WORKSPACE is absolute
if [ -d "$WORKSPACE" ]; then
  WORKSPACE="$(cd "$WORKSPACE" && pwd)"
fi
PROGRESS_LOG="${WORKSPACE}/progress.log"
PHASE_LABEL="Phase 3"

# shellcheck source=lib/phase-common.sh
source "${SCRIPT_DIR}/lib/phase-common.sh"

log "Phase 3: Starting synthesis"

FINAL_REPORT="${WORKSPACE}/final-report.md"
SYNTHESIS_STATE="${WORKSPACE}/synthesis-state.txt"
SYNTHESIS_SETTINGS="${WORKSPACE}/synthesis-settings.json"

# Initialize iteration state
echo "1" > "$SYNTHESIS_STATE"

# Write settings with synthesis-specific iteration hook
cat > "$SYNTHESIS_SETTINGS" << EOF
{
  "hooks": {
    "Stop": [{
      "hooks": [{
        "type": "command",
        "command": "${PLUGIN_ROOT}/scripts/synthesis-iteration-hook.sh",
        "timeout": 120
      }]
    }]
  }
}
EOF

SYNTHESIS_PROMPT="$(cat "${PLUGIN_ROOT}/prompts/synthesis-system.md")

## Research Topic

${TOPIC}
${COVERAGE_NOTE}

## Files to Read

Refined reports (primary inputs):${REPORT_LIST}

You may also find original (pre-refinement) reports in the same directory for additional context.

## Output

Write your final synthesis to: ${FINAL_REPORT}

Be thorough. This is the final deliverable.
When the synthesis is comprehensive and complete, add <!-- RESEARCH_COMPLETE --> as the very last line."

CLAUDE_EFFORT_FLAG=""
if [ "${RESEARCH_TEST_MODE:-false}" = "true" ]; then
  CLAUDE_EFFORT_FLAG="--effort low"
fi

log "Phase 3: Launching Claude synthesis agent (${CLAUDE_MODEL}${CLAUDE_EFFORT_FLAG:+ effort=low}, max 2 iterations)"

(
  RESEARCH_REPORT_PATH="$FINAL_REPORT" \
  RESEARCH_STATE_PATH="$SYNTHESIS_STATE" \
  RESEARCH_MAX_ITERS=2 \
  RESEARCH_PROGRESS_LOG="$PROGRESS_LOG" \
  env -u CLAUDECODE claude -p \
    --model "$CLAUDE_MODEL" \
    $CLAUDE_EFFORT_FLAG \
    --dangerously-skip-permissions \
    --settings "$SYNTHESIS_SETTINGS" \
    --max-turns 200 \
    "$SYNTHESIS_PROMPT" > "${WORKSPACE}/synthesis-stdout.log" 2>&1
  rc=$?
  log "Phase 3: Claude synthesis agent finished (exit $rc)"
  exit $rc
) &
register_agent claude $! "${WORKSPACE}/synthesis-stdout.log"

# ── Wait for agent ──────────────────────────────────────────────────────
record_pids

wait_for_agents || {
  exit 1
}

# ── Verify output ────────────────────────────────────────────────────────
if [ -f "$FINAL_REPORT" ] && [ -s "$FINAL_REPORT" ]; then
  log "Phase 3: Synthesis complete — $(basename "$FINAL_REPORT") ($(wc -l < "$FINAL_REPORT") lines)"
else
  log "Phase 3: WARNING — final-report.md not found or empty"
fi

rm -f "${WORKSPACE}/agent-pids.txt"
log "Phase 3: Complete"
