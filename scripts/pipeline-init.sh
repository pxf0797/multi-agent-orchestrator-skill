#!/bin/bash
# Initialize a pipeline state file
# Usage: pipeline-init.sh <pipeline-name> <run-name-1> <run-name-2> ...
set -euo pipefail

PIPELINE_NAME="${1:-}"
shift || true

if [ -z "$PIPELINE_NAME" ]; then
    echo "Usage: pipeline-init.sh <pipeline-name> <run-name-1> [run-name-2 ...]" >&2
    exit 1
fi

PIPELINE_DIR="${HOME}/.claude/orchestrator/pipelines/${PIPELINE_NAME}"
STATE_FILE="${PIPELINE_DIR}/pipeline-state.json"

if [ -f "$STATE_FILE" ]; then
    echo "ERROR: Pipeline '${PIPELINE_NAME}' already exists at ${STATE_FILE}" >&2
    echo "Use 'pipeline-status.sh ${PIPELINE_NAME}' to view or resume." >&2
    exit 1
fi

mkdir -p "$PIPELINE_DIR"

NOW=$(date -u +%Y-%m-%dT%H:%M:%S+08:00)
PIPELINE_ID="pipeline-$(date +%Y%m%d-%H%M%S)-$$"

# Build runs array
RUNS_JSON="["
i=1
for name in "$@"; do
    dir="${PIPELINE_DIR}/run-$(printf '%02d' $i)-${name}"
    mkdir -p "$dir"
    if [ $i -gt 1 ]; then
        RUNS_JSON+=","
    fi
    RUNS_JSON+="{\"run_id\":null,\"name\":\"${name}\",\"status\":\"pending\",\"output_dir\":\"${dir}\",\"output_file\":null,\"summary\":null,\"started_at\":null,\"completed_at\":null}"
    i=$((i+1))
done
RUNS_JSON+="]"

python3 -c "
import json
state = {
    'pipeline_id': '${PIPELINE_ID}',
    'pipeline_name': '${PIPELINE_NAME}',
    'status': 'pending',
    'current_run': 1,
    'runs': json.loads('''${RUNS_JSON}'''),
    'created_at': '${NOW}',
    'updated_at': '${NOW}'
}
with open('${STATE_FILE}', 'w') as f:
    json.dump(state, f, indent=2, ensure_ascii=False)
print(json.dumps({'pipeline_id': state['pipeline_id'], 'run_count': len(state['runs'])}))
"

echo "Pipeline initialized: ${PIPELINE_NAME} (${PIPELINE_ID})"
echo "State file: ${STATE_FILE}"
