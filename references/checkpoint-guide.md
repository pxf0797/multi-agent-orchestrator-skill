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
   CHECKPOINT_PID=$(jq -r '.coordinator_pid' <检查点文件>)
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

