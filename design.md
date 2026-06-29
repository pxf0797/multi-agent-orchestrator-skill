# Multi-Agent Orchestrator Skill — 设计文档

**状态**：草稿 | **日期**：2026-05-15 | **作者**：xfpan + Claude Code

---

## 一、概述

### 1.1 目标

将 Anthropic Managed Agents 的四层解耦架构思想落地为 Claude Code 可用的 **Multi-Agent Orchestrator Skill**，实现：

- 一个 Coordinator 接收复杂目标 → 自动拆解为 DAG 任务图 → 并行调度子 Agent → 汇总结果
- 任务中断后可恢复（轻量 Session Store）
- 适配 DeepSeek / Claude 官方 API 两种环境

### 1.2 核心场景

| 场景 | 触发特征 | DAG 模式 |
|---|---|---|
| **代码开发** | 关键词：实现/开发/重构/写代码/修bug/添加功能 | 并行开发模块 → 汇总 → Code Review |
| **深度研究** | 关键词：研究/调查/分析/报告/对比/总结 | 并行搜索 → 并行写作 → 汇总报告 |
| **通用任务** | 不匹配上述模式 | Coordinator 动态推断 DAG 结构 |

### 1.3 与 Managed Agents 四层架构的对照

| Managed Agents 层级 | Claude Code 等价实现 |
|---|---|
| 第一层：脑/手解耦 | Agent 工具直调（独立子进程，各自上下文） |
| 第二层：Coordinator | Skill 定义的 Coordinator Prompt + Task 系统 |
| 第三层：Session 记忆树 | `~/.claude/orchestrator/checkpoints/` 文件持久化 |
| 第四层：Session Store | 检查点文件可跨 session 恢复（文件级，非 Redis） |

### 1.4 框架定位

Orchestrator Skill 位于多 Agent 框架栈的 **高层应用层**，不替代底层运行时：

```
高层应用层 ─── 【Orchestrator Skill】 ── 场景识别、DAG编排、结果聚合
                   │
中层框架层 ─── CrewAI / MetaGPT / CAMEL ── 角色定义、SOP流程、对话管理
                   │
底层运行时层 ── LangGraph / MAF / AutoGen ── 图执行引擎、状态管理、流式控制
```

**与外部框架的互补关系**：Orchestrator Skill 是调度中枢，专注于"拆解什么 + 何时执行"，不关心底层 Agent 如何通信。当需要复杂角色扮演或多轮辩论时，可委托给 CrewAI/MetaGPT 子进程；当需要精确的图执行控制时，可对接 LangGraph 运行时。自身保持轻量，只做规划与编排。

---

## 二、架构设计

### 2.1 整体架构

```
用户输入复杂目标
       │
       ▼
┌──────────────────────────────────┐
│         Coordinator               │
│  (Skill Prompt — 只拆任务不干活)   │
│                                   │
│  1. 识别场景类型                   │
│  2. 拆解为子任务                   │
│  3. 生成 DAG（blockedBy 依赖）      │
│  4. 写入检查点文件                  │
│  5. 调度执行                       │
│  6. 汇总结果                       │
└──────────┬───────────────────────┘
           │
    ┌──────┼──────┬──────┐
    ▼      ▼      ▼      ▼
┌──────┐┌──────┐┌──────┐┌──────┐
│Agent ││Agent ││Agent ││Agent │  ← 并行 spawn
│  #1  ││  #2  ││  #3  ││  #N  │
└──┬───┘└──┬───┘└──┬───┘└──┬───┘
   │       │       │       │
   └───────┴───┬───┴───────┘
               │
         结果写入检查点
               │
               ▼
         Coordinator 汇总
               │
               ▼
          最终输出
```

### 2.2 组件职责

| 组件 | 职责 | 实现方式 |
|---|---|---|
| **Coordinator** | 理解目标、拆解任务、生成 DAG、调度、汇总 | Skill Prompt + Task 系统 |
| **Task 系统** | 管理任务状态、依赖关系（blockedBy） | Claude Code 内置 TaskCreate/TaskUpdate |
| **Agent 调度器** | 决定用 Teams 还是直调、并行度控制 | Skill 逻辑 + Agent 工具 |
| **检查点管理器** | 保存/恢复任务进度、Agent 输出 | JSON 文件读写 |
| **结果聚合器** | 收集子 Agent 输出、去重、合成 | Coordinator Prompt 指导 |

---

## 三、Coordinator 设计

### 3.1 角色定义

Coordinator 是一个 **只拆任务、不干具体活** 的指挥官。它的 Prompt 核心约束：

```
你是 Multi-Agent Orchestrator 的 Coordinator（编排者）。
你的唯一职责是：理解目标 → 拆解任务 → 调度 Agent → 汇总结果。
你绝不亲自执行具体任务。所有执行工作交给子 Agent。
```

### 3.2 工作流程

```
Step 1: 场景识别
   ├── 分析用户输入的关键词
   ├── 判断属于 [代码开发|深度研究|通用任务]
   └── 选择对应的 DAG 模板

Step 2: 任务拆解
   ├── 将目标拆为 2-N 个子任务（不超过 10 个，避免过度碎片化）
   ├── 每个子任务：单一职责、独立可验证、有明确输出
   └── 识别子任务之间的依赖关系

Step 3: 生成 DAG
   ├── 用 TaskCreate 创建所有子任务
   ├── 用 addBlockedBy 设置依赖
   └── 保存检查点到 ~/.claude/orchestrator/checkpoints/<task-id>.json

Step 4: 调度执行
   ├── 识别所有 blockedBy 为空的就绪任务
   ├── 并行 spawn Agent（max 4 并发）
   ├── 每个 Agent 完成 → TaskUpdate(status: completed) → 解锁下游任务
   └── 循环直到所有任务完成或失败

Step 5: 结果汇总
   ├── 从检查点读取所有 Agent 输出
   ├── 去重、合并、结构化
   └── 输出最终结果给用户
```

### 3.3 场景识别规则

```
代码开发特征:
  关键词: 实现|开发|重构|写|修bug|修复|添加功能|优化性能|写测试
  DAG: 并行开发 → 汇总 → Review

深度研究特征:
  关键词: 研究|调查|分析|报告|对比|总结|侦查|scout|调研
  DAG: 并行搜索 → 并行写作 → 汇总报告

通用任务:
  不匹配上述特征时
  DAG: Coordinator 动态分析依赖关系后决定
```

---

## 四、DAG 任务图设计

### 4.1 代码开发 DAG

```
              ┌──────────────┐
              │  Coordinator  │
              │  拆解开发任务  │
              └──────┬───────┘
                     │
       ┌─────────────┼─────────────┐
       ▼             ▼             ▼
┌───────────┐ ┌───────────┐ ┌───────────┐
│  模块 A    │ │  模块 B    │ │  模块 C    │  ← 并行开发
│  (Agent)   │ │  (Agent)   │ │  (Agent)   │
└─────┬─────┘ └─────┬─────┘ └─────┬─────┘
      └──────────────┼──────────────┘
                     │
                     ▼
            ┌───────────────┐
            │   集成汇总     │  ← 依赖所有模块完成
            │   (Agent)     │
            └───────┬───────┘
                    │
                    ▼
            ┌───────────────┐
            │  Code Review  │  ← 可选，最终质量检查
            │   (Agent)     │
            └───────────────┘
```

### 4.2 深度研究 DAG

```
              ┌──────────────┐
              │  Coordinator  │
              │  拆解研究课题  │
              └──────┬───────┘
                     │
       ┌─────────────┼─────────────┐
       ▼             ▼             ▼
┌───────────┐ ┌───────────┐ ┌───────────┐
│ 搜索维度A  │ │ 搜索维度B  │ │ 搜索维度C  │  ← 并行搜索
│  (Agent)   │ │  (Agent)   │ │  (Agent)   │
└─────┬─────┘ └─────┬─────┘ └─────┬─────┘
      └──────────────┼──────────────┘
                     │
       ┌─────────────┼─────────────┐
       ▼             ▼             ▼
┌───────────┐ ┌───────────┐ ┌───────────┐
│ 写作整理A  │ │ 写作整理B  │ │ 写作整理C  │  ← 并行写作
│  (Agent)   │ │  (Agent)   │ │  (Agent)   │
└─────┬─────┘ └─────┬─────┘ └─────┬─────┘
      └──────────────┼──────────────┘
                     │
                     ▼
            ┌───────────────┐
            │   汇总报告     │  ← 最终合成
            │   (Agent)     │
            └───────────────┘
```

### 4.3 通用 DAG

Coordinator 动态分析任务依赖，不套用固定模板。原则：

- **无依赖 → 并行**：能同时跑的绝不串行
- **有依赖 → blockedBy**：上游完成才触发下游
- **最大并行度 4**：避免 API 速率限制

---

## 五、Agent 调度策略

### 5.1 实测结论：Teams 模式 vs 直调 Agent 模式

经过与 Claude Code Agent Teams 的实际测试，得出以下关键结论：

| 维度 | Teams 模式 | 直调 Agent 模式 | 结论 |
|---|---|---|---|
| **结果回传** | Workers 完成初始任务后仅发送 `idle_notification`，无法通过消息返回结果 | 完成时自动通知，`output_file` 含完整结果 | **直调胜出** |
| **任务结束** | 需手动 `shutdown`，部分 worker 会卡住 | 任务完成后自动结束 | **直调胜出** |
| **模型指定** | 模型映射存在 bug（尤其是 DeepSeek 环境） | 模型可精确指定，稳定可靠 | **直调胜出** |
| **Task 系统集成** | Team 独立任务列表，主会话 `TaskList` 返回空 | Task 系统与主会话一致，状态可追踪 | **直调胜出** |
| **Worker 间通信** | 支持 Worker 间双向交互 | Worker 间独立，无直接通信 | **Teams 胜出** |

**调度策略结论**：

1. **默认使用直调 Agent 模式** — 适合绝大多数 fire-and-forget 任务（Coordinator 派发任务、收集结果，Worker 之间无需互通）
2. **Teams 模式仅用于双向交互场景** — 当任务需要 Worker 之间相互讨论、协商、辩论时（如多角色 Code Review 讨论），才启用 Teams
3. **`teams_disabled` 标记** — 已在 `~/.claude/orchestrator/teams_disabled` 设置永久禁用标记，环境检测已优化为跳过 Teams 探测，直接使用直调模式

### 5.2 双模式调度

```
调度决策树:

1. 检查 ~/.claude/orchestrator/teams_disabled 是否存在
   ├── 存在 → 直接使用直调 Agent 模式（跳过后续检查）
   └── 不存在 → 继续步骤 2

2. 判断任务是否需要 Worker 间双向交互？
   ├── 不需要（默认）→ 使用直调 Agent 模式
   └── 需要 → 继续步骤 3

3. 检查 Teams 可用性：
   [ -z "$ANTHROPIC_BASE_URL" ] || [[ "$ANTHROPIC_BASE_URL" == *"api.anthropic.com"* ]]
   ├── 通过 → 尝试 Teams 模式
   │       ├── TeamCreate 成功 → Teams 模式（worker 间可相互通信）
   │       └── TeamCreate 失败 → touch teams_disabled → 回退到直调 Agent
   └── 不通过 → touch teams_disabled → 使用直调 Agent 模式

Teams 禁用标记: ~/.claude/orchestrator/teams_disabled
  - 存在此文件 → 永久使用直调模式（跳过 Teams 探测）
  - 不存在 → 仅当第2步判断需要双向交互时，才进入第3步尝试 Teams
```

### 5.3 直调 Agent 实现（DeepSeek 兼容 — 默认模式）

```
对每个就绪的子任务:
  Agent(
    description: "<子任务摘要>",
    prompt: "<Coordinator 编写的完整任务描述 + 上下文>",
    subagent_type: "general-purpose",  // 或根据任务类型选择
    run_in_background: true            // 并行启动
  )

优势:
  - 完成时自动通知 Coordinator，output_file 包含完整结果
  - 自动结束，无需手动 shutdown
  - 模型可精确指定，无映射 bug
  - Task 状态与主会话一致，可通过 TaskList 追踪
```

### 5.4 并发控制

| 参数 | 值 | 说明 |
|---|---|---|
| 最大并行 Agent | 4 | 避免 API 速率限制 |
| Agent 超时 | 600s | 单个 Agent 最长执行时间 |
| 重试次数 | 1 | 失败后自动重试一次 |

### 5.5 模型分配策略（Token Efficiency）

```
Coordinator:     大模型（opus） — 复杂推理和规划
并行开发 Agent:  中模型（sonnet） — 代码生成
搜索 Agent:      小模型（haiku） — 信息搜集
汇总 Agent:      大模型（opus） — 需要全局视角
```

---

## 六、状态持久化设计

### 6.1 检查点文件

```
~/.claude/orchestrator/
├── checkpoints/
│   ├── <orchestrator-task-id>.json    ← 当前活跃任务
│   │   ├── snapshots/                 ← 增量快照（子步骤级）
│   │   │   ├── step-001.json
│   │   │   ├── step-002.json
│   │   │   └── ...
│   │   └── archive/
│   │       └── <orchestrator-task-id>.json ← 已完成任务归档
│   └── index.json                     ← 检查点索引（快速查找）
├── teams_disabled                     ← Teams 模式永久禁用标记
└── history.log                        ← 操作日志
```

### 6.2 检查点文件结构（增强版）

```json
{
  "orchestrator_id": "orch-20260515-180000-12345",
  "coordinator_pid": 12345,
  "created_at": "2026-05-15T18:00:00Z",
  "updated_at": "2026-05-15T18:15:00Z",
  "status": "in_progress | completed | failed",
  "scenario": "code_dev | deep_research | general",
  "goal": "用户原始输入",
  "checkpoint_version": 2,
  "checkpoint_mode": "full | incremental | delta",
  "checkpoint_sequence": 4,
  "dag": {
    "tasks": [
      {
        "task_id": "1",
        "subject": "...",
        "description": "...",
        "status": "completed",
        "blockedBy": [],
        "agent_output": "...",
        "agent_session_id": "d800ec28-...",
        "sub_steps": [
          {
            "step_id": "1.1",
            "description": "分析需求",
            "status": "completed",
            "output_summary": "...",
            "started_at": "2026-05-15T18:01:00Z",
            "completed_at": "2026-05-15T18:03:00Z"
          },
          {
            "step_id": "1.2",
            "description": "编写核心逻辑",
            "status": "completed",
            "output_summary": "...",
            "started_at": "2026-05-15T18:03:00Z",
            "completed_at": "2026-05-15T18:08:00Z"
          }
        ],
        "retry_count": 0,
        "last_error": null
      }
    ]
  },
  "hitl_gates": [
    {
      "gate_id": "approval-1",
      "after_task": "3",
      "question": "模块A和B的设计方案已生成，请审阅后确认继续",
      "status": "pending | approved | rejected",
      "user_response": null
    }
  ],
  "summary": null
}
```

### 6.3 增量检查点与断点续传

#### 检查点保存策略

```
三种持久化模式（借鉴 LangGraph 设计）：

1. Full Checkpoint（任务级）
   - 触发：每个 Task 完成后
   - 内容：完整 DAG 状态快照
   - 开销：大（~10-50KB），但完整可恢复

2. Incremental Checkpoint（子步骤级）
   - 触发：Agent 内每个关键子步骤完成后
   - 内容：仅该步骤的增量数据（output_summary、状态变更）
   - 开销：小（~1-5KB），高频保存
   - 存储：checkpoints/<task-id>/snapshots/step-NNN.json

3. Delta Checkpoint（变更级）
   - 触发：任何状态字段变更时
   - 内容：仅变更的字段 diff（JSON Patch 格式）
   - 开销：极小（~100-500B），最高频
   - 用途：精确恢复到任意时间点

保存频率：
  - Delta：每次子步骤状态变更（实时）
  - Incremental：每个子步骤完成（每 1-3 分钟）
  - Full：每个 Task 完成（每 5-15 分钟）
```

#### 断点续传粒度

```
恢复粒度层级（由粗到细）：

Level 1: 任务级恢复（当前实现）
  - 读取已完成任务的 agent_output
  - 重新执行所有未完成的任务
  - 缺点：一个任务跑到 80% 中断，需从头重跑

Level 2: 子步骤级恢复（增量检查点增强）
  - 读取任务下已完成子步骤的 output_summary
  - Agent 恢复时注入"已完成子步骤摘要"作为上下文前缀
  - Agent 从最后一个未完成子步骤继续
  - 节省：避免重复已完成的子步骤工作

Level 3: 精确级恢复（Delta 检查点增强 — 远期目标）
  - 恢复到任务内任意子步骤的精确状态
  - 需 Agent 支持状态注入（传递 sub_step context）
  - 依赖：Agent 工具支持 session 恢复参数

当前实现目标：Level 2（子步骤级恢复）
远期目标：Level 3（需 Claude Code Agent 原生支持 session 恢复）
```

### 6.4 恢复流程

```
1. Coordinator 启动时扫描 ~/.claude/orchestrator/checkpoints/
2. 发现 status=in_progress 的检查点 → PID 存活检测:
   ├── 读取检查点的 coordinator_pid 字段
   ├── kill -0 <pid> 2>/dev/null:
   │   ├── 进程存活 → 跳过（该编排可能在另一窗口运行中）
   │   └── 进程已退出 → 确认废弃，进入恢复询问
3. 确认废弃后，询问用户是否恢复
4. 恢复：
   ├── 读取已完成任务的 agent_output 和子步骤摘要
   ├── 识别未完成的任务（以及任务内未完成的子步骤）
   ├── 构建恢复上下文：已完成子步骤摘要 + 原始剩余任务描述
   ├── 重新 spawn Agent 执行未完成部分
   └── 继续 DAG 执行
5. 所有任务完成后 → 归档到 archive/，标记 status=completed
6. 清理增量快照（保留最后一个 Full Checkpoint 的快照集）
```

---

## 七、Skill 文件结构

```
~/.claude/skills/
└── multi-agent-orchestrator/
    ├── orchestrator.skill           ← 主 Skill 文件（触发逻辑 + Coordinator Prompt）
    ├── templates/
    │   ├── code-dev-dag.md         ← 代码开发 DAG 模板
    │   ├── deep-research-dag.md    ← 深度研究 DAG 模板
    │   └── general-dag.md          ← 通用 DAG 模板
    ├── dsl/
    │   └── dependency-dsl.md       ← 声明式依赖 DSL 语法定义
    ├── roles/
    │   ├── architect.md            ← 架构师角色模板
    │   ├── developer.md            ← 开发者角色模板
    │   ├── reviewer.md             ← 审查者角色模板
    │   ├── researcher.md           ← 研究员角色模板
    │   ├── writer.md               ← 写作者角色模板
    │   └── qa.md                   ← QA 测试角色模板
    ├── sops/
    │   ├── software-dev.md         ← 软件开发 SOP
    │   ├── research-report.md      ← 研究报告 SOP
    │   ├── code-review.md          ← 代码审查 SOP
    │   └── deploy-verify.md        ← 部署验证 SOP
    ├── scripts/
    │   ├── checkpoint.sh           ← 检查点读写脚本
    │   └── env-detect.sh           ← 环境检测（Teams 是否可用）
    └── prompts/
        ├── coordinator-system.md   ← Coordinator 系统提示词
        ├── agent-code-dev.md       ← 代码开发 Agent 提示词模板
        ├── agent-research.md       ← 研究 Agent 提示词模板
        └── agent-summarizer.md     ← 汇总 Agent 提示词模板
```

### 7.1 触发条件

当用户输入包含以下模式时触发：
- 明确要求多 Agent 协作（"并行"、"同时"、"多个 agent"、"swarm"、"team"）
- 复杂目标超过单一 Agent 合理处理范围（Coordinator 自动判断）
- 用户显式调用 `/orchestrate` 或 `/swarm`

### 7.2 入口流程

```
1. Skill 被触发
2. Coordinator Prompt 加载
3. 场景识别 → 匹配领域 SOP 模板
4. 任务拆解 → 使用声明式 DSL 生成 DAG
5. 角色分配 → 从角色模板库匹配
6. env-detect.sh 检测环境（默认直调模式）
7. HITL 审批关卡注册
8. 按 DAG 调度 Agent
9. 检查点持续更新（增量模式）
10. 结果汇总输出
```

---

## 八、使用示例

### 8.1 代码开发

```
用户: 帮我实现一个用户认证系统，需要注册、登录、JWT中间件、密码重置四个模块

Coordinator:
  1. 识别: 代码开发场景 → 加载 software-dev SOP 模板
  2. 角色分配: Task 1-3 = Developer, Task 5 = QA, Task 6 = Reviewer
  3. 拆解:
     Task 1: 注册模块 (无依赖)
     Task 2: 登录模块 (无依赖)
     Task 3: JWT中间件 (无依赖)
     Task 4: 密码重置 (依赖 Task 2)
     Task 5: 集成测试 (依赖 Task 1,2,3,4)
     Task 6: Code Review (依赖 Task 5)
  4. 调度: Task 1,2,3 并行启动 → Task 4 等待 Task 2 → Task 5 等待所有 → Task 6 最后
  5. HITL: Task 5 完成后暂停，展示测试结果 → 用户确认后启动 Task 6
  6. 汇总: 集成测试通过，输出完整代码 + Review 意见
```

### 8.2 深度研究

```
用户: 调查一下 Claude Code 和 Cursor 的 Agent 能力差异，出对比报告

Coordinator:
  1. 识别: 深度研究场景 → 加载 research-report SOP 模板
  2. 角色分配: Task 1-3 = Researcher, Task 4-5 = Writer, Task 6 = Writer (汇总)
  3. 拆解:
     Task 1: 搜索 Claude Code Agent 能力 (无依赖)
     Task 2: 搜索 Cursor Agent 能力 (无依赖)
     Task 3: 搜索第三方对比评测 (无依赖)
     Task 4: 整理 Claude Code 部分 (依赖 Task 1)
     Task 5: 整理 Cursor 部分 (依赖 Task 2)
     Task 6: 合成对比报告 (依赖 Task 3,4,5)
  4. 调度: 3 个搜索并行 → 2 个写作并行 → 汇总
  5. 输出: 结构化对比报告
```

### 8.3 中断恢复

```
用户: (上次被中断) 继续上次的任务

Coordinator:
  1. 扫描 checkpoints/ → 发现 orch-20260515-180000-12345 (in_progress)
  2. "检测到未完成任务：用户认证系统开发，进度 3/6。Task 3 (JWT中间件) 已完成 2/3 子步骤。是否恢复？"
  3. 用户确认 → 恢复 DAG 状态 → 注入已完成子步骤上下文 → 继续执行
```

---

## 十一、与外部框架对标

### 11.1 对标框架概览

Orchestrator Skill 定位为高层调度中枢，与以下主流多 Agent 框架形成互补而非替代关系。

### 11.2 全面对比

| 维度 | Orchestrator Skill | LangGraph | CrewAI | MetaGPT | CAMEL | BeeAI |
|---|---|---|---|---|---|---|
| **抽象层级** | 高层应用 | 底层运行时 | 中层框架 | 中层框架 | 中层框架 | 中层框架 |
| **调度模型** | Coordinator 中心化 | StateGraph DAG | 顺序/层级 Process | 固定角色链 SOP | Role-Playing 对话 | Agent Network |
| **依赖声明** | blockedBy + DSL（计划中） | `add_edge`/`add_conditional_edge` | `@listen`/`@router` 装饰器 | 固定阶段顺序 | 隐式（对话驱动） | Agent Card 声明 |
| **持久化** | 文件级 JSON 检查点 | SQLite/PostgreSQL 自动 Checkpoint | 无内置（依赖 LangSmith） | 无内置 | 无内置 | 无内置 |
| **检查点粒度** | 子步骤级（计划中） | 每步自动 Checkpoint | — | — | — | — |
| **检查点模式** | 3 种（计划中：Full/Incremental/Delta） | 3 种（Full/Incremental/Delta） | — | — | — | — |
| **断点续传** | 任务级（当前）/ 子步骤级（计划中） | 原生支持（任意 SuperStep） | 无 | 无 | 无 | 无 |
| **加密持久化** | 无（本地文件） | AES 加密可选 | — | — | — | — |
| **HITL 中断** | `hitl_gates`（计划中） | `interrupt()` 原生支持 | `human_input=True` 标记 | 无内置 | 无内置 | 无内置 |
| **流式进度** | 检查点轮询（当前） | 7 种流模式（values/updates/messages/custom/checkpoints/tasks/debug） | 回调输出 | 日志输出 | 对话流 | Agent Event Stream |
| **角色系统** | 角色模板库（计划中） | 无内置 | `role+goal+backstory` 三段式 | 固定角色链（PM/Architect/Engineer） | Role 定义 | Agent Card |
| **领域 SOP** | SOP 模板库（计划中） | 无内置 | 无内置 | 固定 SOP（软件公司） | 无内置 | 无内置 |
| **协议互操作** | 仅 Claude Code Sub-Agent | LangGraph Platform API | 无（Python 库内调用） | 无 | 无 | A2A + MCP 双协议 |
| **运行环境** | Claude Code Skill 沙盒 | Python/JS 独立进程 | Python 独立进程 | Python 独立进程 | Python 独立进程 | TypeScript 独立进程 |
| **安装复杂度** | 零安装（Skill 文件） | `pip install langgraph` | `pip install crewai` | `pip install metagpt` | `pip install camel` | `npm install beeai` |

### 11.3 关键借鉴点

从外部框架对标中识别出的待增强能力：

| 借鉴来源 | 特性 | 当前状态 | 计划采纳 |
|---|---|---|---|
| **CrewAI** | `@listen`/`@router` 声明式依赖装饰器 | 缺失 | **第十二章 — DSL 设计** |
| **LangGraph** | 每步自动 Checkpoint + SQLite 持久化 | 仅文件级 JSON | **第六章增强 — 增量检查点** |
| **LangGraph** | `interrupt()` 动态 HITL | 缺失 | **第十五章 — HITL 设计** |
| **LangGraph** | 7 种流式进度模式 | 仅检查点轮询 | **中期规划 — 流式进度** |
| **CrewAI** | `role+goal+backstory` 三段式角色 | 每次从零生成 | **第十三章 — 角色模板库** |
| **MetaGPT** | 固定角色链 + 领域 SOP | 缺失 | **第十四章 — SOP 模板** |

### 11.4 与外部框架的协作模式

```
场景 A: 纯调度型（默认）
  Orchestrator Skill（拆解+调度）→ Claude Code Sub-Agents（执行）
  适用：代码开发、深度研究、通用任务

场景 B: 委托型（远期）
  Orchestrator Skill（拆解+调度）→ CrewAI/MetaGPT 子进程（复杂角色扮演）
  适用：需要多轮角色辩论的复杂设计决策

场景 C: 精确控制型（远期）
  Orchestrator Skill（拆解+调度）→ LangGraph 运行时（精确图执行）
  适用：需要严格状态管理和检查点的长流程任务
```

---

## 十二、声明式任务依赖 DSL 设计

### 12.1 设计目标

借鉴 CrewAI 的 `@listen`/`@router` 装饰器思想，为 Orchestrator Skill 设计一套轻量级声明式依赖语法，让 Coordinator 用简洁的 DSL 表达任务依赖，而非手写复杂的 TaskCreate + addBlockedBy 调用。

### 12.2 DSL 语法

```
# ── 基础语法 ─────────────────────────────

@task "任务名称"
  描述: "任务的自然语言描述"
  角色: developer | researcher | reviewer | ...
  模型: sonnet | haiku | opus
  输出: "期望的输出格式描述"
  
# ── 依赖声明 ─────────────────────────────

@depends_on(task_id)          # 显式依赖：本任务依赖指定任务
@after(task_id)               # 语义糖：等价于 @depends_on(task_id)
@after_all([task_1, task_2])  # 等待多个任务全部完成

# ── 并行声明 ─────────────────────────────

@parallel                     # 标记本组任务可并行执行
  @task "模块A" { ... }
  @task "模块B" { ... }
  @task "模块C" { ... }

# ── 条件执行 ─────────────────────────────

@conditional                  # 条件分支
  when: "task_3.output.contains('ERROR')"
  then: @task "错误修复" { ... }
  else: @task "继续部署" { ... }

# ── 人机协作标记 ─────────────────────────────

@human_approval               # 执行前需人工审批
  问题: "请确认模块设计"
  超时: 3600                   # 等待超时（秒）
```

### 12.3 完整示例：认证系统开发

```
# orchestrator_dag.dsl

@plan "用户认证系统开发"

@parallel:
  @task "注册模块" {
    描述: "实现用户注册功能，含邮箱验证"
    角色: developer
    模型: sonnet
    输出: "注册模块完整代码 + 单元测试"
  }

  @task "登录模块" {
    描述: "实现用户登录功能，含会话管理"
    角色: developer
    模型: sonnet
    输出: "登录模块完整代码 + 单元测试"
  }

  @task "JWT中间件" {
    描述: "实现 JWT 认证中间件"
    角色: developer
    模型: sonnet
    输出: "JWT 中间件代码 + 使用文档"
  }

@task "密码重置" {
  描述: "实现密码重置流程"
  角色: developer
  模型: sonnet
  输出: "密码重置模块代码 + 测试"
}
@depends_on("登录模块")

@task "集成测试" {
  描述: "对所有模块进行集成测试"
  角色: qa
  模型: sonnet
  输出: "集成测试报告"
}
@after_all(["注册模块", "登录模块", "JWT中间件", "密码重置"])

@task "代码审查" {
  描述: "审查全部代码质量和安全性"
  角色: reviewer
  模型: opus
  输出: "审查报告 + 修改建议"
}
@after("集成测试")
@human_approval {
  问题: "集成测试已完成，请查看报告后决定是否进入代码审查"
}
```

### 12.4 DSL 到 Task 系统的编译

DSL 由 Coordinator 在拆解阶段解析，编译为实际 Task 系统调用：

```
DSL 编译流程:
  1. 解析 @plan → 创建 Orchestrator 检查点文件
  2. 解析 @parallel → 标记任务组，清除组内 blockedBy
  3. 解析 @depends_on / @after → 转换为 Task blockedBy 数组
  4. 解析 @conditional → 创建条件 Task，运行时判断
  5. 解析 @human_approval → 注册 HITL gate
  6. 解析 角色/模型 → 设置 Agent subagent_type 和 model 参数
  7. 生成最终 DAG JSON → 写入检查点文件
```

### 12.5 DSL 实现路径

| 阶段 | 目标 | 实现 |
|---|---|---|
| **短期** | YAML/JSON 结构化任务定义（非正式 DSL） | Coordinator Prompt 中定义 JSON Schema，直接生成 |
| **中期** | `@task`/`@depends_on` 核心语法 | Python/Shell 解析器 or Coordinator Prompt 内置解析 |
| **长期** | 完整 DSL + IDE 支持 | 独立解析器 + VSCode 语法高亮 |

---

## 十三、角色模板库设计

### 13.1 设计目标

借鉴 CrewAI 的 `role + goal + backstory` 三段式角色定义模式，避免 Coordinator 每次从零生成 Agent 角色描述。角色模板库提供可复用的角色定义，确保 Agent 行为一致性和专业度。

### 13.2 角色定义模板

```
角色定义三段式（借鉴 CrewAI）：

  role:      "一句话角色名"        — 如 "Senior Python Developer"
  goal:      "角色的核心目标"       — 如 "编写高质量、可测试的 Python 代码"
  backstory: "角色背景故事"        — 为人格化设定，增强角色行为一致性

扩展字段（Orchestrator Skill 特有）：

  skills:         ["技能1", "技能2"]      — 角色擅长领域
  tools:          ["tool_a", "tool_b"]    — 推荐工具集
  output_format:  "输出格式描述"           — 期望的输出格式
  constraints:    ["约束1", "约束2"]      — 行为约束
  model_prefer:   "sonnet | haiku | opus" — 推荐模型
```

### 13.3 预置角色模板

#### 架构师 (Architect)

```yaml
role: "系统架构师"
goal: "设计高内聚低耦合的系统架构，确保可扩展性和可维护性"
backstory: >
  你是一位有15年经验的系统架构师，曾设计过多个大规模分布式系统。
  你擅长在简洁性和可扩展性之间找到平衡，反对过度设计。
  你在做出架构决策时总会给出清晰的理由。
skills: [系统设计, 技术选型, 接口设计, 数据建模]
tools: [设计文档生成, 图表绘制]
output_format: "架构决策记录 (ADR) 格式"
constraints: [不过度设计, 基于实际需求选型, 标注 tradeoff]
model_prefer: opus
```

#### 开发者 (Developer)

```yaml
role: "高级软件工程师"
goal: "编写清晰、可维护、充分测试的代码"
backstory: >
  你是一位资深软件工程师，遵循 TDD 和 Clean Code 原则。
  你写的代码几乎不需要注释，因为代码本身就是文档。
  你在提交代码前总会运行测试并自我审查。
skills: [编码实现, 单元测试, 代码重构, 性能优化]
tools: [代码编辑器, 测试框架, 静态分析工具]
output_format: "可运行的完整代码文件"
constraints: [遵循现有代码风格, 不过度抽象, 包含错误处理]
model_prefer: sonnet
```

#### 审查者 (Reviewer)

```yaml
role: "代码审查专家"
goal: "发现代码中的逻辑缺陷、安全隐患和风格问题"
backstory: >
  你是一个严格的代码审查者，以发现隐蔽的 bug 和安全隐患而闻名。
  你的审查意见总是建设性的，会指出问题并提供改进建议。
  你关注：正确性 > 安全性 > 性能 > 可读性 > 风格。
skills: [代码审查, 安全审计, 性能分析, 最佳实践评估]
tools: [静态分析, 安全扫描]
output_format: "结构化审查报告：严重问题 / 建议改进 / 亮点"
constraints: [不纠结个人风格偏好, 每个问题附带修复建议, 区分严重级别]
model_prefer: opus
```

#### 研究员 (Researcher)

```yaml
role: "技术研究员"
goal: "全面收集和整理指定领域的信息，提供有深度的分析"
backstory: >
  你是一位技术研究员，擅长快速理解新技术并识别关键信息。
  你不仅收集事实，还会分析趋势、对比竞品、识别机遇。
  你的研究报告以结构清晰、数据翔实著称。
skills: [信息检索, 技术分析, 竞品对比, 趋势判断]
tools: [WebSearch, WebFetch, 文档阅读]
output_format: "结构化研究报告：概述 / 核心发现 / 对比分析 / 建议"
constraints: [标注信息来源, 区分事实和观点, 不遗漏反面观点]
model_prefer: sonnet
```

#### 写作者 (Writer)

```yaml
role: "技术文档撰写者"
goal: "将原始信息整理为清晰、有逻辑、易读的文档"
backstory: >
  你擅长将复杂的技术信息转化为读者友好的文档。
  你的写作风格：先结论后展开，层次分明，善用对比表格。
  你不满足于简单罗列，而是寻找信息之间的内在逻辑。
skills: [技术写作, 结构化表达, 图表设计, 对比分析]
tools: [Markdown 编辑, 表格生成]
output_format: "Markdown 格式文档，含目录、表格、代码块"
constraints: [避免行话堆砌, 每个段落有明确目的, 标注存疑点]
model_prefer: sonnet
```

#### QA 测试 (QA)

```yaml
role: "质量保证工程师"
goal: "验证功能正确性、发现边界情况和回归问题"
backstory: >
  你是一个细心的 QA 工程师，对各种边界情况和异常输入特别敏感。
  你的测试原则：先验证正常流程，再攻击边界条件，最后探索异常场景。
  你不仅发现问题，还会给出可复现的步骤和预期行为。
skills: [测试设计, 边界分析, 回归测试, 性能测试]
tools: [测试框架, 断言库, 性能分析工具]
output_format: "测试报告：通过 / 失败 / 待确认，附带复现步骤"
constraints: [先测核心路径, 每个失败用例可独立复现, 标注环境差异]
model_prefer: sonnet
```

### 13.4 角色模板使用方式

```
Coordinator 分配角色流程:
  1. 拆解任务后，根据任务类型匹配角色模板
     - 编码任务 → Developer
     - 设计任务 → Architect
     - 测试任务 → QA
     - 搜索任务 → Researcher
     - 写作任务 → Writer
     - 审查任务 → Reviewer

  2. 从 roles/ 目录加载对应模板
  3. 注入任务特定上下文（技术栈、约束条件等）
  4. 将 role+goal+backstory+skills 嵌入 Agent prompt
  5. 所有同角色 Agent 共享 backstory，保持行为一致性

  示例 Agent prompt 结构：
    [Backstory]
    [Role + Goal]
    [Skills + Tools]
    [Task-Specific Context: 本次具体任务]
    [Output Format]
    [Constraints]
```

### 13.5 角色自定义

用户可通过以下方式自定义角色：

1. **修改模板文件**：直接编辑 `roles/*.md` 调整预设角色
2. **创建新角色**：在 `roles/` 目录下新增 `.md` 文件，遵循三段式 + 扩展字段格式
3. **运行时覆盖**：在任务 DSL 中指定 `角色: custom_name`，Coordinator 会提示用户定义新角色

---

## 十四、领域 SOP 模板设计

### 14.1 设计目标

借鉴 MetaGPT 的固定 SOP（Standard Operating Procedure）流程思想，为常见任务类型预定义标准化操作流程。SOP 模板确保同类任务每次执行都遵循最佳实践，避免 Coordinator 重复设计流程。

### 14.2 SOP 与 DAG 的关系

```
SOP 模板 = 领域最佳实践的固化流程
    │
    ▼
Coordinator 根据场景选择 SOP
    │
    ▼
SOP 实例化为具体 DAG（根据用户目标填充参数）
    │
    ▼
DAG 调度执行
```

**关键设计**：SOP 定义"这个领域的工作通常怎么分阶段做"，DAG 是"这次具体任务的执行计划"。SOP 提供骨架，DAG 填充血肉。

### 14.3 SOP 模板结构

```yaml
sop:
  name: "软件开发 SOP"
  scenario: "code_dev"
  version: "1.0"
  description: "从需求到代码审查的完整软件开发流程"

  stages:
    - stage: "并行开发"
      description: "无依赖的模块并行开发"
      roles: [developer]
      parallelism: max
      output: "各模块代码 + 单元测试"

    - stage: "依赖开发"
      description: "有依赖关系的模块串行/局部并行开发"
      roles: [developer]
      parallelism: partial
      output: "依赖模块代码 + 测试"

    - stage: "集成测试"
      description: "端到端集成测试验证"
      roles: [qa]
      output: "测试报告"
      hitl_gate: true   # 此阶段后需人工审批

    - stage: "代码审查"
      description: "质量与安全审查"
      roles: [reviewer]
      output: "审查报告"
      optional: true
```

### 14.4 预置 SOP 模板

#### SOP 1: 软件开发 (software-dev)

| 阶段 | 角色 | 并行度 | 输出 | HITL |
|---|---|---|---|---|
| 1. 需求分析与拆解 | Architect | 1 | 模块划分方案 | yes |
| 2. 并行模块开发 | Developer | max(4) | 各模块代码+测试 | no |
| 3. 依赖模块开发 | Developer | partial | 依赖模块代码 | no |
| 4. 集成测试 | QA | 1 | 测试报告 | yes |
| 5. 代码审查 | Reviewer | 1 | 审查报告 | no |

#### SOP 2: 研究报告 (research-report)

| 阶段 | 角色 | 并行度 | 输出 | HITL |
|---|---|---|---|---|
| 1. 课题拆解 | Researcher | 1 | 搜索维度列表 | yes |
| 2. 并行信息搜集 | Researcher | max(4) | 各维度原始资料 | no |
| 3. 分类整理 | Writer | max(3) | 分类整理稿 | no |
| 4. 报告合成 | Writer | 1 | 完整报告 | yes |
| 5. 质量审核 | Reviewer | 1 | 审核意见 | no |

#### SOP 3: 代码审查 (code-review)

| 阶段 | 角色 | 并行度 | 输出 | HITL |
|---|---|---|---|---|
| 1. 静态分析 | Reviewer | 1 | 静态分析报告 | no |
| 2. 逻辑审查 | Reviewer | 1 | 逻辑问题清单 | no |
| 3. 安全审查 | Reviewer | 1 | 安全问题清单 | no |
| 4. 合成报告 | Reviewer | 1 | 综合审查报告 | no |

> 注：逻辑审查和安全审查可并行执行（2 个 Reviewer Agent）。

#### SOP 4: 部署验证 (deploy-verify)

| 阶段 | 角色 | 并行度 | 输出 | HITL |
|---|---|---|---|---|
| 1. 环境检查 | QA | 1 | 环境检查报告 | no |
| 2. 并行功能验证 | QA | max(4) | 各功能验证结果 | no |
| 3. 性能基准测试 | QA | 1 | 性能报告 | no |
| 4. 部署决策 | Coordinator | 1 | 上线/回滚建议 | yes |

### 14.5 SOP 扩展机制

```
用户自定义 SOP:
  1. 在 sops/ 目录创建 <your-sop>.md
  2. 遵循 SOP 模板结构（stages + roles + parallelism + hitl_gate）
  3. Orchestrator 启动时自动扫描 sops/ 目录
  4. 场景识别时优先匹配自定义 SOP

SOP 版本管理:
  - 每个 SOP 文件包含 version 字段
  - 重大流程变更时递增版本号
  - 旧版本 SOP 归档到 sops/archive/
```

---

## 十五、人机协作 (HITL) 设计

### 15.1 设计目标

借鉴 LangGraph 的 `interrupt()` 动态中断机制和 CrewAI 的 `human_input` 标记，为 Orchestrator Skill 引入人机协作能力。HITL 确保在关键决策点引入人类判断，避免自动化执行不可逆或高风险操作。

### 15.2 三种 HITL 模式

| 模式 | 触发时机 | 行为 | 适用场景 |
|---|---|---|---|
| **审批门 (Approval Gate)** | DAG 关键阶段完成后 | 暂停执行，展示阶段结果，等待用户确认/拒绝 | 设计审阅、上线决策 |
| **人工输入 (Human Input)** | 任务执行前/中需要人工提供信息 | 暂停执行，向用户提问，等待输入 | 需要业务判断的任务 |
| **审阅后继续 (Review-then-Continue)** | 阶段性输出产生后 | 暂停执行，展示输出，用户审阅后继续或调整方向 | 报告初稿审阅 |

### 15.3 HITL Gate 配置

在 SOP 或 DAG 中声明 HITL 关卡：

```yaml
hitl_gates:
  - gate_id: "design-review"
    after_task: "架构设计"
    mode: approval              # approval | input | review
    question: "架构设计方案已完成，请审阅。确认后可继续开发？"
    timeout: 3600               # 等待超时（秒），超时后默认行为
    default_action: "pause"     # approve | reject | pause
    show_output: true           # 是否展示上游 Agent 的完整输出
    options:                    # 仅 approval 模式
      - "确认，继续开发"
      - "需要修改：{用户输入修改意见}"
      - "暂停任务，稍后继续"
```

### 15.4 HITL 执行流程

```
HITL Gate 触发流程:

  1. DAG 执行到 hitl_gate.after_task 完成
     │
  2. Coordinator 识别关联的 HITL gate
     │
  3. 暂停 DAG 调度（保持其他进行中任务不变）
     │
  4. 展示 Gate 信息给用户：
     ├── 已完成的阶段摘要
     ├── gate.question
     └── gate.options（如有）
     │
  5. 等待用户响应（最长时间：gate.timeout）
     │
  6. 用户响应处理：
     ├── approve → 继续 DAG 执行
     ├── reject → 标记 gate 为 rejected，DAG 进入修改循环
     ├── input → 将用户输入注入后续 Agent prompt
     └── timeout → 执行 gate.default_action
     │
  7. 更新检查点中的 hitl_gate 状态
     │
  8. 继续或终止 DAG
```

### 15.5 HITL 与检查点的集成

```json
// 检查点文件中的 HITL 状态记录
{
  "hitl_gates": [
    {
      "gate_id": "design-review",
      "after_task": "2",
      "mode": "approval",
      "question": "架构设计方案已完成，请审阅。确认后可继续开发？",
      "status": "approved",
      "user_response": "确认，继续开发",
      "responded_at": "2026-05-15T18:20:00Z",
      "retry_count": 0
    }
  ]
}
```

**恢复场景**：如果 session 在等待 HITL 响应时中断，恢复后 Coordinator 重新展示未响应的 HITL gate，用户可继续审批。

### 15.6 典型 HITL 场景

#### 场景 1：软件开发中的设计审批

```
DAG: 架构设计 → [HITL Gate] → 并行开发 → 集成测试 → Code Review

架构设计 Agent 完成后：
  Coordinator: "架构设计已完成。方案概要：
     - 采用分层架构（Controller → Service → Repository）
     - JWT 认证 + Redis Session
     - PostgreSQL 主库 + Read Replica
   请选择：[确认继续] [修改方案] [暂停]"
```

#### 场景 2：研究报告的初稿审阅

```
DAG: 搜索 → 整理 → [HITL Gate — Review] → 最终报告

整理阶段完成后：
  Coordinator: "研究报告初稿已完成。目录概要：
     1. 市场现状分析
     2. 竞品对比（5款产品）
     3. 技术趋势判断
   请审阅后选择：[继续生成最终报告] [调整方向] [补充某维度]"
```

#### 场景 3：部署决策

```
DAG: 测试 → 性能基准 → [HITL Gate — Approval] → 部署

性能基准测试完成后：
  Coordinator: "性能基准测试完成。
     延迟 P99: 120ms (基线 100ms, +20%)
     错误率: 0.01% (基线 0.01%, 持平)
     QPS: 8500 (基线 8000, +6.25%)
   请选择：[确认上线] [回滚，暂不上线] [查看更多细节]"
```

### 15.7 HITL 实现路径

| 阶段 | 目标 | 实现 |
|---|---|---|
| **短期** | 关键阶段的简单确认提示 | Coordinator 在阶段完成后主动询问用户 |
| **中期** | 结构化 HITL gate（审批/输入/审阅三种模式） | 检查点中记录 gate 状态，支持恢复 |
| **长期** | 条件触发 HITL + 动态审批链 | 支持基于任务输出的动态触发条件 |

---

## 九、限制与风险

| 限制 | 影响 | 缓解措施 |
|---|---|---|
| 无真正沙盒隔离 | Agent 共享本地文件系统，可能冲突 | 每个 Agent 指定独立工作目录 |
| Teams 模型映射 bug | DeepSeek 下 Teams 不可用 | 默认使用直调 Agent；Teams disabled 标记永久生效 |
| Teams fire-and-forget 不可靠 | Workers 仅发 idle_notification，不回传结果 | 直调 Agent 为默认模式，Teams 仅用于双向交互场景 |
| 无云端 Session Store | 检查点仅本地可用 | 归档到 iCloud 目录 |
| 文件级持久化（非 Redis） | 恢复粒度粗（任务级，非事件级） | 增量检查点将粒度提升至子步骤级（Level 2） |
| API 速率限制 | 过多并行 Agent 可能触发限流 | 最大并行度 4 |
| 执行进度不透明 | 用户无法实时感知 Agent 进度 | 中期规划流式进度反馈（借鉴 LangGraph 7 种流模式） |
| 无加密持久化 | 检查点明文存储，敏感信息可能泄露 | 远期规划 AES 加密（借鉴 LangGraph DeltaChannel） |

---

## 十、开发计划

### 10.1 短期（1-2 周）：核心可用 ✅ **已完成 (2026-06-29)**

| 任务 | 产出 | 优先级 | 状态 |
|---|---|---|---|
| Skill 骨架 + Coordinator Prompt | `SKILL.md` 主文件 | P0 | ✅ |
| DAG 模板（3 种场景） | `references/*-dag.md` | P0 | ✅ (code-dev + deep-research + general) |
| 直调 Agent 调度（默认模式） | Skill 调度逻辑 | P0 | ✅ |
| 基础检查点脚本（任务级，Full Checkpoint） | SKILL.md §4 + `references/checkpoint-guide.md` | P0 | ✅ |
| 环境检测 + Teams 禁用标记 | SKILL.md §5.1 | P0 | ✅ |
| Agent 提示词模板 | `templates/progress-injection.md` | P1 | ✅ |
| 基础角色模板（全部 7 个角色） | `references/role-templates.md` | P1 | ✅ |
| 基础 SOP 模板（4 个领域） | `references/sop-templates.md` | P1 | ✅ |
| HITL 工作流参考 | `references/hitl-workflow.md` | P1 | ✅ |
| 快速入门指南 | `references/quick-start.md` | P1 | ✅ |
| workflow-manager 配套集成 | SKILL.md §5.9 | P1 | ✅ |

**里程碑 M1** ✅：Coordinator 可完成"接收复杂目标 → 拆解 → 并行调度 Agent → 汇总"的完整闭环，支持中断恢复。

### 10.2 中期（1-2 月）：增强完善 🔄 **进行中**

| 任务 | 产出 | 优先级 | 状态 |
|---|---|---|---|
| 增量检查点 + 子步骤级恢复（Level 2） | `references/checkpoint-guide.md` §增量检查点 | P0 | ✅ 设计完成，待实现 |
| HITL v1：关键阶段审批门 | `references/hitl-workflow.md` | P0 | ✅ |
| 声明式依赖 DSL v1：JSON/YAML 结构化定义 | `dsl/dependency-dsl.md` | P1 | ⏳ |
| 角色模板库完善（全部 7 个角色） | `references/role-templates.md` | P1 | ✅ |
| SOP 模板库完善（4 个领域 SOP） | `references/sop-templates.md` | P1 | ✅ |
| 流式进度反馈 v1：检查点轮询 + 摘要展示 | `templates/progress-injection.md` + SKILL.md §5.5 | P1 | ✅ |
| 端到端集成测试（3 个场景） | 测试脚本 | P0 | ⏳ |
| HITL v2：三种模式（审批/输入/审阅） | `references/hitl-workflow.md` | P2 | ✅ |

**里程碑 M2**：具备完整的角色模板、SOP 模板、HITL 审批、增量检查点恢复能力，任务可靠性显著提升。

### 10.3 长期（3-6 月）：生态与深度

| 任务 | 产出 | 优先级 |
|---|---|---|
| 完整 DSL 解析器（`@task`/`@depends_on`/`@conditional`） | 独立 DSL 引擎 | P1 |
| DSL IDE 支持（VSCode 语法高亮 + 自动补全） | VSCode 扩展 | P2 |
| 流式进度反馈 v2：借鉴 LangGraph 流模式 | 实时进度推送 | P2 |
| Delta Checkpoint + AES 加密持久化 | 增强持久化层 | P2 |
| 外部框架对接：CrewAI / LangGraph 委托模式 | 对接适配器 | P2 |
| 用户自定义 SOP 共享生态 | SOP 市场 / 社区 | P3 |
| HITL 条件触发 + 动态审批链 | 增强 HITL 引擎 | P2 |
| 多协议互操作（A2A / MCP）探索 | 互操作原型 | P3 |

**里程碑 M3**：Orchestrator Skill 从工具进化为平台，支持社区贡献 SOP/角色模板，可与外部框架协作。

### 10.4 优先级说明

| 级别 | 含义 |
|---|---|
| P0 | 必须完成，阻塞里程碑 |
| P1 | 应该完成，显著增强体验 |
| P2 | 可以完成，锦上添花 |
| P3 | 远期探索，需要更多前置条件 |

---

*本设计基于 Anthropic Managed Agents 架构分析 + Claude Code v2.1.142 现有能力 + 多 Agent 框架生态对标。*
