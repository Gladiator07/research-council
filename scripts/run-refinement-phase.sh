#!/usr/bin/env bash
# Phase 2: Cross-pollination refinement — each agent reads both reports and refines
#
# Usage: run-refinement-phase.sh <research_id> <topic> <max_iters> \
#          <claude_model> <codex_model> <codex_reasoning>

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"
PROJECT_DIR="$(pwd)"

RESEARCH_ID="$1"
TOPIC="$2"
MAX_ITERS="$3"
CLAUDE_MODEL="$4"
CODEX_MODEL="$5"
CODEX_REASONING="$6"

WORKSPACE="${PROJECT_DIR}/research/${RESEARCH_ID}"

# Ensure WORKSPACE is absolute (needed for agents that cd elsewhere)
if [ -d "$WORKSPACE" ]; then
  WORKSPACE="$(cd "$WORKSPACE" && pwd)"
fi
PROGRESS_LOG="${WORKSPACE}/progress.log"
PHASE_LABEL="Phase 2"

# shellcheck source=lib/phase-common.sh
source "${SCRIPT_DIR}/lib/phase-common.sh"

log "Phase 2: Starting cross-pollination refinement"

CLAUDE_REPORT="${WORKSPACE}/claude-report.md"
CODEX_REPORT="${WORKSPACE}/codex-report.md"

CLAUDE_REFINED="${WORKSPACE}/claude-refined.md"
CODEX_REFINED="${WORKSPACE}/codex-refined.md"

REFINEMENT_PROMPT="$(cat "${PLUGIN_ROOT}/prompts/refinement-system.md")"

# Helper: build refinement prompt for a specific agent
build_refinement_prompt() {
  local OWN_REPORT="$1"
  local OWN_LABEL="$2"
  local OTHER1="$3"
  local OTHER1_LABEL="$4"
  local OUTPUT="$5"

  echo "${REFINEMENT_PROMPT}

## Research Topic
${TOPIC}

## Files
- Your original report (${OWN_LABEL}): ${OWN_REPORT}
- Other report (${OTHER1_LABEL}): ${OTHER1}
- Write your REFINED report to: ${OUTPUT}

Read both reports, then write your refined report to ${OUTPUT}."
}

# ── Launch Claude refinement ──────────────────────────────────────────────
if [ -f "$CLAUDE_REPORT" ] && [ -s "$CLAUDE_REPORT" ]; then
  CLAUDE_STATE="${WORKSPACE}/claude-refine-state.txt"
  CLAUDE_SETTINGS="${WORKSPACE}/claude-refine-settings.json"

  echo "1" > "$CLAUDE_STATE"

  write_claude_settings "$CLAUDE_SETTINGS" "$PLUGIN_ROOT"

  CLAUDE_REFINE_PROMPT="$(build_refinement_prompt "$CLAUDE_REPORT" "Claude" "$CODEX_REPORT" "Codex" "$CLAUDE_REFINED")

When spawning sub-agents, use the opus model for maximum reasoning quality — cost is not a concern."

  CLAUDE_EFFORT_FLAG=""
  if [ "${RESEARCH_TEST_MODE:-false}" = "true" ]; then
    CLAUDE_EFFORT_FLAG="--effort low"
  fi

  log "Phase 2: Launching Claude refinement agent${CLAUDE_EFFORT_FLAG:+ (effort=low)}"

  (
    RESEARCH_REPORT_PATH="$CLAUDE_REFINED" \
    RESEARCH_STATE_PATH="$CLAUDE_STATE" \
    RESEARCH_MAX_ITERS="$MAX_ITERS" \
    RESEARCH_PROGRESS_LOG="$PROGRESS_LOG" \
    env -u CLAUDECODE claude -p \
      --model "$CLAUDE_MODEL" \
      $CLAUDE_EFFORT_FLAG \
      --dangerously-skip-permissions \
      --settings "$CLAUDE_SETTINGS" \
      --max-turns 200 \
      "$CLAUDE_REFINE_PROMPT" > "${WORKSPACE}/claude-refine-stdout.log" 2>&1
    rc=$?
    log "Phase 2: Claude refinement finished (exit $rc)"
    exit $rc
  ) &
  register_agent claude $! "${WORKSPACE}/claude-refine-stdout.log"
else
  log "Phase 2: Skipping Claude refinement (no Phase 1 report)"
fi

# ── Launch Codex refinement ───────────────────────────────────────────────
if [ -f "$CODEX_REPORT" ] && [ -s "$CODEX_REPORT" ]; then
  CODEX_REFINE_PROMPT="$(build_refinement_prompt "$CODEX_REPORT" "Codex" "$CLAUDE_REPORT" "Claude" "$CODEX_REFINED")"

  log "Phase 2: Launching Codex refinement agent"

  (
    cd "$PROJECT_DIR"
    bash "${PLUGIN_ROOT}/scripts/codex-wrapper.sh" \
      "$CODEX_REFINE_PROMPT" \
      "$CODEX_REFINED" \
      "$MAX_ITERS" \
      "$CODEX_MODEL" \
      "$CODEX_REASONING" \
      "$PROGRESS_LOG" \
      "$TOPIC" > "${WORKSPACE}/codex-refine-stdout.log" 2>&1
    rc=$?
    log "Phase 2: Codex refinement finished (exit $rc)"
    exit $rc
  ) &
  register_agent codex $! "${WORKSPACE}/codex-refine-stdout.log"
else
  log "Phase 2: Skipping Codex refinement (no Phase 1 report)"
fi

# ── Wait for agents ──────────────────────────────────────────────────────
record_pids

wait_for_agents || {
  # All agents crashed at startup
  exit 1
}

# ── Report results ────────────────────────────────────────────────────────
REFINED_FOUND=0
for f in "$CLAUDE_REFINED" "$CODEX_REFINED"; do
  if [ -f "$f" ] && [ -s "$f" ]; then
    REFINED_FOUND=$((REFINED_FOUND + 1))
    log "Phase 2: Refined report found: $(basename "$f") ($(wc -l < "$f") lines)"
  else
    # Fall back to original report if refinement failed
    ORIGINAL="${f//-refined/-report}"
    if [ -f "$ORIGINAL" ] && [ -s "$ORIGINAL" ]; then
      cp "$ORIGINAL" "$f"
      log "Phase 2: WARNING — refinement failed for $(basename "$f"), using original report as fallback"
      REFINED_FOUND=$((REFINED_FOUND + 1))
    else
      log "Phase 2: WARNING — no refined report: $(basename "$f")"
    fi
  fi
done

rm -f "${WORKSPACE}/agent-pids.txt"
log "Phase 2: Complete (${REFINED_FOUND}/2 refined reports, ${FAILURES} failures)"
