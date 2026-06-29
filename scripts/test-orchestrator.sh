#!/bin/bash
# End-to-end integration tests for multi-agent-orchestrator skill
# Tests that the orchestrator infrastructure (checkpoints, events, scripts) works correctly
# Does NOT spawn actual Agent calls — tests the orchestration plumbing only
set -euo pipefail

ORCH_DIR="${HOME}/.claude/orchestrator"
SKILL_DIR="${HOME}/.claude/skills/multi-agent-orchestrator"
PASS=0
FAIL=0

green() { printf '\033[32m%s\033[0m\n' "$1"; }
red()   { printf '\033[31m%s\033[0m\n' "$1"; }

check() {
    local desc="$1"
    if eval "$2"; then
        green "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        red "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Multi-Agent Orchestrator Integration Tests ==="
echo ""

# ── Test 1: Directory structure exists ──
echo "--- 1. Infrastructure ---"
check "orchestrator base dir exists" '[ -d "$ORCH_DIR" ]'
check "checkpoints dir exists" '[ -d "$ORCH_DIR/checkpoints" ]'
check "events dir exists" '[ -d "$ORCH_DIR/events" ]'
check "output dir exists" '[ -d "$ORCH_DIR/output" ]'
check "templates dir exists" '[ -d "$ORCH_DIR/templates" ]'

# ── Test 2: Skill files present ──
echo "--- 2. Skill Files ---"
check "SKILL.md exists" '[ -f "$SKILL_DIR/SKILL.md" ]'
check "design.md exists" '[ -f "$SKILL_DIR/design.md" ]'
check "templates/progress-injection.md exists" '[ -f "$SKILL_DIR/templates/progress-injection.md" ]'

for ref in quick-start role-templates sop-templates hitl-workflow checkpoint-guide \
            code-dev-dag deep-research-dag general-dag dependency-dsl; do
    check "references/${ref}.md exists" '[ -f "$SKILL_DIR/references/${ref}.md" ]'
done

# ── Test 3: Script executability ──
echo "--- 3. Scripts ---"
for script in checkpoint-resume; do
    check "scripts/${script}.sh is executable" '[ -x "$SKILL_DIR/scripts/${script}.sh" ]'
done

# ── Test 4: Checkpoint system ──
echo "--- 4. Checkpoint System ---"

TEST_ORCH_ID="orch-test-$(date +%Y%m%d-%H%M%S)-$$"
TEST_CP="${ORCH_DIR}/checkpoints/${TEST_ORCH_ID}.json"
TEST_PID="${ORCH_DIR}/checkpoints/${TEST_ORCH_ID}.pid"

# Create test checkpoint
cat > "$TEST_CP" << 'CPEOF'
{
  "orchestrator_id": "orch-test-placeholder",
  "coordinator_pid": 99999,
  "created_at": "2026-01-01T00:00:00+08:00",
  "updated_at": "2026-01-01T00:00:00+08:00",
  "status": "in_progress",
  "scenario": "deep_research",
  "goal": "test checkpoint resume",
  "checkpoint_mode": "full",
  "tasks": [
    {
      "claude_task_id": "1",
      "subject": "T1: test task completed",
      "status": "completed",
      "blockedBy": [],
      "criticality": "normal"
    },
    {
      "claude_task_id": "2",
      "subject": "T2: test task with sub-steps",
      "status": "in_progress",
      "blockedBy": [],
      "criticality": "critical",
      "checkpoint_mode": "incremental",
      "sub_steps": [
        {"step_id": "2.1", "description": "analyze requirements", "status": "completed", "output_summary": "Found 3 requirements"},
        {"step_id": "2.2", "description": "design solution", "status": "completed", "output_summary": "Chose pattern X"},
        {"step_id": "2.3", "description": "implement core", "status": "in_progress", "output_summary": null},
        {"step_id": "2.4", "description": "write tests", "status": "pending", "output_summary": null}
      ]
    },
    {
      "claude_task_id": "3",
      "subject": "T3: test task pending",
      "status": "pending",
      "blockedBy": ["T2"],
      "criticality": "normal"
    }
  ],
  "hitl_gates": [
    {"gate_id": "test-gate", "after_task": "1", "mode": "approval", "question": "Continue?", "status": "pending"}
  ]
}
CPEOF
echo "$TEST_ORCH_ID" > "$TEST_PID"

check "test checkpoint created" '[ -f "$TEST_CP" ]'

# Test checkpoint-resume.sh
RESUME_OUTPUT=$(bash "$SKILL_DIR/scripts/checkpoint-resume.sh" "$TEST_CP" 2>&1)
check "checkpoint-resume.sh runs without error" 'echo "$RESUME_OUTPUT" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null'

# Verify resume output structure
check "resume detects completed task" 'echo "$RESUME_OUTPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d[\"progress\"]==\"1/3\", f\"Expected 1/3, got {d[\"progress\"]}\"" 2>/dev/null'
check "resume detects incremental sub-steps" 'echo "$RESUME_OUTPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); assert any(a[\"action\"]==\"resume_from_step\" for a in d[\"resume_actions\"]), \"No resume_from_step action\"" 2>/dev/null'
check "resume detects pending HITL gate" 'echo "$RESUME_OUTPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); assert len(d[\"needs_hitl_response\"])==1, f\"Expected 1 gate, got {len(d['needs_hitl_response'])}\"" 2>/dev/null'

# Test PID-based dead detection
check "dead PID detected (kill -0 fails)" '[ -f "$TEST_PID" ] && ! kill -0 99999 2>/dev/null'

# Cleanup
rm -f "$TEST_CP" "$TEST_PID"
check "test checkpoint cleaned up" '[ ! -f "$TEST_CP" ]'

# ── Test 5: Event system ──
echo "--- 5. Event System ---"

TEST_EVENTS="${ORCH_DIR}/events/${TEST_ORCH_ID}.jsonl"
TEST_SEQ="${ORCH_DIR}/seq_tracker/${TEST_ORCH_ID}.seq"

# Simulate agent events
mkdir -p "$(dirname "$TEST_EVENTS")" "$(dirname "$TEST_SEQ")"
echo '{"event":"task.started","orch_id":"test","data":{"task_id":"T1"}}' > "$TEST_EVENTS"
echo '{"event":"task.completed","orch_id":"test","data":{"task_id":"T1"}}' >> "$TEST_EVENTS"
echo '{"event":"orchestrator.phase","orch_id":"test","data":{"phase":"verify"}}' >> "$TEST_EVENTS"
echo "0" > "$TEST_SEQ"

check "event file created" '[ -f "$TEST_EVENTS" ]'
check "event file has 3 lines" '[ $(wc -l < "$TEST_EVENTS") -eq 3 ]'

# Test seq tracker consumption logic
LAST_SEQ=$(cat "$TEST_SEQ")
CURRENT_LINES=$(wc -l < "$TEST_EVENTS" | tr -d ' ')
check "seq tracker can detect new events" '[ "$CURRENT_LINES" -gt "$LAST_SEQ" ]'

# Simulate reading new events (tail from last_seq+1)
NEW_EVENTS=$(tail -n +$((LAST_SEQ + 1)) "$TEST_EVENTS")
check "can read new events from seq position" '[ $(echo "$NEW_EVENTS" | wc -l) -eq 3 ]'

# Update seq tracker
echo "$CURRENT_LINES" > "$TEST_SEQ"
check "seq tracker updated" '[ $(cat "$TEST_SEQ") -eq 3 ]'

# Cleanup
rm -f "$TEST_EVENTS" "$TEST_SEQ"
rmdir "$(dirname "$TEST_EVENTS")" 2>/dev/null || true
rmdir "$(dirname "$TEST_SEQ")" 2>/dev/null || true

# ── Test 6: Role template parsing ──
echo "--- 6. Role Templates ---"
check "role-templates.md has 7 roles" '[ $(grep -c "^## [0-9]\." "$SKILL_DIR/references/role-templates.md") -ge 7 ]'

# ── Test 7: SOP template parsing ──
echo "--- 7. SOP Templates ---"
check "sop-templates.md has 4 SOPs" '[ $(grep -c "^## SOP [0-9]:" "$SKILL_DIR/references/sop-templates.md") -eq 4 ]'

# ── Test 8: DAG template completeness ──
echo "--- 8. DAG Templates ---"
check "code-dev-dag has example section" 'grep -q "示例" "$SKILL_DIR/references/code-dev-dag.md"'
check "deep-research-dag has example section" 'grep -q "示例" "$SKILL_DIR/references/deep-research-dag.md"'
check "general-dag has example section" 'grep -q "示例" "$SKILL_DIR/references/general-dag.md"'
check "DSL has complete examples" 'grep -q "auth-system.dsl" "$SKILL_DIR/references/dependency-dsl.md"'

# ── Summary ──
echo ""
echo "========================================="
printf "Results: "
[ $FAIL -eq 0 ] && green "$PASS passed, $FAIL failed" || red "$PASS passed, $FAIL failed"
echo "========================================="

exit $FAIL
