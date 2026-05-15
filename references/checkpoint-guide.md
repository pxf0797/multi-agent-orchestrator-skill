# 检查点系统指南

## 目录结构

```
~/.claude/orchestrator/
├── checkpoints/
│   ├── orch-YYYYMMDD-NNN.json    ← 当前活跃的编排任务
│   └── archive/
│       └── orch-YYYYMMDD-NNN.json ← 已完成/已放弃的归档
├── output/                         ← Agent 输出文件
│   ├── search-<dimension>.md
│   ├── write-<dimension>.md
│   └── integration-summary.txt
├── teams_disabled                  ← Teams 功能禁用标记
└── history.log                     ← 操作日志
```

## 检查点文件格式

```json
{
  "orchestrator_id": "orch-20260515-001",
  "created_at": "2026-05-15T18:00:00+08:00",
  "updated_at": "2026-05-15T18:30:00+08:00",
  "status": "in_progress",
  "scenario": "code_dev",
  "goal": "实现用户认证系统",
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
      "started_at": "2026-05-15T18:01:00+08:00",
      "completed_at": "2026-05-15T18:08:00+08:00"
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

2. 发现 `status: "in_progress"` 的检查点 → 提示用户：
   ```
   检测到未完成任务：
     目标：实现用户认证系统
     场景：代码开发
     进度：3/6 已完成
     上次更新：2026-05-15 18:30
   
   是否恢复？ [恢复] [放弃并归档] [忽略]
   ```

3. 恢复：读取已完成任务的输出 → 继续执行未完成任务

4. 归档：移动检查点到 `archive/`，标记 `status: "archived"`

## 清理策略

- **自动归档**：`status: "completed"` 超过 7 天的检查点移动到 `archive/`
- **输出清理**：`archive/` 中的检查点关联的 output 文件保留 30 天后删除
- **手动清理**：`/orchestrate clean` 删除所有已完成检查点

## 错误处理

| 错误类型 | 处理 |
|---|---|
| Agent 超时 (>600s) | 标记 `failed`，自动重试 1 次，仍失败则跳过 |
| Agent 返回错误 | 记录错误信息到检查点，重试 1 次 |
| 检查点写入失败 | 重试 3 次，仍失败则输出警告继续 |
| Teams 创建失败 | 创建 `teams_disabled`，回退到直调模式 |
| 全部 Agent 失败 | 标记 `status: "failed"`，输出诊断信息 |
