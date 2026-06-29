# 手动串联指南：多 Orchestrator Run 串行编排

研究路线图 **短期目标**：在一次会话中手动串联多个 Orchestrator Run，通过文件系统传递状态。

## 核心理念

```
Orchestrator Run 1            Orchestrator Run 2            Orchestrator Run 3
┌─────────────────┐          ┌─────────────────┐          ┌─────────────────┐
│  并行搜索 → 汇总  │  ──→   │  并行开发 → 集成  │  ──→   │  并行测试 → 审查  │
└─────────────────┘          └─────────────────┘          └─────────────────┘
        │                            │                            │
        ▼                            ▼                            ▼
  输出到文件                     读取上游文件                  读取上游文件
  保存状态                       更新状态                      完成
```

每个 Orchestrator Run 是完整的编排周期（拆解→调度→汇总），Run 之间通过约定好的文件传递数据。

## 使用场景

| 场景 | Run 1 | Run 2 | Run 3 |
|------|-------|-------|-------|
| 多阶段项目 | 深度研究 | 架构设计 | 代码实现 |
| 数据处理 | 数据提取 | 数据转换 | 数据加载 |
| 内容生产 | 素材收集 | 内容撰写 | 质量审阅 |

## 文件约定

### 输出目录结构

```
~/.claude/orchestrator/pipelines/<pipeline-name>/
├── pipeline-state.json          ← 管线状态文件
├── run-01-research/             ← 第一个 Run 的输出
│   └── final-report.md
├── run-02-design/               ← 第二个 Run 的输出
│   └── architecture-design.md
└── run-03-implement/            ← 第三个 Run 的输出
    └── integration-summary.md
```

### Pipeline 状态文件格式

```json
{
  "pipeline_id": "pipeline-20260629-230000",
  "pipeline_name": "project-lifecycle",
  "status": "in_progress",
  "current_run": 2,
  "runs": [
    {
      "run_id": "orch-20260629-220000-11111",
      "name": "research",
      "status": "completed",
      "output_dir": "~/.claude/orchestrator/pipelines/project-lifecycle/run-01-research",
      "output_file": "~/.claude/orchestrator/pipelines/project-lifecycle/run-01-research/final-report.md",
      "summary": "完成了XX技术调研，识别了3个关键风险",
      "started_at": "2026-06-29T22:00:00+08:00",
      "completed_at": "2026-06-29T22:15:00+08:00"
    },
    {
      "run_id": "orch-20260629-223000-22222",
      "name": "design",
      "status": "in_progress",
      "output_dir": "~/.claude/orchestrator/pipelines/project-lifecycle/run-02-design",
      "started_at": "2026-06-29T22:30:00+08:00"
    },
    {
      "run_id": null,
      "name": "implement",
      "status": "pending",
      "output_dir": "~/.claude/orchestrator/pipelines/project-lifecycle/run-03-implement"
    }
  ]
}
```

## 操作流程

### Step 1: 初始化管线

```
/orchestrate pipeline init <pipeline-name>

Coordinator 创建:
  - ~/.claude/orchestrator/pipelines/<pipeline-name>/pipeline-state.json
  - 规划各 Run 的角色、输入、输出
```

### Step 2: 执行第一个 Run

```
/orchestrate <第一个Run的目标>

Coordinator 在 prompt 末尾自动追加:
  "请将最终产物保存到 ~/.claude/orchestrator/pipelines/<pipeline-name>/run-01-<name>/"
```

### Step 3: 手动串联后续 Run

```
/orchestrate <下一个Run的目标>
上下文：上一个Run的输出在 <output-dir>/final-report.md
请基于该输出继续。

Coordinator 在 Agent prompt 的 [Shared Context] 段注入上游输出路径。
```

### Step 4: 查看管线进度

```
/orchestrate pipeline status <pipeline-name>

Coordinator 读取 pipeline-state.json，展示:
  - 当前处于第几个 Run
  - 每个 Run 的完成状态
  - 累计耗时和 Token
```

### Step 5: 管线完成

所有 Run 完成后，Coordinator 生成管线总结报告。

## Coordinator Prompt 追加规则

当检测到管线上下文时（pipeline-state.json 存在），Coordinator 在以下时机注入上下文：

### 调度 Agent 时

```
[Pipeline Context]
当前管线: <pipeline-name>
上游 Run: <name> — 输出: <output-file>
关键发现: <上游 Run 的 summary 字段>
```

### 汇总阶段

```
[Pipeline Context]
当前是管线第 <N> 个 Run
已完成: Run 1 (<name>), Run 2 (<name>)
本 Run 产出将作为 Run <N+1> 的输入
请在汇总时标注哪些结论依赖上游输出
```

## 状态更新脚本

```bash
# 初始化管线
bash ~/.claude/skills/multi-agent-orchestrator/scripts/pipeline-init.sh <pipeline-name> <run-names...>

# 更新 Run 状态
bash ~/.claude/skills/multi-agent-orchestrator/scripts/pipeline-update.sh <pipeline-name> <run-index> <status>

# 读取管线状态
bash ~/.claude/skills/multi-agent-orchestrator/scripts/pipeline-status.sh <pipeline-name>
```

## 典型示例：三阶段项目

```
用户: "帮我做一个完整的技术选型项目：先研究微服务框架，再设计架构，最后实现核心模块"

Step 1 — /orchestrate pipeline init ms-tech-selection

Step 2 — /orchestrate 深入研究微服务框架（Spring Cloud vs Go Kit vs Kubernetes native），输出对比报告

Step 3 — /orchestrate 基于研究报告设计系统架构
        上下文：~/.../pipelines/ms-tech-selection/run-01-research/final-report.md

Step 4 — /orchestrate 实现核心模块（服务注册、配置中心、API 网关）
        上下文：~/.../pipelines/ms-tech-selection/run-02-design/architecture-design.md
```

## 限制

| 限制 | 影响 | 缓解 |
|------|------|------|
| 手动触发每个 Run | 用户需在会话中主动发起 | 中期用 Workflow Manager Skill 自动化 |
| 状态文件可能不同步 | Agent 未正确写入约定路径 | 每个 Run 完成后 Coordinator 验证输出 |
| 无法跨 Session 自动恢复 | Session 结束后管线暂停 | pipeline-state.json 可跨 Session 读取 |
| 上游输出质量影响下游 | 一个 Run 的偏差会放大 | 每个 Run 后设 HITL 审批门禁 |

## 向中期演进

当手动串联模式稳定后，Workflow Manager Skill（已实现）接管：
- YAML 定义管线，不再手动 `/orchestrate pipeline init`
- 自动按 DAG 触发后续 Run
- 状态管理完全自动化

工作流 YAML 示例：
```yaml
name: "ms-tech-selection"
phases:
  - id: research
    prompt: "深入研究微服务框架，输出对比报告"
  - id: design
    prompt: "基于 {{phase.research.output_file}} 设计系统架构"
    depends_on: [research]
    approval: true
  - id: implement
    prompt: "实现核心模块：服务注册、配置中心、API网关"
    depends_on: [design]
```
