#!/bin/bash
# Read pipeline status
# Usage: pipeline-status.sh <pipeline-name>
set -euo pipefail

PIPELINE_NAME="${1:-}"

if [ -z "$PIPELINE_NAME" ]; then
    # List all pipelines
    PIPELINE_BASE="${HOME}/.claude/orchestrator/pipelines"
    if [ -d "$PIPELINE_BASE" ]; then
        echo "Active pipelines:"
        for d in "$PIPELINE_BASE"/*/; do
            [ -d "$d" ] || continue
            name=$(basename "$d")
            state_file="${d}pipeline-state.json"
            if [ -f "$state_file" ]; then
                status=$(python3 -c "import json; print(json.load(open('$state_file'))['status'])" 2>/dev/null || echo "corrupt")
                current=$(python3 -c "import json; print(json.load(open('$state_file'))['current_run'])" 2>/dev/null || echo "?")
                total=$(python3 -c "import json; print(len(json.load(open('$state_file'))['runs']))" 2>/dev/null || echo "?")
                echo "  ${name} — ${status} (run ${current}/${total})"
            fi
        done
    else
        echo "No pipelines found."
    fi
    exit 0
fi

STATE_FILE="${HOME}/.claude/orchestrator/pipelines/${PIPELINE_NAME}/pipeline-state.json"

if [ ! -f "$STATE_FILE" ]; then
    echo "ERROR: Pipeline '${PIPELINE_NAME}' not found" >&2
    exit 1
fi

python3 -c "
import json
with open('${STATE_FILE}') as f:
    state = json.load(f)

print(f\"Pipeline: {state['pipeline_name']} ({state['pipeline_id']})\")
print(f\"Status: {state['status']}\")
print(f\"Current run: {state['current_run']}/{len(state['runs'])}\")
print()
for i, run in enumerate(state['runs'], 1):
    icon = {'pending': '⏳', 'in_progress': '🔄', 'completed': '✅', 'failed': '❌'}.get(run['status'], '❓')
    print(f\"  {icon} Run {i}: {run['name']} — {run['status']}\")
    if run.get('summary'):
        print(f\"     Summary: {run['summary']}\")
    if run.get('output_file'):
        print(f\"     Output: {run['output_file']}\")
"
