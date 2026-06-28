# 流式进度系统 v2 — 详细设计

**作者**：架构分析 | **日期**：2026-05-15 | **版本**：2.0

---

## 1. 事件类型与 Schema

所有事件共享顶级封装结构：

```json
{
  "event": "<event_type>",
  "orch_id": "orch-20260515-180322-12345",
  "task_id": "3",
  "timestamp": "2026-05-15T18:03:22.145Z",
  "sequence": 17,
  "data": { }
}
```

### 1.1 task.started — Agent 启动执行

```json
{
  "event": "task.started",
  "data": {
    "subject": "实现 JWT 中间件",
    "role": "developer",
    "model": "sonnet",
    "agent_id": "d800ec28-...",
    "estimated_duration_sec": 300,
    "dependencies_met": ["1", "2"],
    "phase": 2
  }
}
```

### 1.2 task.substep — 子步骤完成

```json
{
  "event": "task.substep",
  "data": {
    "step_id": "3.2",
    "description": "编写 JWT 签发逻辑",
    "status": "completed|in_progress|failed",
    "elapsed_sec": 47,
    "output_preview": "已实现 token 签发函数..."
  }
}
```

### 1.3 task.heartbeat — 周期性心跳（每 30s）

```json
{
  "event": "task.heartbeat",
  "data": {
    "since_start_sec": 158,
    "substep_index": 4,
    "total_substeps": 7,
    "current_operation": "正在生成测试用例..."
  }
}
```

超过 90 秒无心跳 → 标记为可能的卡死。

### 1.4 task.output_preview — 中间输出预览

```json
{
  "event": "task.output_preview",
  "data": {
    "content_type": "code|text|report",
    "preview": "function signToken(payload: JwtPayload): string { ...",
    "char_count": 187,
    "truncated": true
  }
}
```

最多 200 字符，与 `substep` 的区别：substep 是有边界的状态完成，output_preview 是流式内容推送。

### 1.5 task.completed — Agent 完成执行

```json
{
  "event": "task.completed",
  "data": {
    "subject": "实现 JWT 中间件",
    "duration_sec": 293,
    "token_estimate": 4200,
    "output_summary": "JWT 中间件完整实现：签发、验证、刷新三个端点",
    "output_path": "~/.claude/orchestrator/outputs/orch-180322-12345/task-3-output.md",
    "task_progress": "3/6",
    "phase_progress": "2/4",
    "unblocked_tasks": ["4", "5"],
    "error": null
  }
}
```

### 1.6 checkpoint.saved — 检查点持久化

```json
{
  "event": "checkpoint.saved",
  "data": {
    "mode": "full|incremental|delta",
    "sequence": 7,
    "size_bytes": 12500,
    "path": ".../checkpoints/orch-180322-12345.json",
    "tasks_snapshot": {"completed": 3, "in_progress": 2, "pending": 1, "failed": 0}
  }
}
```

### 1.7 orchestrator.phase — SOP 阶段切换

```json
{
  "event": "orchestrator.phase",
  "data": {
    "from_phase": 2,
    "to_phase": 3,
    "phase_name": "集成测试",
    "phase_description": "对所有模块进行集成测试验证",
    "phase_total": 5,
    "elapsed_total_sec": 620,
    "progress_overall": "3/6"
  }
}
```

---

## 2. 传输机制

### 方案 A：文件轮询（推荐）

**架构**：
```
Agent (run_in_background)
  └── 通过 Bash 工具往事件文件追加 JSONL 行
       └── ~/.claude/orchestrator/events/<orch-id>.jsonl

Coordinator (主会话)
  └── Monitor/until-loop 轮询事件文件
       └── 按 sequence 读取新行 → 展示给用户
```

**读取**：`tail -f events.jsonl` 完美匹配 Monitor 工具。

**写入**：Agent 在关键节点通过注入的 Bash 脚本执行：
```bash
echo '{"event":"task.substep","orch_id":"orch-180322-12345","task_id":"3",...}' >> ~/.claude/orchestrator/events/orch-180322-12345.jsonl
```

### 方案对比

| 维度 | A: 文件轮询 | B: 检查点嵌入 | C: Hook 触发 |
|------|-----------|-------------|------------|
| **延迟** | ~500ms | ~1-3s | Task 完成时 |
| **中间事件** | 全支持 | 全支持 | 不支持 |
| **并发安全** | 好（append-only） | 差（并发写冲突） | 好 |
| **实现复杂度** | 低 | 中 | 低 |
| **文件膨胀** | 低（JSONL 行序追加） | 高（全量 JSON） | 低 |
| **推荐** | ⭐ | — | — |

### Agent 进度注入

Coordinator 在 Agent prompt 末尾注入进度上报模板（`templates/progress-injection.md`），Agent 在每个子步骤开始/完成时通过 Bash 写入事件。

---

## 3. 进度状态机

```
pending → queued → running(substeps) → completed
                       ↓ fail          ↓
                     failed ──retry──→ queued
                       ↓ cancel
                    cancelled
```

| 状态 | Entry 动作 | Exit 动作 |
|------|-----------|----------|
| `pending` | 无 | — |
| `queued` | emit `task.queued` | — |
| `running` | emit `task.started` | — |
| `running.substep_n` | emit `task.substep(in_progress)` | emit `task.substep(completed)` |
| `completed` | emit `task.completed` + `checkpoint.saved` | — |
| `failed` | emit `task.completed(error)` | — |

**编排级状态机**：phase:1 → phase:2 → HITL gate → phase:3 → ... → done

---

## 4. 展示格式

### Compact 模式（实时单行）
```
[orch-180322-12345] 📍 [■■■□□□□] Task #3 子步骤 4/7: 编写JWT签发逻辑... [+47s]
[orch-180322-12345] ✅ [■■■□□□□] Task #3 JWT中间件 完成 (293s) 进度: 3/6
[orch-180322-12345] ⏸️ [■■■■■□□] 等待审批: 请审阅测试结果后决定是否继续
[orch-180322-12345] 🎉 [■■■■■■■] 全部完成! 耗时620s, Token≈24K
```

### Detail 模式（HITL暂停或用户查询时展开）
- 任务树 + 子步骤状态（✅ ▶ ⬜）
- 事件时间线
- 阶段进度可视化

### Summary 模式（完成汇总表）
- 阶段/角色/耗时/Token 四维统计
- 检查点统计（full × N, incremental × N, delta × N）
- 错误/重试/HITL 统计

---

## 5. 与现有系统集成

### 调度循环注入点

```
while 有未完成任务:
  # 阶段1: HITL检查（不变）
  
  # 阶段2: 任务调度
  → [注入点 A] 发射 task.started 事件
  → 启动 Agent（含进度注入模板）
  → [注入点 B] 启动 Monitor 监听事件文件
  
  # 阶段3: 完成处理
  → [注入点 C] 消费新事件 → 更新展示
  → 检测 task.completed → 触发 TaskUpdate
  → [注入点 D] 心跳超时检测（>90s 无心跳）
```

### 与检查点系统共享

```
~/.claude/orchestrator/
├── checkpoints/          ← 状态快照（低频写入）
├── events/               ← 流式日志（高频追加，append-only JSONL）
├── seq_tracker/          ← 消费者游标
└── templates/
    └── progress-injection.md  ← Agent 进度注入模板
```

**关键设计**：事件与检查点解耦。事件文件独立归档、独立清理。恢复时不依赖事件文件。

### P1 向后兼容

事件消费后**同时发射 P1 格式文本行**，确保纯文本用户不受影响。事件文件不存在时退回到检查点轮询。

---

## 6. 与 LangGraph 流式架构对比

| 维度 | LangGraph | orch v2 | 差异原因 |
|------|-----------|---------|---------|
| **传输方式** | 内存 AsyncIterator | 文件轮询 JSONL | Agent 跨进程通信只能走文件系统 |
| **事件粒度** | State 字段级 | 子步骤级 | orch 没有 graph state |
| **消息完整性** | 完整推送 | 200字预览截断 | 文件系统不适合大块内容流式 |
| **检查点关联** | 自动关联 | 手动发射 | LangGraph 的 checkpoint 是引擎原语 |
| **心跳机制** | 无需要（同步执行） | 每30s心跳 | orch Agent 是"发射后不管"的后台进程 |
| **实时延迟** | <10ms | ~500ms | 文件轮询固有延迟 |
| **事件持久化** | 内存缓冲 | 持久化到 JSONL（兼审计日志） | 设计意图不同 |

### 不可复刻 LangGraph 的原因
1. **运行时架构**：LangGraph 同进程执行，orch Agent 独立子进程
2. **State 模型**：LangGraph 有显式 State 对象，orch 状态分散在多个系统中
3. **消费方差异**：LangGraph 面向开发者代码，orch 面向人类用户

---

*基于 LangGraph 流式架构分析 + Claude Code 环境约束设计*
