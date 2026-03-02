#!/usr/bin/env bash
# Deep Research Council — Orchestrator Stop Hook
#
# Phase state machine:
#   research   → run 2 parallel research agents → refinement
#   refinement → run 2 parallel refinement agents → synthesis
#   synthesis  → run 1 Claude synthesis agent → complete
#   complete   → allow exit
#
# Fail-open: on any unexpected error, allow exit (never trap the user).

LOG_FILE=".claude/deep-research.log"

log() {
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] orchestrator: $*" >> "$LOG_FILE"
}

# Portable sed -i (macOS vs GNU)
sedi() { if [[ "$OSTYPE" == "darwin"* ]]; then sed -i '' "$@"; else sed -i "$@"; fi; }

# Escape a string for safe use in sed replacement patterns.
# Must escape \ first (to avoid double-escaping), then & and /.
sed_escape() { printf '%s\n' "$1" | sed -e 's/[\\]/\\&/g' -e 's/[&/]/\\&/g'; }

# Guard: jq is required by this hook
command -v jq &>/dev/null || { log "ERROR: jq not found in PATH"; exit 0; }

# On any error, allow exit
trap 'log "ERROR: hook exited via ERR trap (line $LINENO)"; rm -f ".claude/deep-research.lock"; printf "{\"decision\":\"approve\"}\n"; exit 0' ERR

# Consume stdin
HOOK_INPUT=$(cat)

STATE_FILE=".claude/deep-research.local.md"
LOCK_FILE=".claude/deep-research.lock"

# No active session → allow exit
if [ ! -f "$STATE_FILE" ]; then
  exit 0
fi

# ── Parse state file fields ──────────────────────────────────────────────
parse_field() {
  sed -n "s/^${1}: *//p" "$STATE_FILE" | head -1
}

ACTIVE=$(parse_field "active")
PHASE=$(parse_field "phase")
RESEARCH_ID=$(parse_field "research_id")
TEST_MODE=$(parse_field "test_mode")
MAX_ITERS=$(parse_field "max_iterations")
CLAUDE_MODEL=$(parse_field "claude_model")
CODEX_MODEL=$(parse_field "codex_model")
CODEX_REASONING=$(parse_field "codex_reasoning")

# Not active → clean up
if [ "$ACTIVE" != "true" ]; then
  rm -f "$STATE_FILE"
  exit 0
fi

# Validate research_id format
if ! echo "$RESEARCH_ID" | grep -qE '^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$'; then
  log "ERROR: invalid research_id format: $RESEARCH_ID"
  rm -f "$STATE_FILE"
  exit 0
fi

# ── Lock helpers (defined early — used by session-ID check and phase execution) ──
# Lock file stores "PID:EPOCH" to defend against PID-reuse false positives.
# A lock older than 2 hours is treated as stale regardless of PID liveness.
LOCK_MAX_AGE=7200  # 2 hours in seconds

is_lock_alive() {
  [ -f "$LOCK_FILE" ] || return 1
  local lock_content pid lock_epoch now age
  lock_content=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
  pid="${lock_content%%:*}"
  lock_epoch="${lock_content#*:}"
  [ -z "$pid" ] && return 1
  # If lock has no epoch (legacy format), treat as stale
  [ "$lock_epoch" = "$pid" ] && return 1
  # Validate numeric format to avoid arithmetic errors on malformed content
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  [[ "$lock_epoch" =~ ^[0-9]+$ ]] || return 1
  # Check age — stale locks are dead regardless of PID
  now=$(date +%s)
  age=$(( now - lock_epoch ))
  if [ "$age" -gt "$LOCK_MAX_AGE" ]; then
    log "WARN: lock is ${age}s old (max ${LOCK_MAX_AGE}s), treating as stale despite PID=$pid"
    return 1
  fi
  # PID must still be alive
  kill -0 "$pid" 2>/dev/null || return 1
  return 0
}

# ── Session ID check: skip if different session ──────────────────────────
CURRENT_SESSION=$(echo "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null || echo "")
RECORDED_SESSION=$(parse_field "session_id")

# First run: stamp the session ID into the state file
if [ -z "$RECORDED_SESSION" ] && [ -n "$CURRENT_SESSION" ]; then
  sedi "s/^session_id:$/session_id: $(sed_escape "$CURRENT_SESSION")/" "$STATE_FILE"
  RECORDED_SESSION="$CURRENT_SESSION"
  log "Stamped session_id: ${CURRENT_SESSION}"
fi

# Different session — check if we can adopt the orphaned research
if [ -n "$RECORDED_SESSION" ] && [ -n "$CURRENT_SESSION" ] && [ "$CURRENT_SESSION" != "$RECORDED_SESSION" ]; then
  # If a lock is held by a live, recent process, another session is actively running phases
  if is_lock_alive; then
    log "Skipping: different session and lock is active (current=$CURRENT_SESSION, recorded=$RECORDED_SESSION)"
    exit 0
  fi
  # No active lock — adopt the research into this session
  log "Adopting orphaned research into new session (old=$RECORDED_SESSION, new=$CURRENT_SESSION)"
  sedi "s/^session_id: .*$/session_id: $(sed_escape "$CURRENT_SESSION")/" "$STATE_FILE"
  RECORDED_SESSION="$CURRENT_SESSION"
fi

# ── Staleness check: auto-clean after 5 hours ────────────────────────────
STARTED_AT=$(parse_field "started_at")
if [ -n "$STARTED_AT" ]; then
  if [[ "$OSTYPE" == "darwin"* ]]; then
    STARTED_EPOCH=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$STARTED_AT" +%s 2>/dev/null || echo 0)
  else
    STARTED_EPOCH=$(date -d "$STARTED_AT" +%s 2>/dev/null || echo 0)
  fi
  NOW_EPOCH=$(date +%s)
  AGE=$(( NOW_EPOCH - STARTED_EPOCH ))
  if [ "$AGE" -gt 18000 ]; then  # 5 hours = 18000 seconds
    log "WARN: stale state file (${AGE}s old, started_at=$STARTED_AT), cleaning up"
    rm -f "$STATE_FILE"
    exit 0
  fi
fi

# Extract topic (everything after the second --- line in YAML front matter).
# Only the first two --- lines are treated as delimiters; any --- in the
# topic body (e.g. user researching YAML syntax) is passed through.
TOPIC=$(awk '/^---$/ && count<2 {count++; next} count>=2' "$STATE_FILE" | sed '/^$/d')

if [ -z "$TOPIC" ]; then
  log "ERROR: no topic found in state file"
  rm -f "$STATE_FILE"
  exit 0
fi

WORKSPACE="research/${RESEARCH_ID}"
SCRIPT_DIR="$(cd "$(dirname "$0")/../scripts" && pwd)"
PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ── Lock acquire/release (is_lock_alive defined above) ────────────────
acquire_lock() {
  if [ -f "$LOCK_FILE" ]; then
    if is_lock_alive; then
      local lock_content
      lock_content=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
      log "SKIP: another hook is running phases (lock=$lock_content)"
      jq -n '{decision:"block", reason:"Research agents are still running. Please wait."}'
      exit 0
    else
      log "WARN: removing stale lock"
      rm -f "$LOCK_FILE"
    fi
  fi
  echo "$$:$(date +%s)" > "$LOCK_FILE"
}

release_lock() {
  rm -f "$LOCK_FILE"
}

# Export test mode for child scripts
export RESEARCH_TEST_MODE="${TEST_MODE:-false}"

# ── Phase: research ──────────────────────────────────────────────────────
run_research() {
  log "Starting Phase 1: Initial Research"

  bash "${PLUGIN_ROOT}/scripts/run-research-phase.sh" \
    "$RESEARCH_ID" \
    "$TOPIC" \
    "$MAX_ITERS" \
    "$CLAUDE_MODEL" \
    "$CODEX_MODEL" \
    "$CODEX_REASONING"
  RESULT=$?
  log "Phase 1 finished (exit $RESULT)"

  # Check if any reports were produced
  REPORTS_FOUND=0
  for f in "${WORKSPACE}/claude-report.md" "${WORKSPACE}/codex-report.md"; do
    [ -f "$f" ] && [ -s "$f" ] && REPORTS_FOUND=$((REPORTS_FOUND + 1))
  done

  if [ "$REPORTS_FOUND" -eq 0 ]; then
    log "FATAL: No reports produced in Phase 1"
    rm -f "$STATE_FILE"
    rm -f "$LOCK_FILE"
    REASON="ERROR: No research reports were produced by any agent. Check ${WORKSPACE}/progress.log and the agent stdout logs for errors. Common issues:
- Codex CLI not authenticated (run 'codex login')
- Claude API key not configured
- Model names not available on your subscription tier

Review the logs and try again with /deep-research"
    jq -n --arg r "$REASON" '{decision:"block", reason:$r}'
    return
  fi

  # Update state to refinement
  sedi 's/^phase: research$/phase: refinement/' "$STATE_FILE"
}

# ── Phase: refinement ────────────────────────────────────────────────────
run_refinement() {
  log "Starting Phase 2: Cross-Pollination Refinement"

  bash "${PLUGIN_ROOT}/scripts/run-refinement-phase.sh" \
    "$RESEARCH_ID" \
    "$TOPIC" \
    "$MAX_ITERS" \
    "$CLAUDE_MODEL" \
    "$CODEX_MODEL" \
    "$CODEX_REASONING"
  REFINE_RESULT=$?
  log "Phase 2 finished (exit $REFINE_RESULT)"

  # Check if any refined reports were produced
  REFINED_COUNT=0
  for f in "${WORKSPACE}/claude-refined.md" "${WORKSPACE}/codex-refined.md"; do
    [ -f "$f" ] && [ -s "$f" ] && REFINED_COUNT=$((REFINED_COUNT + 1))
  done

  if [ "$REFINED_COUNT" -eq 0 ]; then
    log "FATAL: No refined reports produced in Phase 2"
    rm -f "$STATE_FILE"
    release_lock
    REASON="ERROR: Refinement phase failed — no refined reports were produced by any agent. Check ${WORKSPACE}/progress.log and agent stdout logs for errors.

Review the logs and try again with /deep-research"
    jq -n --arg r "$REASON" '{decision:"block", reason:$r}'
    return
  fi

  # Update state to synthesis
  sedi 's/^phase: refinement$/phase: synthesis/' "$STATE_FILE"

  # Fall through to synthesis
}

# ── Phase: synthesis (automated sub-agent) ────────────────────────────────
run_synthesis() {
  log "Starting Phase 3: Synthesis"

  # Build report list and coverage note from refined reports
  REPORT_LIST=""
  MISSING_LIST=""
  AGENT_NAMES=("Claude" "Codex")
  AGENT_FILES=("${WORKSPACE}/claude-refined.md" "${WORKSPACE}/codex-refined.md")
  AVAILABLE_COUNT=0

  for i in 0 1; do
    f="${AGENT_FILES[$i]}"
    name="${AGENT_NAMES[$i]}"
    if [ -f "$f" ] && [ -s "$f" ]; then
      REPORT_LIST="${REPORT_LIST}
- ${f} (${name})"
      AVAILABLE_COUNT=$((AVAILABLE_COUNT + 1))
    else
      name_lower=$(echo "$name" | tr '[:upper:]' '[:lower:]')
      MISSING_LIST="${MISSING_LIST}
- ${name}: no report (check ${WORKSPACE}/${name_lower}-refine-stdout.log)"
    fi
  done

  if [ "$AVAILABLE_COUNT" -eq 0 ]; then
    log "FATAL: No refined reports available for synthesis"
    rm -f "$STATE_FILE"
    release_lock
    REASON="ERROR: No refined reports found for synthesis. Check ${WORKSPACE}/progress.log for errors."
    jq -n --arg r "$REASON" '{decision:"block", reason:$r}'
    return
  fi

  COVERAGE_NOTE=""
  if [ -n "$MISSING_LIST" ]; then
    COVERAGE_NOTE="

NOTE: Not all agents produced reports. Missing:${MISSING_LIST}

Your synthesis should note this reduced coverage in the Methodology section."
  fi

  bash "${PLUGIN_ROOT}/scripts/run-synthesis-phase.sh" \
    "$RESEARCH_ID" \
    "$TOPIC" \
    "$CLAUDE_MODEL" \
    "$REPORT_LIST" \
    "$COVERAGE_NOTE"
  SYNTH_RESULT=$?
  log "Phase 3 finished (exit $SYNTH_RESULT)"

  # Verify final report exists and has completion marker
  FINAL="${WORKSPACE}/final-report.md"
  if [ -f "$FINAL" ] && [ -s "$FINAL" ]; then
    log "Synthesis complete: ${FINAL} ($(wc -l < "$FINAL") lines)"
    sedi 's/^phase: synthesis$/phase: complete/' "$STATE_FILE"
    sedi 's/^active: true$/active: false/' "$STATE_FILE"
  else
    log "ERROR: synthesis agent finished but final-report.md not found or empty"
    REASON="ERROR: Synthesis agent failed to produce final-report.md. Check ${WORKSPACE}/synthesis-stdout.log for errors.

Review the logs and try again with /deep-research"
    jq -n --arg r "$REASON" '{decision:"block", reason:$r}'
  fi
}

# ── Phase: synthesis (safety net — normally handled by run_synthesis fall-through) ──
check_synthesis() {
  FINAL="${WORKSPACE}/final-report.md"
  if [ -f "$FINAL" ] && [ -s "$FINAL" ]; then
    log "Synthesis verified: ${FINAL} ($(wc -l < "$FINAL") lines)"
    sedi 's/^active: true$/active: false/' "$STATE_FILE"
    sedi 's/^phase: synthesis$/phase: complete/' "$STATE_FILE"
    exit 0
  else
    # Synthesis sub-agent didn't produce the file — run it
    acquire_lock
    run_synthesis
    release_lock
  fi
}

# ── State machine ────────────────────────────────────────────────────────
# Disable global ERR trap during phase execution — errors are handled explicitly
trap - ERR

case "$PHASE" in
  research)
    acquire_lock
    run_research
    # Fall through to refinement if research succeeded
    if [ "$(parse_field "phase")" = "refinement" ]; then
      run_refinement
    fi
    # Fall through to synthesis if refinement succeeded
    if [ "$(parse_field "phase")" = "synthesis" ]; then
      run_synthesis
    fi
    release_lock
    ;;

  refinement)
    acquire_lock
    run_refinement
    # Fall through to synthesis if refinement succeeded
    if [ "$(parse_field "phase")" = "synthesis" ]; then
      run_synthesis
    fi
    release_lock
    ;;

  synthesis)
    check_synthesis
    ;;

  complete)
    # All done — allow exit
    exit 0
    ;;

  *)
    log "WARN: unknown phase '$PHASE', cleaning up"
    rm -f "$STATE_FILE"
    exit 0
    ;;
esac
