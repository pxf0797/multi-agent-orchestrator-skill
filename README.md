# Multi-Agent Orchestrator Skill

A Claude Code Skill that transforms complex goals into parallel DAG task graphs, dispatches agents, and aggregates results — all through natural language.

## How It Works

```
User: "Research X, build Y, compare Z"
                |
        ┌───────┴───────┐
        ▼               ▼
   Coordinator      Task System
   (拆解+调度)       (DAG + blockedBy)
        │               │
   ┌────┼────┬────┐     │
   ▼    ▼    ▼    ▼     ▼
 Agent Agent Agent Agent ── 并行执行
        │         │
        └────┬────┘
             ▼
        Result Aggregation
```

1. **Scene Recognition** — identifies `code_dev`, `deep_research`, or `general` tasks
2. **Task Decomposition** — breaks goals into 2-10 single-responsibility subtasks
3. **DAG Generation** — creates dependency graph with `blockedBy`
4. **Parallel Dispatch** — launches agents concurrently (max 4)
5. **Result Aggregation** — merges, deduplicates, and presents structured output

## Key Features

- **Parallel-first execution** — independent tasks run simultaneously
- **DAG dependency management** — explicit `blockedBy` chains prevent race conditions
- **Checkpoint persistence** — resume interrupted tasks from any point
- **Dual-mode dispatch** — direct Agent calls (default) or Agent Teams (for worker-to-worker communication)
- **Token-efficient model allocation** — Coordinator (Opus/Pro), Dev Agent (Sonnet/Flash), Search (Haiku/Flash)
- **3 scenario templates** — code development, deep research, and general-purpose DAG patterns

## File Structure

```
multi-agent-orchestrator-skill/
├── SKILL.md              ← Main skill definition + Coordinator prompt
├── design.md             ← Architecture design document
├── README.md
└── references/
    ├── code-dev-dag.md       ← Code development DAG template
    ├── deep-research-dag.md  ← Deep research DAG template
    └── checkpoint-guide.md   ← Checkpoint management guide
```

## Usage

```
/orchestrate 帮我实现用户认证系统（注册、登录、JWT、密码重置）
/swarm 研究多Agent编排框架并出对比报告
```

Also auto-triggers on keywords: 并行, 多个 agent, 同时, swarm, team.

## Requirements

- Claude Code with Agent tool access
- `~/.claude/orchestrator/` directory (auto-created on first run)

## Design

See [design.md](design.md) for the full architecture design, including:
- External framework benchmarking (LangGraph, CrewAI, MetaGPT, etc.)

- Role template library
- Domain SOP templates
- Human-in-the-loop (HITL) design
- Three-tier development roadmap
