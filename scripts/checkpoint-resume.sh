#!/bin/bash
# Incremental checkpoint resume — Level 2 sub-step recovery
# Usage: checkpoint-resume.sh <checkpoint-path>
# Output: JSON with resume context and next actions
set -euo pipefail

CHECKPOINT_PATH="${1:-}"

if [ -z "$CHECKPOINT_PATH" ] || [ ! -f "$CHECKPOINT_PATH" ]; then
    echo '{"error": "Usage: checkpoint-resume.sh <checkpoint-path>"}' >&2
    exit 1
fi

python3 -c "
import json, sys, os
from datetime import datetime, timezone

with open('${CHECKPOINT_PATH}') as f:
    ck = json.load(f)

result = {
    'orchestrator_id': ck.get('orchestrator_id', 'unknown'),
    'status': ck.get('status', 'unknown'),
    'scenario': ck.get('scenario', 'unknown'),
    'goal': ck.get('goal', 'unknown'),
    'tasks_summary': [],
    'resume_actions': [],
    'needs_hitl_response': []
}

for t in ck.get('tasks', []):
    task_id = t.get('subject', 'unknown')
    status = t.get('status', 'pending')
    mode = t.get('checkpoint_mode', 'full')
    sub_steps = t.get('sub_steps', [])

    summary = {
        'task': task_id,
        'status': status,
        'checkpoint_mode': mode,
        'completed_substeps': sum(1 for s in sub_steps if s.get('status') == 'completed'),
        'total_substeps': len(sub_steps),
        'resume_from_step': None,
        'resume_context': None
    }

    if status == 'in_progress' and mode == 'incremental' and sub_steps:
        # Find last completed sub-step
        completed = [s for s in sub_steps if s.get('status') == 'completed']
        pending = [s for s in sub_steps if s.get('status') != 'completed']

        if pending:
            next_step = pending[0]
            summary['resume_from_step'] = next_step.get('step_id')
            # Build resume context from completed steps
            completed_context = []
            for s in completed:
                ctx = f\"Step {s.get('step_id')} (completed): {s.get('output_summary', s.get('description', ''))}\"
                completed_context.append(ctx)

            summary['resume_context'] = '\n'.join(completed_context) if completed_context else None

            result['resume_actions'].append({
                'task': task_id,
                'claude_task_id': t.get('claude_task_id'),
                'action': 'resume_from_step',
                'resume_step': next_step.get('step_id'),
                'resume_step_description': next_step.get('description'),
                'inject_context': f\"\"\"[Resume Context]
以下子步骤已完成，请从最后一个未完成步骤继续:
{summary['resume_context']}
当前需完成: Step {next_step.get('step_id')} — {next_step.get('description')}
\"\"\"
            })
        else:
            # All sub-steps completed but task still in_progress — mark complete
            result['resume_actions'].append({
                'task': task_id,
                'claude_task_id': t.get('claude_task_id'),
                'action': 'mark_completed',
                'reason': 'All sub-steps completed'
            })

    elif status == 'pending':
        result['resume_actions'].append({
            'task': task_id,
            'claude_task_id': t.get('claude_task_id'),
            'action': 'start_fresh',
            'reason': 'Task not started'
        })

    result['tasks_summary'].append(summary)

# Check for pending HITL gates
for g in ck.get('hitl_gates', []):
    if g.get('status') == 'pending':
        after_task = g.get('after_task')
        # Check if the triggering task is completed
        for t in ck.get('tasks', []):
            if t.get('subject', '').startswith(f'T{after_task}') or t.get('subject', '') == after_task:
                if t.get('status') == 'completed':
                    result['needs_hitl_response'].append({
                        'gate_id': g.get('gate_id'),
                        'mode': g.get('mode'),
                        'question': g.get('question'),
                        'options': g.get('options', [])
                    })
                break

# Summary stats
completed = sum(1 for t in ck.get('tasks', []) if t.get('status') == 'completed')
total = len(ck.get('tasks', []))
result['progress'] = f'{completed}/{total}'
result['recoverable'] = len(result['resume_actions']) > 0

print(json.dumps(result, indent=2, ensure_ascii=False))
"
