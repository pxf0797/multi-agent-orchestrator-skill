# 人机协作（HITL）工作流参考

Coordinator 在关键决策点暂停自动化流程，引入人类判断。借鉴 LangGraph 的 `interrupt()` 和 CrewAI 的 `human_input` 机制。

## 三种 HITL 模式

### 1. Approval Gate（审批门）

**触发时机**: DAG 关键阶段完成后（如架构设计完成、集成测试通过）
**行为**: 暂停→展示阶段结果→等待用户 approve/reject

```json
{
  "gate_id": "design-review",
  "after_task": "3",
  "mode": "approval",
  "question": "架构设计方案已完成，请审阅。确认后可继续开发？",
  "timeout": 3600,
  "default_action": "pause",
  "options": ["确认，继续开发", "需要修改后重试", "暂停任务"]
}
```

**Coordinator 执行流程**:
```
1. 检测 gate.after_task 状态变为 completed
2. 发射 orchestrator.phase 事件（phase: "HITL: design-review"）
3. 展示已完成阶段摘要（含关键产物和指标）
4. 呈现 gate.question + gate.options
5. 等待用户选择:
   ├── "确认继续" → gate.status=approved → 继续调度
   ├── "需要修改" → gate.status=rejected → 标记受影响任务 pending
   └── "暂停" → gate.status=pending → 保持状态，等待后续恢复
6. 更新检查点中的 gate 记录
```

### 2. Human Input（人工输入）

**触发时机**: 任务执行前需要人工补充信息
**行为**: 暂停→提问→等待用户输入→注入后续 Agent prompt

```json
{
  "gate_id": "scope-clarify",
  "after_task": "1",
  "mode": "input",
  "question": "请明确本次开发的范围：需要支持哪些数据库？预期的用户规模？",
  "timeout": 1800,
  "default_action": "pause"
}
```

**注入方式**:
下游 Agent prompt 中自动追加 `[Human Input]` 段：
```
[Human Input]
用户补充信息: <用户的自由文本回复>
请根据以上信息调整你的输出。
```

### 3. Review-then-Continue（审阅后继续）

**触发时机**: 阶段性成果产出后（如报告初稿、实现方案）
**行为**: 暂停→展示初稿→用户审阅→继续或调整方向

```json
{
  "gate_id": "report-review",
  "after_task": "9",
  "mode": "review",
  "question": "研究报告初稿已完成（见上方摘要）。请审阅后选择后续方向。",
  "timeout": 3600,
  "default_action": "pause",
  "options": ["方向正确，继续生成最终报告", "需要补充XX维度", "调整侧重点"]
}
```

## HITL Gate 配置完整字段

| 字段 | 必需 | 类型 | 说明 |
|------|------|------|------|
| `gate_id` | yes | string | 唯一标识符 |
| `after_task` | yes | string | 触发该 gate 的任务逻辑 ID |
| `mode` | yes | string | `approval` / `input` / `review` |
| `question` | yes | string | 展示给用户的问题 |
| `timeout` | no | int | 等待超时秒数（默认 3600） |
| `default_action` | no | string | 超时后行为：`pause`（默认）/ `approve` / `skip` |
| `options` | no | list | approval/review 模式的选项列表 |
| `status` | auto | string | `pending` → `approved` / `rejected` |
| `user_response` | auto | string | 用户的选择或自由文本输入 |

## 各 SOP 的 HITL 集成点

### 软件开发 SOP

```
需求分析(Architect) → [HITL: 方案审批]
  → 并行模块开发 → 并行验证
  → 集成测试 → [HITL: 测试报告审批]
  → Code Review
```

### 研究报告 SOP

```
课题拆解 → [HITL: 研究方向确认]
  → 并行搜索 → 验证
  → 并行写作 → 验证
  → 报告合成 → [HITL: 报告审阅]
  → 最终交付
```

### 部署验证 SOP

```
环境检查 → 并行功能验证 → 性能测试
  → [HITL: 上线决策] ← 最关键的门禁
```

## HITL 与检查点的集成

HITL gate 状态保存在检查点文件的 `hitl_gates` 数组中。中断恢复时：

```bash
# 恢复时检测: 是否有未响应的 HITL gate
python3 -c "
import json
with open('checkpoint.json') as f:
    ck = json.load(f)
pending = [g for g in ck.get('hitl_gates', []) if g['status'] == 'pending']
for g in pending:
    print(f\"⏸️  HITL Gate '{g['gate_id']}': {g['question']}\")
    print(f\"   等待用户响应...\")
"
```

如果 session 在等待 HITL 响应时中断，恢复后 Coordinator 重新展示未响应的 gate。

## HITL 最佳实践

1. **关键决策点才设 gate** — 每个 gate 打断自动化流程，过多会降低效率。通常每个 SOP 1-2 个 gate
2. **超时要有合理默认值** — 用户可能离开，设置合理的 timeout 和 default_action
3. **gate 前产出要完整** — 用户在审批时需要看到完整的上下文（摘要、关键指标、可选方案）
4. **选项要具体可操作** — "确认继续" / "需要修改：XXX" 比 "yes/no" 更有用
5. **审批记录要保存** — user_response 写入检查点，便于追溯决策历史

## HITL 进度报告格式

```
HITL 触发: "[orch-<id>] ⏸️ 等待审批: <gate.question>"
HITL 通过: "[orch-<id>] ✅ Gate '<gate_id>' 审批通过 → 继续执行"
HITL 拒绝: "[orch-<id>] 🔙 Gate '<gate_id>' 被拒绝 → 暂停下游任务"
HITL 超时: "[orch-<id>] ⏰ Gate '<gate_id>' 超时 → 执行 default_action: <action>"
```
