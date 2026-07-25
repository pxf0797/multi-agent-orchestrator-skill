# 共享词汇表（Glossary）

定义 Multi-Agent Orchestrator 的核心术语，消除跨文件的概念漂移。Coordinator 和子 Agent 使用统一的术语理解编排过程。

> **使用约定：** skill.md 和 `references/` 下所有文件统一引用本词汇表。角色模板的 `[Backstory]` 段涉及领域术语时链接到对应条目。首次定义 11 个核心术语，经 2 周实践验证后扩展。

---

## 1. Orchestration（编排）

- **定义：** Coordinator 接收高层目标 → 分析 → 拆解为子任务 → 生成 DAG → 并行调度 Agent → 汇总结果的完整过程
- **与 Scheduling（调度）的区别：** 编排包含"分析+拆解+决策"（战略层），调度仅指"按 DAG 执行+监控+恢复"（执行层）。Coordinator 同时做编排和调度
- **Rejected meaning:** 编排不是工作流引擎（workflow engine）——编排是 AI 驱动的自适应过程，工作流是预定义的固定步骤

## 2. Task（DAG 节点）

- **定义：** DAG 中的一个独立工作单元，派发给单个 Agent 执行。每个 Task 有单一职责、明确输出物、可独立验证完成与否
- **与 Sub-step（子步骤）的区别：** Task 是 DAG 的节点（跨 Agent），Sub-step 是 Task 内部的步骤（同一 Agent 内）。检查点可在两个粒度保存
- **Rejected meaning:** Task 不是 Agent 本身——一个 Agent 实例执行一个 Task，但同一个角色模板可被多个 Task 复用

## 3. Frontier（前沿）

- **定义：** DAG 中所有"就绪但尚未分配"的任务集合。判定条件：status=pending + blockedBy 全部 completed + 未被任何 Agent 认领
- **用途：** Coordinator 调度循环每次迭代从 Frontier 中取任务分配
- **Rejected meaning:** Frontier 不是"高优先级任务"——它只是可执行性判定，与 criticality（关键度）无关

## 4. Assumption（假设）vs Constraint（约束）

- **假设：** 方案设计中依赖的、未经运行时验证的前提条件（如"所有数据源的时区一致"）。置信度标注：高/中/低。运行时若被打破 → Bug
- **约束：** 方案设计中明确施加的限制条件（如"不使用外部 API"、"最大并行度 10"）。约束是设计意图，不是外部条件
- **Rejected meaning:** 假设不是"我不确定的事"——不确定的事应标记为 `[待确认]` 并触发 HITL 澄清，而非写进假设清单

## 5. SOP Template（SOP 模板）

- **定义：** 领域最佳实践的固化流程描述。分为两层：
  - **Shell（薄）：** 场景匹配条件 + 阶段骨架 + 并行度 + HITL 位置（skill.md Step 1 表格，~100 Token 总量）
  - **Primitive（厚）：** 完整阶段指南 — 角色定义、验证强度、输出格式、反模式（`references/sop-templates.md`，按需加载）
- **Rejected meaning:** SOP 不是 DAG——SOP 定义"这个领域通常怎么做"（骨架），DAG 是"这次具体怎么做"（填充了参数的实例）

## 6. HITL Gate（人机协作关卡）

- **定义：** DAG 执行中的暂停点，在关键决策节点引入人类判断。三种模式：approval（审批）、input（信息输入）、review（方向审阅）
- **与 Inline HITL 的区别：** HITL Gate 注册在检查点系统中，通过调度循环阶段1处理；Inline HITL 是 Coordinator 直接与用户交互（如歧义澄清），不经过检查点系统，用于检查点创建之前的早期阶段
- **Rejected meaning:** HITL Gate 不是阻塞——暂停期间其他不依赖此 gate 的并行任务继续执行

## 7. Checkpoint（检查点）

- **定义：** DAG 执行状态的持久化快照，支持中断恢复。三种持久化模式：
  - **Full（任务级）：** 每个 Task 完成后保存完整 DAG 状态（stable）
  - **Incremental（子步骤级）：** Task 内每个 sub-step 完成后保存增量数据（beta）
  - **Delta（变更级）：** 任何状态变更时保存字段 diff（planned）
- **Rejected meaning:** 检查点不是日志——日志是时序事件流（events/*.jsonl），检查点是状态快照（checkpoints/*.json）

## 8. Verification Strength（验证强度）

- **定义：** Guard-Verify 质检门禁系统中 Verifier 的审查深度分级：
  - **Light：** Schema 校验 — 格式完整性、必填字段、输出结构。低风险任务
  - **Standard：** Schema + LLM 评判 — 正确性、完整性、需求覆盖。常规任务
  - **Strict：** Schema + 对抗性验证 — 3 个独立 Verifier 投票。高风险任务
- **Rejected meaning:** 验证强度不是"Verifier 模型的规模"——Light 也可以用大模型跑，关键是检查的维度和投票机制

## 9. Coordinator（编排者）

- **定义：** 多 Agent 系统中的唯一中枢。职责边界：分析目标 → 拆解任务 → 调度 Agent → 汇总结果。**不亲自执行**任何文件读写/代码修改/网络搜索等具体操作
- **允许的元操作：** mkdir/cp/echo/cat(元数据) 等编排基础设施操作；读取检查点的 status/updated_at 字段；读取事件 JSONL 的文件大小/行数
- **Rejected meaning:** Coordinator 不是"老板 Agent"——它不审查代码、不设计架构、不写报告。这些是子 Agent 的工作

## 10. DAG（有向无环图）

- **定义：** 任务的依赖关系图。节点 = Task，边 = blockedBy 关系（上游完成才触发下游）。**有向**（依赖方向不可逆）、**无环**（不能出现循环依赖）
- **动态 DAG：** DAG 不是静态蓝图——运行时可通过 Replan（Split/Merge/Append）动态调整结构
- **Rejected meaning:** DAG 不是"项目甘特图"——甘特图是时间线视图，DAG 是依赖关系视图。一个 DAG 可以有多种时间线（取决于并行度）

## 11. Replan（动态重规划）

- **定义：** 运行时根据实际输出质量调整 DAG 结构。四种操作：Split（拆大任务）、Merge（合并重叠任务）、Append（追加遗漏任务）、Replan（E3 触发，整体重新设计）
- **触发时机：** 每个 SOP 阶段完成后 / E3 级错误 / 用户通过 HITL 请求
- **Rejected meaning:** Replan 不是"从头开始"——Split/Merge/Append 是非阻塞增量调整，只有 E3 触发的 Replan 才暂停等用户确认

---

## 术语关系速查

| 术语 A | 关系 | 术语 B | 说明 |
|--------|------|--------|------|
| Orchestration | 包含 | Scheduling | 编排是战略+执行，调度是执行 |
| Task | 包含 | Sub-step | 一个 Task 有 N 个 Sub-step |
| SOP (Shell) | 实例化为 | SOP (Primitive) → DAG | Shell 选模板，Primitive 填充细节，DAG 是执行实例 |
| Checkpoint (Full) | 粗于 | Checkpoint (Incremental) | Full 存 Task 级，Incremental 存 Sub-step 级 |
| HITL Gate | 不同于 | Inline HITL | Gate 走检查点系统，Inline 是 Coordinator 直接交互 |
| Assumption | vs | Constraint | 假设是外部条件（可能被打破），约束是设计意图 |
| Frontier | 来源 | DAG | Frontier = DAG 中就绪但未分配的任务 |
| Replan (Split/Merge/Append) | 不阻塞 | DAG 执行 | 非阻塞增量调整 |
| Replan (E3触发) | 阻塞 | DAG 执行 | 暂停等用户确认 |
