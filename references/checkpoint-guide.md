# 检查点系统指南

## 目录结构

检查点系统涉及的子目录。完整目录树见 SKILL.md §5.5（唯一权威视图）。

```
~/.claude/orchestrator/
├── checkpoints/
│   ├── orch-YYYYMMDD-HHMMSS-<pid>.json    ← 当前活跃的编排任务（时间戳+PID，天然唯一）
│   └── archive/                   ← 已完成/已放弃的归档
├── output/                         ← Agent 输出文件 + 共享上下文
└── history.log                     ← 操作日志
```

## 检查点文件格式

```json
{
  "orchestrator_id": "orch-20260515-180000-12345",
  "coordinator_pid": 12345,
  "created_at": "2026-05-15T18:00:00+08:00",
  "updated_at": "2026-05-15T18:30:00+08:00",
  "status": "in_progress",
  "scenario": "code_dev",
  "goal": "实现用户认证系统",
  "checkpoint_mode": "full",
  "model_provider": "deepseek",
  "teams_mode": false,
  "summary": null,
  "tasks": [
    {
      "claude_task_id": "1",
      "subject": "实现注册模块",
      "description": "创建 POST /api/register 端点...",
      "status": "completed",
      "assigned_agent": null,
      "blockedBy": [],
      "agent_output": "已创建 register.ts，实现输入验证...",
      "agent_session_id": "d800ec28-be71-481e-9a27-8a76e92880e6",
      "error": null,
      "error_type": null,
      "retry_count": 0,
      "recovery_action": null,
      "criticality": "critical",
      "started_at": "2026-05-15T18:01:00+08:00",
      "completed_at": "2026-05-15T18:08:00+08:00",
      "sub_steps": [
        {
          "step_id": "1.1",
          "description": "设计数据模型",
          "status": "completed",
          "output_summary": "定义 User schema"
        }
      ]
    }
  ],
  "hitl_gates": [
    {
      "gate_id": "approval-1",
      "after_task": "3",
      "mode": "approval",
      "question": "请确认后继续",
      "status": "pending",
      "user_response": null
    }
  ],
  "dag_snapshots": [
    {
      "version": 1,
      "timestamp": "2026-05-15T18:00:00+08:00",
      "trigger": "initial",
      "description": "初始 DAG",
      "tasks_snapshot": ["1", "2", "3", "4", "5", "6"]
    }
  ]
}
```

## Level 1.5: 核心/静态字段分离（轻量检查点）

Level 1.5 介于 Level 1（任务级）和 Level 2（子步骤级）之间，通过将检查点字段拆分为**核心字段**和**静态字段**来减少每次状态变更的 I/O 量。这是当前 stable 模式的直接优化，不破坏现有检查点兼容性。

### 核心字段（core）— 每 turn 更新

每次状态变更时立即写回。预计大小 500B-2KB：

```json
{
  "status": "in_progress",
  "updated_at": "ISO时间戳",
  "tasks": [{
    "claude_task_id": "5",
    "status": "completed",
    "retry_count": 0,
    "agent_output_ref": "results/task-5.json"
  }],
  "hitl_gates": [{"gate_id": "x", "status": "pending"}],
  "budget": {"consumed_estimate": 125000}
}
```

**核心字段清单：**

| 字段 | 说明 | 更新频率 |
|------|------|---------|
| `status` | 编排整体状态 | 每 turn |
| `updated_at` | 最后更新时间戳 | 每 turn |
| `tasks[].status` | 每个任务的状态 | Agent 完成/失败时 |
| `tasks[].agent_output_ref` | Agent 输出文件路径引用（非内联文本） | Agent 完成时 |
| `tasks[].retry_count` | 重试次数 | 重试发生时 |
| `tasks[].error` / `error_type` | 错误信息 | 失败发生时 |
| `tasks[].recovery_action` | 恢复动作 | 错误恢复时 |
| `tasks[].started_at` / `completed_at` | 时间戳 | 任务开始/完成时 |
| `hitl_gates[].status` | HITL 关卡状态 | 审批完成时 |
| `hitl_gates[].user_response` | 用户回复 | HITL 交互时 |
| `budget` | Token 消耗估算 | 每 turn |

### 静态字段（static）— 仅创建时写入

创建检查点时一次性写入，后续只读不写。预计大小 ~3KB：

```json
{
  "orchestrator_id": "orch-...",
  "coordinator_pid": "12345",
  "created_at": "...",
  "scenario": "code_dev",
  "goal": "用户原始输入",
  "checkpoint_mode": "full",
  "checkpoint_version": 2,
  "model_provider": "deepseek",
  "teams_mode": false,
  "tasks_static": [{
    "claude_task_id": "5",
    "subject": "审计端点: /api/users",
    "description": "...",
    "blockedBy": [],
    "criticality": "normal",
    "completion_criteria": ["检查auth", "验证输入"],
    "sub_steps": []
  }],
  "dag_snapshots": []
}
```

**静态字段清单：**

| 字段 | 说明 | 写入时机 |
|------|------|---------|
| `orchestrator_id` | 编排唯一标识 | 创建时 |
| `coordinator_pid` | Coordinator 进程 PID | 创建时 |
| `created_at` | 创建时间戳 | 创建时 |
| `scenario` | 场景类型 | 创建时 |
| `goal` | 用户原始输入 | 创建时 |
| `checkpoint_mode` | 检查点模式 | 创建时 |
| `checkpoint_version` | 检查点格式版本（1=旧格式，2=核心/静态分离） | 创建时 |
| `model_provider` | 模型提供商 | 创建时 |
| `teams_mode` | 是否 Teams 模式 | 创建时 |
| `tasks_static` | 任务的静态属性（subject/description/blockedBy/criticality/sub_steps/completion_criteria） | 创建时 |
| `dag_snapshots` | DAG 变更历史 | DAG 调整时追加 |

### 目录结构（Level 1.5）

```
~/.claude/orchestrator/checkpoints/<orch-id>/
├── core.json          ← 核心字段 (~1KB，高频写入)
├── static.json        ← 静态字段 (~3KB，只读)
└── results/
    ├── task-5.json    ← Agent 5 的完整输出
    ├── task-6.json    ← Agent 6 的完整输出
    └── ...
```

### Agent 输出独立存储

Agent 的完整输出文本不再内联到检查点 JSON 中。检查点只记录文件路径引用 `agent_output_ref`：

```json
// core.json 中的任务条目
{
  "claude_task_id": "5",
  "status": "completed",
  "agent_output_ref": "results/task-5.json",
  "retry_count": 0
}
```

完整输出写入 `results/<task_id>.json`：

```bash
# Coordinator 在 Agent 完成时
mkdir -p ~/.claude/orchestrator/checkpoints/<orch-id>/results
# 将 Agent 输出写入独立文件
echo "$AGENT_OUTPUT" > ~/.claude/orchestrator/checkpoints/<orch-id>/results/task-5.json
```

**恢复时读取：** Coordinator 通过 `agent_output_ref` 路径定位并读取 Agent 输出，无需解析大型内联 JSON。

### 更新策略

- **Coordinator 只重写核心字段**：通过维护 `core.json` 和 `static.json` 两个独立文件，或通过 `jq` 合并
- **静态字段只读不写**：创建后不再修改（dag_snapshots 追加除外）
- **向后兼容**：`checkpoint_version: 1` 使用旧格式（单文件，所有字段内联），`checkpoint_version: 2` 使用核心/静态分离格式。Coordinator 根据 `checkpoint_version` 字段自动选择读写策略

### 预期收益

| 指标 | 旧格式 (v1) | 新格式 (v2) | 改善 |
|------|-----------|-----------|------|
| 每次状态变更写入量 | 3-50KB | 500B-2KB | 60-80% 减少 |
| 10 任务编排检查点峰值 | 20-50KB | ~2KB (core) + ~3KB (static) | 核心写入减少 90% |
| Agent 输出定位 | 解析大型 JSON | 直接读取独立文件 | 按需加载 |

## 状态转换

```
pending → in_progress → completed
                     ↘ failed → (重试) → in_progress
```

## 恢复流程

1. Coordinator 启动时执行：
   ```bash
   ls ~/.claude/orchestrator/checkpoints/orch-*.json 2>/dev/null
   ```

2. 发现 `status: "in_progress"` 的检查点 → **先做 PID 存活检测**：
   ```bash
   CHECKPOINT_PID=$(cat <检查点文件>.pid 2>/dev/null)
   if kill -0 "$CHECKPOINT_PID" 2>/dev/null; then
     echo "跳过（PID $CHECKPOINT_PID 仍存活，可能在另一窗口运行中）"
   else
     echo "确认废弃（PID $CHECKPOINT_PID 已退出）"
   fi
   ```
   仅当进程已退出时，才提示用户恢复：
   ```
   检测到未完成任务（已确认废弃）：
     目标：实现用户认证系统
     场景：代码开发
     进度：3/6 已完成
     上次更新：2026-05-15 18:30
     原 PID：12345（已退出）
   
   是否恢复？ [恢复] [放弃并归档] [忽略]
   ```

3. 恢复：读取已完成任务的输出 → 继续执行未完成任务

4. 归档：移动检查点到 `archive/`，标记 `status: "archived"`

## DAG 快照（动态调整追踪）

当 DAG 在运行时发生调整（Split/Merge/Append/Replan），每次变更记录一个快照：

```json
{
  "version": 2,
  "timestamp": "2026-05-15T18:15:00+08:00",
  "trigger": "split|merge|append|replan",
  "description": "变更原因和详情",
  "tasks_snapshot": ["T1", "T2", "T3a", "T3b", "T4"]
}
```

- `version`: DAG 版本号，从 1 开始递增
- `trigger`: 触发本次调整的原因
- `tasks_snapshot`: 调整后的完整任务 ID 列表
- 中断恢复时，使用最新版本的 DAG 快照

## 清理策略

- **自动归档**：`status: "completed"` 超过 7 天的检查点移动到 `archive/`
- **输出清理**：`archive/` 中的检查点关联的 output 文件保留 30 天后删除
- **手动清理**：`/orchestrate clean` 删除所有已完成检查点

## 错误处理（三级分级恢复）

### 错误分类

| 级别 | 名称 | 典型信号 | 恢复策略 | 最大重试 | 耗尽后动作 |
|------|------|---------|---------|---------|-----------|
| **E1** | 局部错误 | 超时、工具调用失败、格式解析错 | 指数退避重试 (1s→4s→16s) | 3 次 | optional→skip / normal→通知下游 / critical→升级E3 |
| **E2** | 上游错误 | 验证不通过、输入数据矛盾、引用缺失 | 回溯上游重执行+Agent反馈 | 上游2次 | 升级E3 |
| **E3** | 结构错误 | 多Agent同时失败、重试耗尽、DAG前提矛盾 | Replan模式:暂停→调整DAG→HITL确认 | Coordinator评估 | 用户决策 |

### 恢复流程

```
Agent 失败
  ├── E1 局部错误
  │     → 指数退避: 1s → 4s → 16s (最多3次)
  │     → 3次后仍失败:
  │         ├── criticality=optional → 标记 failed，跳过（不阻塞 DAG）
  │         ├── criticality=normal   → 标记 failed，通知下游自行处理缺失输入
  │         └── criticality=critical → 升级为 E3，触发 Replan
  │
  ├── E2 上游错误
  │     → 找到上游 Agent, 注入 Verifier 反馈
  │     → 上游 Agent 重新执行 (最多2次)
  │     → 2次后仍失败 → 升级为 E3
  │
  └── E3 结构错误
        → 暂停全编排
        → Coordinator 进入 Replan
        → 输出调整方案
        → HITL approval gate → 用户确认
        → 按新 DAG 继续
```

### 检查点新增字段

| 字段 | 类型 | 说明 |
|------|------|------|
| `error_type` | `E1\|E2\|E3\|null` | Agent 失败时的错误分级 |
| `retry_count` | number | 当前任务已重试次数 |
| `recovery_action` | `retry\|replan\|skip\|escalate\|null` | 采取的恢复动作 |

## 增量检查点（Level 2 — 中期目标）

当前 Level 1（任务级）恢复需要重跑整个未完成的任务。Level 2（子步骤级）允许从任务内部的中断点继续。

### 子步骤快照格式

每个 `incremental` 模式的任务在检查点中维护 `sub_steps` 数组：

```json
{
  "claude_task_id": "5",
  "subject": "T3: 实现JWT中间件",
  "status": "in_progress",
  "checkpoint_mode": "incremental",
  "sub_steps": [
    {"step_id": "3.1", "description": "分析JWT标准规范", "status": "completed", "output_summary": "确认使用RS256算法，token过期时间15分钟"},
    {"step_id": "3.2", "description": "实现token签发逻辑", "status": "completed", "output_summary": "已完成sign()和verify()函数，包含错误处理"},
    {"step_id": "3.3", "description": "实现中间件集成", "status": "in_progress", "output_summary": null},
    {"step_id": "3.4", "description": "编写单元测试", "status": "pending", "output_summary": null}
  ]
}
```

### 恢复流程

```
1. 检测 in_progress 任务有 sub_steps
2. 收集所有 completed 子步骤的 output_summary
3. 构建恢复上下文:
   [Resume Context]
   以下子步骤已完成，请从最后一个未完成步骤继续:
   - Step 3.1 (completed): 确认使用RS256算法...
   - Step 3.2 (completed): 已完成sign()和verify()函数...
   当前需完成: Step 3.3 — 实现中间件集成
4. 重新 spawn Agent，注入恢复上下文 + 原始任务描述
5. Agent 跳过已完成步骤，从断点继续
```

### 子步骤上报

Agent 通过事件系统上报子步骤进度（见 SKILL.md §5.5）。Coordinator 在检查点更新时同步写入 `sub_steps` 数组。

### Level 2 状态机

```
pending → in_progress (sub_steps 初始化)
  → sub_step.N in_progress → completed (N递增)
  → 所有 sub_steps completed → task status = completed
  → 中断 → 恢复时读取 sub_steps，从断点继续
```

### 实现清单

- [ ] `checkpoint_mode: "incremental"` 在任务创建时设置
- [ ] Agent 在每个子步骤完成时上报 `task.substep` 事件
- [ ] Coordinator 在收到 `task.substep` 事件时更新检查点 `sub_steps`
- [ ] 恢复逻辑：读取 `sub_steps` → 构建 `[Resume Context]` → 注入 Agent prompt

