#!/bin/bash
# Update pipeline run status
# Usage: pipeline-update.sh <pipeline-name> <run-index> <status> [output_file] [summary]
set -euo pipefail

PIPELINE_NAME="${1:-}"
RUN_INDEX="${2:-}"
NEW_STATUS="${3:-}"
OUTPUT_FILE="${4:-}"
SUMMARY="${5:-}"

if [ -z "$PIPELINE_NAME" ] || [ -z "$RUN_INDEX" ] || [ -z "$NEW_STATUS" ]; then
    echo "Usage: pipeline-update.sh <pipeline-name> <run-index> <status> [output_file] [summary]" >&2
    exit 1
fi

STATE_FILE="${HOME}/.claude/orchestrator/pipelines/${PIPELINE_NAME}/pipeline-state.json"

if [ ! -f "$STATE_FILE" ]; then
    echo "ERROR: Pipeline '${PIPELINE_NAME}' not found" >&2
    exit 1
fi

NOW=$(date -u +%Y-%m-%dT%H:%M:%S+08:00)

python3 -c "
import json, sys
with open('${STATE_FILE}') as f:
    state = json.load(f)

idx = ${RUN_INDEX} - 1
if idx < 0 or idx >= len(state['runs']):
    print(f'ERROR: Run index ${RUN_INDEX} out of range (1-{len(state[\"runs\"])})', file=sys.stderr)
    sys.exit(1)

run = state['runs'][idx]
run['status'] = '${NEW_STATUS}'

if '${NEW_STATUS}' == 'in_progress':
    run['started_at'] = '${NOW}'
    state['current_run'] = ${RUN_INDEX}
elif '${NEW_STATUS}' == 'completed':
    run['completed_at'] = '${NOW}'
    if '${OUTPUT_FILE}':
        run['output_file'] = '${OUTPUT_FILE}'
    if '${SUMMARY}':
        run['summary'] = '${SUMMARY}'
    # Advance current_run if not the last
    if ${RUN_INDEX} < len(state['runs']):
        state['current_run'] = ${RUN_INDEX} + 1

# Update pipeline status
statuses = [r['status'] for r in state['runs']]
if all(s == 'completed' for s in statuses):
    state['status'] = 'completed'
elif any(s == 'failed' for s in statuses):
    state['status'] = 'failed'
elif any(s == 'in_progress' for s in statuses):
    state['status'] = 'in_progress'

state['updated_at'] = '${NOW}'
with open('${STATE_FILE}', 'w') as f:
    json.dump(state, f, indent=2, ensure_ascii=False)
print(json.dumps({'updated': 'run ${RUN_INDEX}', 'status': '${NEW_STATUS}', 'pipeline_status': state['status']}))
"
