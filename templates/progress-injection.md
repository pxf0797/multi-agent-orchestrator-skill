# Agent 进度上报指令模板

此模板由 Coordinator 在调度 Agent 时嵌入 prompt 末尾，指示 Agent 通过 Bash 向事件文件上报进度。

**使用方式：** Coordinator 读取此文件 → 替换 `<orch-id>` 和 `<N>` 占位符 → 注入 Agent prompt 末尾。

---

## 1. 子步骤开始

每个子步骤开始时上报：

```bash
echo '{"event":"task.substep","orch_id":"<orch-id>","task_id":"<N>","data":{"step_id":"<N.M>","description":"<子步骤描述>","status":"in_progress"}}' >> ~/.claude/orchestrator/events/<orch-id>.jsonl
```

## 2. 子步骤完成

每个子步骤完成时上报（含耗时）：

```bash
echo '{"event":"task.substep","orch_id":"<orch-id>","task_id":"<N>","data":{"step_id":"<N.M>","description":"<子步骤描述>","status":"completed","elapsed_sec":<实际秒数>}}' >> ~/.claude/orchestrator/events/<orch-id>.jsonl
```

## 3. 心跳

超过 30 秒无子步骤完成时上报心跳，证明 Agent 未卡死：

```bash
echo '{"event":"task.heartbeat","orch_id":"<orch-id>","task_id":"<N>","data":{"since_start_sec":<任务启动后秒数>,"current_operation":"<当前正在执行的操作描述>"}}' >> ~/.claude/orchestrator/events/<orch-id>.jsonl
```

## 4. 中间输出预览

产生可展示的中间输出时上报（首 200 字）：

```bash
echo '{"event":"task.output_preview","orch_id":"<orch-id>","task_id":"<N>","data":{"content_type":"text|code","preview":"<首200字输出，需转义双引号>","char_count":<总字符数>}}' >> ~/.claude/orchestrator/events/<orch-id>.jsonl
```

---

## 注入提示

Coordinator 注入时，在上述模板末尾追加：

```
注意：
- 所有 echo 命令追加到 JSONL 文件，不覆盖已有内容
- 如果 JSONL 文件所在目录不存在，先 mkdir -p ~/.claude/orchestrator/events/
- 双引号需转义为 \"
- 进度上报失败不应阻塞主任务执行（静默失败）
```

## 事件类型参考

| 事件 | 发射时机 | 关键字段 |
|------|---------|---------|
| `task.substep` | 子步骤开始/完成 | step_id, description, status, elapsed_sec |
| `task.heartbeat` | 超过30秒无更新 | since_start_sec, current_operation |
| `task.output_preview` | 产生中间输出 | content_type, preview, char_count |
