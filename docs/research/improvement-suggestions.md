# Multi-Agent Orchestrator 改进建议

> 基于 [Matt Pocock Skills 深度分析研究报告](./research-report.md) 的对比分析
> 日期: 2026-07-25

## 改进建议汇总

| 优先级 | 编号 | 标题 | 借鉴来源 | 预估改动量 |
|--------|------|------|---------|-----------|
| P0 | 1 | 任务 JSON 增加完成标准（Completion Criteria） | diagnosing-bugs/code-review/tdd | 小 |
| P0 | 2 | Agent 指令中引入层次化引导词 | writing-great-skills GLOSSARY.md + tdd | 小 |
| P1 | 3 | 歧义处理改为逐问题采访模式 | grilling/SKILL.md 决策树采访协议 | 中 |
| P1 | 4 | 标准化 skill.md frontmatter 元数据 | SKILL.md frontmatter 规范 + openai.yaml | 小 |
| P1 | 5 | SOP 模板薄壳化改造 | grill-me(3行)+grilling(11行) 三层委派 | 中 |
| P2 | 6 | 建立共享词汇参考文件 | codebase-design + domain-modeling | 中 |
| P2 | 7 | 收紧"Plan, Don't Do"约束表述 | wayfinder 哲学 + Negation 陷阱原则 | 小 |
| P3 | 8 | 引入功能成熟度分桶体系 | 六桶分类 + promoted 质量门控 | 大 |

---

### P0-1: 任务 JSON 增加完成标准（Completion Criteria）

**问题现状：** skill.md Step 3 的任务 JSON 定义（约 L307-327）中，每个任务仅有 `output_format` 字段描述"输出长什么样"，但缺少"什么条件满足才算真正完成"的显式定义。这导致子 Agent 容易出现 premature completion —— 输出文件存在但内容质量不足。Coordinator 只能通过事后 Verifier 验证才能发现问题，浪费 Token 和时间（验证 + 退回修正的往返成本通常 2-3 倍于一次正确执行）。

**借鉴来源：** mattpocock/skills 的 `diagnosing-bugs` Phase 1 完成标准（4 条 checklist：red-capable、deterministic、fast、agent-runnable），`code-review` 子 Agent 的 "Under 400 words" 硬约束，以及 `tdd` 的"写测试前必须确认 seam"。writing-great-skills 将 Completion Criterion 定义为"可检查、可穷尽的完成条件"——核心特征是二元可判定（是/否），而非模糊的质量感知。

**改进方案：**
1. 在 skill.md Step 3 的 JSON 任务模板中，为每个 task 对象增加 `completion_criteria` 字段：
```json
"completion_criteria": [
  "所有引用的文件路径已验证存在",
  "输出覆盖了任务描述中的每个功能点",
  "代码通过 typecheck/lint 无报错"
]
```
2. 在 skill.md §5.3 的 Agent prompt 注入模板（约 L579-586）中，在 `[Constraints]` 段后追加 `[Completion Criteria]` 段，逐条列出完成条件。
3. 在 Verifier prompt（约 L797-813）中增加前置步骤：先逐条检查 Completion Criteria 是否满足，全部通过后再进入常规验证。若 completion criteria 未满足，直接退回不带评分（节省 Verifier 深度分析的 Token）。

**预期收益：** 子 Agent 在声称完成前有明确的自我检查清单，减少 premature completion 约 30-50%。Verifier 的退回率降低（因为 Agent 自己先过了一遍 checklist）。实现成本极低——仅修改 JSON schema 模板和 Agent prompt 注入逻辑，不涉及架构调整。

**风险：** 若 completion_criteria 写得过于宽泛（如"确保代码质量好"），则失去二元可判定的价值，形同虚设。需要遵守"每条标准必须是是/否问题"的规则。

---

### P0-2: Agent 指令中引入层次化引导词（Leading Words）

**问题现状：** skill.md §5.3 的角色模板注入格式（约 L579-586）使用 `[Role:] [Goal:] [Backstory:] [Skills:] [Constraints:] [Output Format:]` 的平铺结构。所有约束指令以列表形式呈现，Agent 对每条指令分配等权重注意力。这导致"禁止修改非目标文件"和"建议使用已有工具函数"在格式上同等重要——而实际上前者违反会破坏代码库，后者只是最佳实践。缺乏层次化的指令标记使得 Agent 无法区分"必须遵守"和"建议参考"，在上下文较长时倾向于遗漏关键约束。

**借鉴来源：** mattpocock/skills 的 writing-great-skills GLOSSARY.md 中系统定义的 Leading Words 技术体系。核心理念：利用模型预训练中已存在的概念锚定行为——如 `tight` 锚定 "2-second deterministic" 的行为期望，`red-capable` 将模糊的质量门转为可观察的二元状态，`seam` 在 tdd 中精确定义测试的切入点。效果：减少 token 消耗（一个词取代一段话）、提高行为一致性（模型对 known concept 的反应比对长指令更稳定）。

**改进方案：**
1. 在 skill.md ~L579-586 的角色模板注入格式中，为 `[Constraints]` 段引入三级引导词前缀：
   - `CRITICAL:` — 违反则任务视为失败（如"CRITICAL: 禁止修改任务范围外的任何文件"）
   - `REMEMBER:` — 关键但容易在长上下文中遗忘（如"REMEMBER: 写入文件前必须确保目录存在"）
   - `PREFER:` — 倾向性建议，不强制（如"PREFER: 复用已有工具函数而非重写"）
2. 在 `[Output Format]` 段中引入结构化标记词：
   - `FIRST:` — 输出必须以此结构开头
   - `NEXT:` — 中间段的顺序要求
   - `FINALLY:` — 输出必须以什么结束

**预期收益：** Agent 对 CRITICAL 级别指令的遵守率提升，减少因忽视关键约束导致的返工。改动量极小（仅修改 Agent prompt 模板中的文本），即可提升指令的信息层级。与 P0-1 配合使用效果更佳——Completion Criteria 回答"做完没有"，Leading Words 回答"怎么做对"。

**风险：** 引导词不宜超过 5 种，否则失去区分度（变回平铺列表）。每个角色模板最多 2-3 条 CRITICAL 约束——过多导致 Agent 忽视真正关键的指令。

---

### P1-3: 歧义处理改为逐问题采访模式

**问题现状：** skill.md §1.5 A.4 的歧义处理流程（约 L160-189）采用批量展示模式：将 $\ge 2$ 个歧义点一次性列出选项，等待用户一次性回答。这种方法存在三个问题：(1) 用户面对多个歧义点容易认知过载，可能草率选择；(2) 后续歧义点的最优选择往往依赖前面问题的答案，批量回答容易产生矛盾；(3) 格式上只是文档化的 JSON 参考（`AskUserQuestion` 接口），缺乏"引导用户理清思路"的互动设计。

**借鉴来源：** mattpocock/skills 的 `grilling/SKILL.md`（11 行原语）定义的决策树采访协议：**"Interview me relentlessly about every aspect of this until we reach a shared understanding. Walk down each branch of the decision tree, resolving dependencies between decisions one-by-one."** 核心设计原则：一问一答（"Asking multiple questions at once is bewildering"）、决策归人事实归工具（能从文件系统查到的 AI 自己查，只有决策问题才停下来问）、每次提问附带推荐答案（把认知负担留给 AI）、依赖关系决定提问顺序、确认共享理解后才行动。

**改进方案：**
1. 修改 §A.4 的歧义处理流程描述（约 L160-189），将"批量展示所有歧义点"改为"按决策依赖树逐个提问"：
   - 先梳理所有歧义点间的依赖关系（哪个问题必须先回答才能回答下一个）
   - 按依赖树深度优先逐层提问，每次只问一个问题
   - 每个问题附带推荐答案 + 选择该答案的理由
   - 用户回答后，基于该回答重新评估剩余歧义点（可能某些歧义点因本次回答而消除）
2. 保留批量模式作为"用户明确要求"时的降级选项（如用户说"把所有问题一起列出来"）。
3. 在 §B.2（研究场景歧义澄清）中同样改为逐问题采访模式。

**预期收益：** 歧义澄清的质量显著提升——用户每次只需集中精力思考一个问题，推荐答案降低了决策难度。消除批量回答中常见的矛盾（后续问题基于前面的不正确答案），减少方案阶段返工。这种交互模式是 MPS 安装 700 万次的核心用户体验创新。

**风险：** 逐问题采访增加了方案阶段的交互轮次（3 个歧义点从 1 轮变 3 轮），可能让急于推进的用户感到繁琐。需要明确告知用户交互轮次预期，并保留批量模式的降级路径。

---

### P1-4: 标准化 skill.md frontmatter 元数据

**问题现状：** skill.md 的 YAML frontmatter（L1-4）：
```yaml
name: multi-agent-orchestrator
description: Multi-Agent Orchestrator — 复杂任务的协调者。...
```
仅包含最基础的 `name` 和 `description`。缺少版本号（无法追踪用户用的是哪个版本）、成熟度声明（用户无法判断哪些功能稳定）、调用类型区分（Coordinator 什么时候自动介入缺少声明）。

**借鉴来源：** mattpocock/skills 的 SKILL.md frontmatter 规范化字段体系：`name`（kebab-case 唯一标识）、`description`（双模态：user-invoked 时是人类可读摘要，model-invoked 时含触发短语）、`disable-model-invocation: true`（标记为 user-invoked）、`argument-hint`（可选参数提示）。配合 `agents/openai.yaml` 实现跨平台元数据同步，两个平台上的行为声明必须一致。

**改进方案：**
1. 在 skill.md frontmatter 中增加以下字段：
```yaml
---
name: multi-agent-orchestrator
version: "2.4.0"            # 新增：语义化版本，与 Git tag 同步
maturity: stable            # 新增：stable | beta | experimental
invocation: auto            # 新增：auto(模型可自动触发) | manual(仅用户显式调用)
description: ...
triggers:                   # 新增：模型自动触发时的匹配关键词
  - 并行
  - 多个 agent
  - orchestrate
  - swarm
---
```
2. `maturity: stable` 表示该 skill 的核心流程（DAG 调度、检查点、四种 SOP）已稳定；`invocation: auto` 表明模型可以在检测到触发关键词时自动调用。
3. 若未来引入实验性功能（如 P3 的分桶体系），可以考虑拆分出 `multi-agent-orchestrator-experimental` 的独立 skill，标记 `maturity: experimental, invocation: manual`。

**预期收益：** 用户通过版本号可追踪更新是否生效。`invocation: auto` + `triggers` 将原来散落在 description 中的触发条件结构化，便于自动匹配。`maturity` 字段为后续 P3 的分桶体系打下基础。改动量极小（仅修改 4 行 frontmatter）。

**风险：** 需要在 release 流程中同步更新 version 字段，增加维护负担。可以待 CI/CD 体系建立后自动化，当前先手动维护。

---

### P1-5: SOP 模板薄壳化改造

**问题现状：** `references/sop-templates.md` 的 4 个 SOP 模板将"场景识别条件"（触发什么关键词匹配哪个 SOP）和"执行阶段细节"（每个阶段的具体角色、并行度、输出要求）混在同一个长文件中。Coordinator 在场景识别阶段（skill.md Step 1）只需要匹配条件，在调度执行阶段（Step 5）才需要阶段细节——但当前加载的是整个文件，token 利用率低。此外，当某个 SOP 的阶段细节需要调整时，修改会影响整个模板文件。

**借鉴来源：** mattpocock/skills 的 Thin Shell, Thick Primitive 三层委派模式。以 grilling 体系为典范：`grill-me/SKILL.md`（3 行正文，Shell）仅声明"Run a `/grilling` session"；`grilling/SKILL.md`（11 行，Primitive）定义全部行为逻辑；`grill-with-docs`（另一个 Shell）复用同一个 grilling 原语并注入不同的上下文。设计原则：可复用行为全部下沉到 model-invoked primitive；user-invoked shell 仅做薄封装（选择 primitive + 注入上下文）；Shell 可以是 3 行，这完全 OK；行为只需在一处修改（Single Source of Truth）。

**改进方案：**
1. 将 `references/sop-templates.md` 拆为两层：
   - **Shell 层（薄）**：每个 SOP 定义约 10-15 行，仅包含场景匹配条件（触发关键词）、DAG 阶段骨架（阶段名称 + 顺序）、推荐的 HITL gate 位置。此部分内联到 skill.md Step 1 的场景识别表中。
   - **Primitive 层（厚）**：每个 SOP 的详细执行指南（每阶段的角色定义、并行度、验证强度、输出格式、反模式）保留在独立文件中，如 `references/sop-code-dev-detail.md`。
2. Coordinator 在 Step 1 加载 Shell 做场景匹配；在 Step 2 确定具体 SOP 后，才加载对应 Primitive 获取执行细节。
3. Shell 与 Primitive 之间通过文件名约定关联（如 `sop-code-dev` 的详细指南在 `sop-code-dev-detail.md`），无需显式注册表。

**预期收益：** 场景识别阶段的 token 消耗减少约 60-70%（不需要加载 4 个 SOP 的完整细节）。修改单个 SOP 的阶段细节不影响其他 SOP。新增 SOP 只需创建 Shell + Primitive 两个文件，不需要修改已有模板。

**风险：** 拆分后新增了文件间的引用关系，增加了 Coordinator 的加载逻辑复杂度。需要在 skill.md 中明确定义 Shell 与 Primitive 的加载时机和方式。

---

### P2-6: 建立共享词汇参考文件

**问题现状：** orchestrator 当前没有统一的术语定义文件。skill.md 和 `references/` 下 10 个文件各自定义和使用术语。例如，"DAG 节点"在 skill.md 中称为 Task，在 dependency-dsl.md 中称为 `@task`，在 checkpoint-guide.md 中称为"任务项"——概念相同但命名不统一。Coordinator 和子 Agent 对"编排"、"frontier"（前沿任务）、"调度"、"验证"等概念可能产生理解偏差。roles 和 SOP 模板中，Architect、Developer、QA 等角色的职责边界也缺少精确锚定。

**借鉴来源：** mattpocock/skills 的词汇基础设施体系。`codebase-design`（纯 reference 技能，约 80 行）定义了 module/interface/implementation/depth/seam/adapter/leverage/locality 八个核心概念，每个概念精确锚定含义，并用 "Rejected framings" 小节显式排除错误解读（如 Depth 不是实现行数/接口行数之比）。`domain-modeling` 主动构建术语表（CONTEXT.md）、选择性记录 ADR。所有其他技能统一引用这套词汇，形成分布式但一致的概念网络。核心理念：公共语言是协作的基础，AI Agent 也不例外。

**改进方案：**
1. 新建 `references/glossary.md`，定义 orchestrator 的核心术语（约 15-20 个），每个术语包含：
   - 精确的锚定定义（一句话）
   - 与相关术语的区分（如 "Task vs Sub-task"、"HITL Gate vs Inline HITL"）
   - Rejected meanings（明确排除的误解，借鉴 codebase-design 的 "Rejected framings"）
2. 在 skill.md 顶部的参考文档表中增加 glossary.md 的链接。
3. 在角色模板（`references/role-templates.md`）中，将 `[Backstory]` 段涉及的领域术语链接到 glossary 中对应的条目。
4. 建议新增词汇（P2 后可渐进补充）：**编排（Orchestration）** vs 调度（Scheduling）、**DAG 节点（Task）** vs 子步骤（Sub-step）、**前沿（Frontier）**（借鉴 wayfinder 的 frontier 概念：open + unblocked + unclaimed 的任务）、**假设（Assumption）** vs 约束（Constraint）、**纪律（Discipline）** vs 流程（Process）——借鉴 MPS 的核心区分。

**预期收益：** 消除跨文件的概念漂移，降低 Coordinator 与子 Agent 的语义偏差。新增角色或 SOP 时有统一的词汇库可用，不需要重新解释基础概念。glossary.md 也是新人理解 orchestrator 设计的最短路径。

**风险：** 词汇定义需要精确且共识——定义不清的 glossary 比没有更危险（会固化错误理解）。建议首次仅定义 10 个最核心术语，经过 2 周实践验证后再扩展。参考 codebase-design 的 "Rejected framings" 做法，每个术语必须注明"它不是什么"。

---

### P2-7: 收紧"Plan, Don't Do"约束表述

**问题现状：** skill.md 核心约束段（L11-26）声明了 Coordinator "绝不亲自执行具体任务"，并通过 7 条以 X 开头的反面示例（不可自己读文件、不可自己改代码、不可自己执行命令等）强化禁止清单。但目前存在两个问题：(1) 缺少正向的行为引导——Coordinator 知道不能做什么，但缺少"那我应该做什么"的指导，可能导致过度谨慎（连该做的也不做）；(2) 部分禁止表述涉及负向强化（"绝不"），根据 MPS writing-great-skills 的 Negation 陷阱原则（禁止 = 强化），过多否定句反而可能强化不希望的行为。

**借鉴来源：** mattpocock/skills 的 wayfinder 中 "Plan, don't do" 哲学——"产出是决策，不是交付物"。以及 writing-great-skills GLOSSARY.md 中的 Negation 陷阱原则："When you say 'don't do X', you reinforce X in the model's attention. Instead, provide a positive alternative that makes X unnecessary." MPS 的建议是给出正向替代而非禁止。

**改进方案：**
1. 在核心约束段的 X 列表（L13-21）之后，增加"Coordinator 应该做的事"（正向引导）清单：
   ```markdown
   **正面示例 — Coordinator 应该做的事：**
   - 分析目标、识别场景类型、选择 SOP 模板
   - 生成方案（initial-plan.md），自审查后进入任务拆解
   - 将任务描述注入对应角色模板，spawn Agent
   - 读取检查点文件、事件 JSONL 的元数据（文件大小/行数/最后修改时间）
   - 汇总 Agent 完成通知中的摘要信息，生成统计表
   - 在 HITL gate 暂停时展示已完成阶段的摘要 + 下一步选择
   ```
2. 将"你绝不亲自执行具体任务"（L11）改为正向表述：
   ```markdown
   你的唯一职责：分析目标 → 拆解任务 → 调度 Agent → 汇总结果。所有具体执行工作交给子 Agent。
   ```
3. 在 §5.2 调度循环的"调度前置步骤"中，增加 Coordinator 可以做元操作的正向说明（如 mkdir 创建输出目录、cp 复制交付物、读取检查点 JSON 的 status 字段做状态决策等）。

**预期收益：** Coordinator 行为边界更清晰——知道禁止边界的同时也有正向行动清单。减少因过度谨慎导致的"什么都不敢做"（如连检查点文件是否存都不去检查）。替换否定表述为正向替代，符合 MPS 验证过的 Negation 陷阱原则。

**风险：** 正向清单可能被误解为"除此之外都不能做"，导致过度约束。需要在清单末尾注明"以上是典型示例，非穷举清单"。

---

### P3-8: 引入功能成熟度分桶体系

**问题现状：** orchestrator 当前所有功能——DAG 调度、Verifier 三种验证强度、HITL 三种模式、检查点三级持久化、流式进度事件系统、自适应 Replan、共享上下文、Trace Agent 等——在 skill.md 中平铺展示，没有成熟度标记。用户（包括人类使用者和 Coordinator 自身）无法判断哪些功能是经过充分验证的 stable、哪些是近期新增尚在磨合的 beta、哪些是设计完成但未实现的概念（如 Level 2 增量检查点）。所有功能看似同等可用，但实际上可靠性差异显著。

**借鉴来源：** mattpocock/skills 的六桶分类体系（engineering/ productivity/ misc/ personal/ in-progress/ deprecated），以成熟度梯度分层。关键设计决策：只有 promoted 桶（engineering + productivity）的技能才能进入 plugin.json 和 README——这是一种显式的质量门控机制。deprecated/ 桶有 4 个已弃用技能，in-progress/ 桶有 9 个持续迭代的草稿。这种分类向用户传递清晰的信号："这个功能是你可以依赖的，那个还在实验中"。CLAUDE.md 强制要求 promoted skill 必须有 docs 页面、plugin.json 条目、README 引用——三重质量卡口。

**改进方案：**
1. 在 skill.md 的参考文档表（约 L1061-1073）中，为每个 reference 文件增加成熟度标记：
```markdown
| 文档 | 内容 | 成熟度 |
|------|------|--------|
| quick-start.md | 快速入门 | stable |
| role-templates.md | 8种角色模板 | stable |
| sop-templates.md | 4个领域SOP | stable |
| checkpoint-guide.md | 检查点系统 | stable（Level 1）/ beta（Level 2）/ planned（Level 3） |
| debugging-meta-patterns.md | 调试元模式 | beta |
| dependency-dsl.md | DSL语法参考 | planned |
```
2. 在 `references/` 目录下建立子目录结构（可选，P3 长期）：
   ```
   references/
   ├── stable/       # 已验证稳定
   ├── beta/         # 可用但需谨慎
   └── planned/      # 设计完成，待实现
   ```
3. Coordinator 在调度时，对标记为 `beta` 的功能采用更保守的参数（如更短的超时、更多的检查点保存频率），对 `planned` 的功能默认不启用。
4. 在 skill.md frontmatter 中增加 `maturity: stable`（与 P1-3 frontmatter 标准化建议联动）。

**预期收益：** 用户对 orchestrator 的功能可靠性有清晰预期，不会因使用了 beta 功能而困惑。新增功能有了明确的灰度路径：planned（设计）-> beta（实验验证）-> stable（质量卡口）。与 MPS 的 deprecated/ 桶对应，orchestrator 也可以从容淘汰不再适合的功能（如当前标记为 planned 的 DSL 解析器若经过评估不适合，可转为 deprecated）。

**风险：** 分桶维护有一定开销，需要定期审视各功能的成熟度状态并更新标记。建议将成熟度评审纳入 release checklist。对于 skill.md 这种单文件结构，子目录可能过度设计——可以先用表格标记起步，子目录按需引入。

---

## 改进路线图

```
第 1 周 (P0)
├── P0-1: Completion Criteria — 修改 JSON schema + Agent prompt
└── P0-2: Leading Words — 修改 Agent prompt 模板

第 2-3 周 (P1)
├── P1-3: Grilling 歧义处理 — 改写 §A.4 流程
├── P1-4: Frontmatter 标准化 — 加 4 行元数据
└── P1-5: SOP 薄壳化 — 拆分 sop-templates.md

第 4-6 周 (P2)
├── P2-6: 共享词汇 — 新建 glossary.md + 链接
└── P2-7: Plan-Don't-Do 收紧 — 改写核心约束段

第 7 周+ (P3)
└── P3-8: 分桶体系 — 参考文档表加成熟度列
```

## 建议来源对照

| 编号 | 标题 | MPS 来源文件 | MPS 核心设计 |
|------|------|------------|------------|
| P0-1 | Completion Criteria | `diagnosing-bugs/SKILL.md` Phase 1 checklist + `code-review/SKILL.md` "Under 400 words" + `tdd/SKILL.md` seam requirement | 可检查、可穷尽的完成条件，二元可判定 |
| P0-2 | Leading Words | `writing-great-skills/GLOSSARY.md` + `tdd/SKILL.md` | 利用模型预训练概念锚定行为，单 token 触发行为模式 |
| P1-3 | Grilling 歧义处理 | `grilling/SKILL.md`（11行原语） | 决策树逐分支采访，一问一答，推荐答案 |
| P1-4 | Frontmatter 标准化 | `SKILL.md` frontmatter + `openai.yaml` + `.agents/invocation.md` | 双模态 description，disable-model-invocation |
| P1-5 | SOP 薄壳化 | `grill-me/SKILL.md`(3行) + `grilling/SKILL.md`(11行) 三层委派 | Thin Shell + Thick Primitive，SSOT |
| P2-6 | 共享词汇 | `codebase-design/SKILL.md`(8核心概念) + `domain-modeling/SKILL.md` | 词汇基础设施，Rejected framings |
| P2-7 | Plan-Don't-Do | `wayfinder/SKILL.md` + `writing-great-skills/GLOSSARY.md` | Plan, don't do; Negation 陷阱 |
| P3-8 | 分桶体系 | 六桶目录 + `CLAUDE.md` bucket rules | 成熟度门控，promoted 三重质量卡口 |

---

## 不适合借鉴的设计（明确排除）

以下 mattpocock/skills 的设计**不适合**当前 orchestrator，原因已在研究报告中分析，此处仅作记录便于后续讨论：

| 设计 | 不借鉴原因 |
|------|-----------|
| 完全去中心化（无编排引擎） | MAO 的核心价值是自动编排 10+ 并行任务——去中心化无法处理复杂依赖和错误恢复 |
| 无状态管理 | MAO 需要跨 session 断点续传，这是硬需求 |
| 无显式角色系统 | MAO 需要异构 Agent（不同模型、工具集、约束） |
| 无错误分级和恢复 | MAO 的 10 Agent 并行场景需要 E1/E2/E3 系统 |
| 完全人工触发 Pipeline | MAO 用户期望"输入目标，自动编排" |
