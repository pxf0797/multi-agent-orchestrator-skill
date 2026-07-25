# Matt Pocock Skills 深度分析研究报告

## 1. 概述

### 仓库基本信息

| 维度 | 详情 |
|------|------|
| **仓库地址** | https://github.com/mattpocock/skills |
| **作者** | Matt Pocock（TypeScript 教育家，Total TypeScript 创始人） |
| **许可证** | MIT |
| **技能总数** | 41 个（22 个 promoted，19 个非推广） |
| **技术栈** | Markdown (SKILL.md) + YAML (openai.yaml) + JSON (plugin.json) |
| **分发方式** | skills.sh 文件拷贝 + Claude Code Plugin 只读订阅 + Symlink 开发模式 |
| **npm 包** | `mattpocock-skills` v1.1.0（private） |
| **Plugin 版本** | v1.2.0（⚠️ 与 package.json 不同步） |

### 研究方法和材料来源

本报告基于 4 个研究子任务的产出：T1 仓库结构分析、T2 设计模式深度分析、T3 Multi-Agent Orchestrator 设计基线提取、T3b YouTube 视频分析（Gary Chen 对 grill-me 的走读）。此外引用了 Matt Pocock 本人博客文章、dev.to 社区分析、中文技术社区深度解读等第三方材料。所有结论均以仓库实际代码和文档为第一手证据。

### 一句话核心结论

**Matt Pocock 的 skills 系统用一套极简的、词汇驱动的"纪律文件"替代了复杂的编排引擎，证明可预测的 Agent 行为不来自更多流程控制，而来自更精准的概念锚定和更严格的信息层级设计。**

---

## 2. 仓库结构与组织

### 2.1 六桶（Bucket）分类体系

仓库按**成熟度梯度**将 41 个技能划分为 6 个桶，每个桶有独立的设计契约：

| Bucket | 数量 | 进入 Plugin | 有 docs 页面 | 定位 |
|--------|------|:-----------:|:-----------:|------|
| `engineering/` | 17 | 是 | 是 | 日常编码工作流，promoted |
| `productivity/` | 5 | 是 | 是 | 非编码工作流，promoted |
| `misc/` | 4 | 否 | 否 | 偶尔有用但不够可靠 |
| `personal/` | 2 | 否 | 否 | 仅适合作者个人设置 |
| `in-progress/` | 9 | 否 | 否 | 草稿，持续开发中 |
| `deprecated/` | 4 | 否 | 否 | 已弃用 |

这种分桶不是随意分类，而是**质量门控机制**——只有通过"可靠、可推广"检验的技能才进入 promoted 桶并出现在 plugin.json 和 README 中。CLAUDE.md 明确规定："engineering/ 和 productivity/ 中的每个 skill 必须在顶层 README 中有引用、在 plugin.json 中有条目、在 docs/ 中有对应文档页"。

### 2.2 技能打包格式：SKILL.md + openai.yaml 双平台结构

每个技能是一个目录，最小结构为：

```
skills/<bucket>/<skill-name>/
├── SKILL.md          # 核心技能定义（必需，YAML frontmatter + Markdown 正文）
├── agents/           # Agent 平台特定配置（必需）
│   └── openai.yaml   # OpenAI/Codex 界面元数据
└── [可选支持文件]     # 如 tdd 的 mocking.md、tests.md
```

**SKILL.md frontmatter 核心字段：**
- `name`: 技能唯一标识（kebab-case，等于目录名）
- `description`: 双模态 —— user-invoked 时是人类可读摘要；model-invoked 时包含触发短语（如 "Use when the user wants to..."）
- `disable-model-invocation: true`: 标记为 user-invoked，Agent 不可自动调用
- `argument-hint`: 可选，极少数技能提供参数提示

**agents/openai.yaml** 为 Codex 平台提供等同元数据。关键同步规则：`disable-model-invocation: true` 必须与 `policy.allow_implicit_invocation: false` 同时出现。一个技能在两个平台要么都是 user-invoked，要么都是 model-invoked，杜绝跨平台行为不一致。

值得注意的是，frontmatter 中**没有工具权限声明**——技能依赖 implicit trust 模型，与 Claude Code Skill 规范的设计选择不同。

### 2.3 分发渠道与版本管理

三种分发渠道并存，面向不同用户场景：

| 渠道 | 命令 | 特点 |
|------|------|------|
| skills.sh 文件拷贝 | `npx skills@latest add mattpocock/skills` | 可编辑、用户拥有代码所有权 |
| Claude Code Plugin | `/plugin marketplace add mattpocock/skills` | 只读、自动更新、托管 bundle |
| Symlink 开发模式 | `scripts/link-skills.sh` | 开发用，`git pull` 即可更新 |

plugin.json 的 `skills` 数组显式列出每个 promoted 技能的完整路径，以此绕过了 Codex plugin manifest 只支持单一路径的局限（见 ADR-0002）。

### 2.4 文档三层架构

仓库设计了三层文档，各有明确受众：

```
SKILL.md（AI Agent 读）→ docs/*.md（人读，发布到 aihero.dev）→ README.md（入口索引）
```

CLAUDE.md 强制要求 promoted skill 必须在 `docs/<bucket>/<skill-name>.md` 有人读文档页，形成"每个 skill 三种表达"的完整覆盖。`.agents/writing-docs.md` 提供了文档页的编写模板和规范。

---

## 3. 技能设计模式深度剖析

### 3.1 核心结构模式

每个 SKILL.md 遵循统一范式：YAML frontmatter 声明元数据 → Markdown 正文定义行为。正文结构因技能类型而异：

- **简单型（user-invoked shell）**：极简正文，仅委派调用。如 `grill-me/SKILL.md` 正文仅 3 行（"Run a `/grilling` session."）
- **复杂型（model-invoked primitive）**：包含深度指导、步骤定义、anti-patterns、completion criteria。如 `tdd/SKILL.md` 约 100 行，包含 seam 定义、三种反模式、红-绿-重构循环规则

目录名 = skill 名称（kebab-case）。`link-skills.sh` 通过 `find -name SKILL.md` 自动发现所有技能，无需显式注册表。

### 3.2 调用模型：User-invoked vs Model-invoked 双层触发

这是仓库最核心的架构决策。两类技能有明确的职责边界：

| 特性 | User-invoked | Model-invoked |
|------|-------------|---------------|
| **谁可调用** | 仅人类（斜杠命令） | 人类或 AI 自动触发 |
| **SKILL.md 标记** | `disable-model-invocation: true` | 无此字段 |
| **openai.yaml 标记** | `policy.allow_implicit_invocation: false` | 无此 policy 块 |
| **典型角色** | 编排者（启动流程，委托给 model-invoked） | 执行者（提供可复用的工作流纪律） |
| **description 语义** | 人类可读摘要 | 含触发短语，用于自动调用匹配 |
| **示例** | `/grill-me`, `/wayfinder`, `/implement` | `/tdd`, `/code-review`, `/diagnosing-bugs` |

关键约束：User-invoked 技能可以调用 Model-invoked 技能，但绝不能调用另一个 User-invoked 技能——这防止了不可控的 Agent 调用链。

### 3.3 Thin Shell, Thick Primitive 分层委派模式

这是全仓库最精妙的设计模式，以 grilling 三层体系为典范：

```
grilling (model-invoked)         ← 通用 grilling 原语（11 行，定义全部行为）
    ↑ 调用                   ↑ 调用
grill-me (user-invoked)     grill-with-docs (user-invoked)
（3 行正文）                  （同样简洁，额外注入 domain-modeling）
```

**设计原则：**
- 可复用行为全部下沉到 model-invoked primitive
- User-invoked shell 仅做薄封装：选择 primitive + 注入上下文
- Shell 的 SKILL.md 可以是 3 行，这完全 OK
- 技能间调用通过 `/skill-name` 语法，不通过文件路径
- 行为只需在一处修改（SSOT），消除跨技能重复

同样的模式出现在 `implement → /tdd + /code-review`、`improve-codebase-architecture → /codebase-design + /grilling + /domain-modeling` 等多处。这不是偶然的代码复用，而是刻意的架构选择：**薄壳负责"何时"和"什么上下文"，厚原语负责"如何"**。

### 3.4 Leading Words 技术体系

这可能是仓库中最有价值的创新。核心思路：利用模型预训练中已存在的概念（tight、red、fog of war、tracer bullet、deep module、seam），用单个词锚定大段行为。

**效果：**
- **减少 token 消耗**：一个词取代一段话
- **提高行为一致性**：模型对 known concept 的反应比对新定义指令更稳定
- **触发精准**：写作中的 leading word 自动激活对应技能

**典型例子：**
- `tight feedback loop` ——用 tight 锚定 "2-second deterministic" 的行为期许（`diagnosing-bugs` Phase 1）
- `red-capable` ——将模糊的质量门转为可观察的二元状态
- `tracer bullet` ——在 `to-tickets` 中用一个词定义整个垂直切片哲学
- `seam` ——在 `tdd` 中作为"测试应该写在哪里"的核心概念锚点

writing-great-skills 的 GLOSSARY.md 系统性地定义了这套词汇体系，形成"词汇即基础设施"——其他所有技能都在这套共同词汇上构建。

### 3.5 Grilling 采访模式：决策树驱动的需求澄清

grilling 引擎（`skills/productivity/grilling/SKILL.md`，11 行）定义了全仓库最关键的交互协议：

> "Interview me relentlessly about every aspect of this until we reach a shared understanding. Walk down each branch of the decision tree, resolving dependencies between decisions one-by-one."

核心设计选择：
- **一问一答**（禁止批量问题："Asking multiple questions at once is bewildering"）
- **决策归人，事实归工具**：能从文件系统查到的事实 AI 自己查，只有决策问题才停下来问
- **逐分支遍历决策树**：依赖关系决定提问顺序
- **确认共享理解后才行动**："Do not act on it until I confirm we have reached a shared understanding"

这不是"审问"，而是**采访**——每次提问附带推荐答案，把决策权留在人手里，把认知负担留给 AI。

### 3.6 Wayfinder 的 Fog of War 编排

Wayfinder（约 350 行，最长单文件技能）是最接近 orchestration 的机制，但其哲学与 DAG 编排截然不同：

**核心概念：**
- **Map（地图）**：一个 label 为 `wayfinder:map` 的 GitHub Issue，是活的规格制品
- **Decision Tickets**：子 Issue，每张是"一个决策问题 + 一个 100K token session"
- **Ticket 类型**：research（AFK）、prototype（HITL）、grilling（HITL）、task（HITL/AFK）
- **Fog of War**：地图故意不完整——不提前 chart 看不清的东西；"Not yet specified" 区域存放雾中待解问题
- **Frontier**：open + unblocked + unclaimed 的 ticket 是"当前可拿"
- **Claim 机制**：assign-to-self 作为并发锁
- **每个 session 仅解决一个 ticket**（research 除外）

**与 DAG 编排的关键差异：** Wayfinder 是人驱动的逐步探索，不是机器的静态规划。地图从开始就是不完整的（有意为之），通过逐个解决 ticket 来消除迷雾。"Plan, don't do"——产出是决策，不是交付物。

### 3.7 Completion Criterion 质量保证机制

多个技能使用显式的完成标准（checklist）防止 Agent 的"premature completion"——声称完成但实际未完成：

| 技能 | 完成标准 | 目的 |
|------|---------|------|
| `diagnosing-bugs` Phase 1 | 4 条 checklist：red-capable、deterministic、fast、agent-runnable | 确保反馈循环真正可运行后再进入假设阶段 |
| `code-review` 子 Agent | "Under 400 words" | 防止冗长，强制提炼核心发现 |
| `tdd` | 写测试前必须确认 seam | 防止实现耦合的测试 |
| `implement` | 先 typecheck → 单测试文件 → 最后全量测试 | 渐进式验证，快速失败 |

writing-great-skills 将 Completion Criterion 列为技能设计的核心概念之一，定义为"可检查、可穷尽的完成条件"。这是对抗 Agent 过早宣布完成的制度性保障。

### 3.8 Shell Pattern 极致简约

`grill-me/SKILL.md` 正文仅 3 行：

```markdown
Run a `/grilling` session.
```

但这 3 行通过调用 `/grilling` 获得了 11 行原语定义的完整行为。这种设计模式：
- 极致 DRY：行为只因一处修改而变化
- Shell 注入不同上下文产生不同变体（grill-me = 纯问询，grill-with-docs = 问询 + 写文件）
- 如果 3 行就够了，绝不写 30 行

### 3.9 元技能 self-referential 设计

`writing-great-skills` 是仓库的 self-referential 文档——它定义了技能本身的编写原则，并用这些原则编写自己。其 GLOSSARY.md 定义了 Predictability、Leading Words、Completion Criterion、Progressive Disclosure、No-op Test 等核心概念，本身就是 progressive disclosure 的示范。这种"用规则写规则"的元循环设计，确保了整个技能体系的内在一贯性。

---

## 4. 核心设计哲学

从上述模式中提炼出 6 条底层原则：

### 原则 1：Predictability 是根价值

**证据：** writing-great-skills 将 Predictability 列为技能设计的首要价值——"Agent 每次跑相同的**过程**（而非输出）"。所有设计决策都回归于此：Leading words 利用预训练知识锚定行为（比长指令更可靠），Completion criteria 提供可验证的检查点，Anti-patterns 通过负向示例划定行为边界。技能被设计为**纪律（discipline）**而非**脚本（script）**。

### 原则 2：User-Invoked = Orchestrator, Model-Invoked = Primitive

**证据：** 全仓库 22 个 promoted 技能严格执行此二分法。User-invoked 技能（9 个 engineering + 4 个 productivity）都标注 `disable-model-invocation: true`，全部是流程编排者；Model-invoked 技能（9 个 engineering + 1 个 productivity）无此标记，全部是可复用原语。调用方向严格单向：User-invoked → Model-invoked，绝不反向。`.agents/invocation.md` 是这层设计的权威解释文档。

### 原则 3：信息层级是第一杠杆

**证据：** writing-great-skills 定义了三级信息层级：in-skill step（始终可见）→ in-skill reference（延迟加载）→ external reference（通过上下文指针访问）。判断标准：inline 所有 branch 都需要的，push 只有某些 branch 需要的。TDD 技能是典范——核心循环在 SKILL.md，测试编写细节在 tests.md 和 mocking.md，通过 "See [tests.md](tests.md)" 等上下文指针决定 Agent 何时加载。

### 原则 4：Skill 是消耗品，不为一次性任务建永久结构

**证据：** Matt Pocock 明确表态"Skill 是消耗品，用完就扔"。仓库的 deprecated/ 桶有 4 个已弃用技能（design-an-interface、qa、request-refactor-plan、ubiquitous-language），in-progress/ 桶有 9 个草稿持续迭代。grill-me（2014 年创建）已演进到 grill-with-docs + domain-modeling 的三层体系。这体现了"问题变了，工具就该换"的实用主义。

### 原则 5：词汇基础设施先于流程

**证据：** 仓库建立了两个"词汇层"技能——`codebase-design`（纯 reference，定义 module/interface/depth/seam/adapter/leverage/locality 八个核心概念）和 `domain-modeling`（主动建模纪律）。其他技能统一使用这套词汇，形成分布式但一致的概念网络。codebase-design 用 "Rejected framings" 小节显式排除错误解读（如 Depth 不是实现行数/接口行数之比）。writing-great-skills 的 GLOSSARY.md 系统性地定义了元词汇。这印证了一个核心理念：**公共语言是协作的基础，AI Agent 也不例外**。

### 原则 6：小切口，深解决

**证据：** grill-me 解决的是"人对齐"——Agent 开发中最大的元问题之一。grill-with-docs 增加了"人与代码库对齐"。diagnosing-bugs 解决的是"bug 修复中的认知纪律"。每个技能瞄准一个明确、高频的痛点，用最少的代码实现最深的约束。这与"大而全的 workflow 引擎"形成对比——后者试图用一个系统解决所有问题，前者用一组独立、可组合的微型解决方案覆盖各自的问题域。

---

## 5. 与 Multi-Agent Orchestrator 的对比分析

以下将 Matt Pocock Skills 系统（以下简称 MPS）与 Multi-Agent Orchestrator（以下简称 MAO）进行逐维度对比。

### 5.1 架构模式对比

| 维度 | MPS | MAO |
|------|-----|-----|
| **架构形态** | 去中心化，技能通过名称约定（`/name`）松散耦合 | 中心化 Coordinator，DAG 驱动的严格调度 |
| **编排触发** | 人类按顺序手动调用技能（`/grill → /to-spec → /to-tickets → /implement`） | Coordinator 自动拆解+调度，人类仅在 HITL gate 介入 |
| **依赖管理** | Pipeline 式：前一个技能的**输出**自然成为后一个的**输入**，无显式依赖图 | DAG 式：`blockedBy` 数组 + `@depends_on` DSL 声明显式依赖 |
| **"编排引擎"** | 不存在。Wayfinder 是最接近的，但它产出的是决策地图而非执行计划 | 全功能编排引擎：DAG 生成、并行调度、Replan 自适应 |
| **哲学差异** | **"轻编排，重纪律"**——通过技能定义的纪律（非流程控制）保证质量 | **"重编排，轻纪律"**——通过调度机制保证质量，执行细节由子 Agent 自行决定 |

### 5.2 任务拆解对比

| 维度 | MPS | MAO |
|------|-----|-----|
| **拆解发生时机** | 设计时（技能作者预先设计好 Pipeline 步骤） | 运行时（Coordinator 动态分析任务，生成 DAG） |
| **拆解粒度** | 粗粒度：一个 skill = 一个人工触发阶段（grill → spec → tickets → implement） | 细粒度：2-10 个原子子任务，单一职责 |
| **粒度控制** | 靠技能边界自然约束。每个 skill 做一件事，但"一件事"的定义较宽（如 implement 覆盖整个实现流程） | 通过 SOP 模板 + 动态分析控制。有明确的 criticality 分级 |
| **前置方案** | 无系统化前置方案阶段。grilling（对齐）充当了"方案前澄清"，但不产出 formal spec | 代码开发场景强制自审查（`initial-plan.md` + 假设清单），研究场景有轻量简报 |
| **自适应调整** | 不存在。Pipeline 是线性的，分支由人决策（wayfinder 的决策 ticket） | Replan Check 机制：Split/Merge/Append/Replan，动态调整 DAG |

### 5.3 子 Agent 调度对比

| 维度 | MPS | MAO |
|------|-----|-----|
| **并行策略** | 极少并行。code-review 的 Standards + Spec 双轴审查是少数并行案例 | 核心能力：无依赖 = 并行，有依赖 = blockedBy 串行。最大并行度 10 |
| **Agent 间通信** | 无直接通信。通过共享制品（spec、ADR、ticket）间接协调 | `shared.jsonl` 文件 + 启动时检查机制。默认不直接通信 |
| **子 Agent 类型** | 仅 `general-purpose` 一种（code-review 用并行 general-purpose agent） | 8 个预置角色（Architect/Developer/QA/Researcher/Writer/Reviewer/Verifier/Trace），按任务类型自动匹配 |
| **角色系统** | 无。技能本身充当"角色"（技能定义行为约束） | 三段式 role/goal/backstory + skills/tools/output_format/constraints/model_prefer |
| **并发控制** | 人工控制（wayfinder 的 Claim 机制） | 自动：blockedBy 声明 + 最大并行度 + 指数退避重试 |

### 5.4 质量保证对比

| 维度 | MPS | MAO |
|------|-----|-----|
| **验证机制** | **内建于技能纪律**：Completion Criteria（checklist）、Anti-patterns、TDD 红-绿循环、code-review 双轴审查 | **外挂 Verifier Agent**：三种验证强度（Light/Standard/Strict），三级错误分级（E1/E2/E3），三维扩展验证 |
| **错误恢复** | "Stop and say so"（diagnosing-bugs：无法构建反馈循环时明确退出，不跳到假设阶段） | 指数退避重试（E1）→ 回溯上游重执行（E2）→ 暂停全编排 Replan（E3） |
| **假设追踪** | 无系统化机制。Leading words 间接减少了隐含假设 | `initial-plan.md` 含显式假设清单，置信度+验证方式逐项标注 |
| **回归防护** | TDD 的回归测试 + diagnosing-bugs 的 regression phase | Verifier 验证 + 三维扩展（同模式横向扫描+上下游纵向追踪+边界条件） |

### 5.5 状态管理对比

| 维度 | MPS | MAO |
|------|-----|-----|
| **持久化方式** | 无。状态保存在对话上下文 + 文件系统制品（Issue、ADR、CONTEXT.md） | 文件级 JSON 检查点 + PID 检测 + 三级持久化（Full/Incremental/Delta） |
| **断点续传** | 不支持。跨 session 通过 handoff 文档手动传递上下文 | Level 1 任务级恢复已实现，Level 2/3 设计完成 |
| **制品存储** | 分散：GitHub Issues（wayfinder map、spec、tickets）、工作区文件（ADR、CONTEXT.md）、OS 临时目录（handoff 文档） | 集中：`~/.claude/orchestrator/checkpoints/` + 7 天自动归档 |

### 5.6 人机协作（HITL）对比

| 维度 | MPS | MAO |
|------|-----|-----|
| **HITL 定位** | **核心设计**而非附加功能。grilling 是整个系统的入口，人类在 Pipeline 每一步都有决策权 | 补充机制。三种模式（Approval Gate / Human Input / Review-then-Continue），每个 SOP 仅 1-2 个 gate |
| **交互粒度** | 细粒度：一问一答，逐决策分支遍历。每次只问一个问题，等待回答后再继续 | 粗粒度：阶段级审批，gate 在关键节点（如方案确认、部署前）暂停 |
| **超时处理** | 无（grilling 默认人等机器） | gate 可配 timeout + default_action（pause/approve/skip） |

### 5.7 可复用性对比

| 维度 | MPS | MAO |
|------|-----|-----|
| **技能/模板复用** | **原生可复用**：每个 model-invoked 技能是可复用的原语，可被多个 user-invoked 技能组合调用（如 grilling 被 5+ 技能复用） | 角色模板可复用（8 个预置角色），SOP 模板可复用（4 种场景）。但单次编排的 DAG 是一次性的 |
| **安装方式** | 零依赖：文件拷贝或 Plugin 安装，`git pull` 即可更新 | 零安装：Skill 文件，但依赖 Claude Code Agent 工具和 Task 系统 |
| **平台兼容** | 双平台：Claude Code + Codex/OpenAI | 单平台：仅 Claude Code |

### 5.8 学习曲线对比

| 维度 | MPS | MAO |
|------|-----|-----|
| **上手难度** | 低：输入 `/grill-me` 即用。每个技能独立，不需要理解全局 | 中高：需理解 Coordinator 角色、DAG 语法、HITL gate 配置、检查点系统 |
| **定制难度** | 低：复制 SKILL.md 修改即可。作者鼓励"Make them your own" | 高：需理解 SOP 模板、角色系统、DSL 语法后才能定制新场景 |
| **概念数量** | 少：Leading words、Completion criteria、Information hierarchy。核心概念约 10 个 | 多：Coordinator/DAG/blockedBy/HITL gate/checkpoint/SOP/Replan/criticality。核心概念约 20+ |

---

## 6. 亮点与创新点

### 6.1 7 行代码解决 700 万下载的问题

grill-me 的 SKILL.md 正文仅 3 行指令（"Run a `/grilling` session."），加 frontmatter 共 7 行，安装了 700 万次。这不只是"极简"的胜利——它证明**最好的工具是解决一个普遍、高频、未被充分解决的问题**。grill-me 解决的"人对齐"问题是 Agent 开发中最基础也最被忽视的元问题，大多数工具跳过了这一步直接进入"执行"。

### 6.2 "Plan, Don't Do"（Wayfinder）

Wayfinder 的编排哲学是**先探索后执行**的极端实践。与 MAO 的 DAG 静态规划不同，Wayfinder 承认不确定性的存在（fog of war），设计了一套**渐进式消除不确定**的机制：产出决策而非交付物，每个 ticket 仅一个 session，解决后清除该区域迷雾再前进。这是对"大爆炸式规划"的根本性否定。

### 6.3 "采访"而非"审问"的交互模式

grilling 引擎的核心设计不是"向用户索取信息"，而是"帮助用户理清思路"。每次提问附带推荐答案，把认知负担从用户转移到 AI。一问一答而非批量轰炸，尊重人类的认知节奏。这与典型的 form-filling HITL 形成鲜明对比——后者更像是"审问"：你给我信息，我替你执行。

---

## 7. 对 Multi-Agent Orchestrator 的启示

### 7.1 可直接借鉴的设计

| 借鉴点 | MPS 来源 | 如何融入 MAO |
|--------|---------|-------------|
| **Grilling 式需求澄清** | `grilling/SKILL.md` 的决策树逐分支采访协议 | 在 MAO 的方案阶段前增加 grilling 步骤，让 Coordinator 在生成 DAG 前通过一问一答确认目标、约束和优先级 |
| **Completion Criteria 体系** | writing-great-skills 的定义 + diagnosing-bugs/tdd/code-review 的实践 | 为每个子 Agent 任务定义显式完成标准（checklist），防止 premature completion。Verifier 验证前先检查 checklist |
| **词汇基础设施** | codebase-design 的 8 个核心概念 + domain-modeling 的术语体系 | 建立 MAO 自己的"共同词汇表"——如"编排"、"DAG 节点"、"frontier"等概念的精确锚定，减少 Coordinator 与子 Agent 间的概念漂移 |
| **Context hygiene 规则** | ask-matt 的 Smart Zone 概念（~120K token）+ grill→spec→tickets 在同一会话、implement 开新会话 | 为 MAO 的跨 Agent session 设计上下文边界规则，明确何时传递上下文（handoff 模式），何时从干净状态启动 |

### 7.2 理念层面的启发

**（1）编排的"薄壳化"。** MPS 证明：编排不需要重型引擎。通过名称约定（前一个 skill 的输出 = 下一个 skill 的输入）和清晰的制品格式，Pipeline 就可以自然串联。MAO 当前用 DAG + blockedBy 做显式依赖管理是正确的，但在简单场景下可考虑"名称约定"的轻量替代——不需要为 3 步的线性流程建立完整 DAG。

**（2）纪律 > 流程。** MPS 的 TDD、code-review、diagnosing-bugs 都是通过技能内置的纪律（而非外部监控）来保证质量。MAO 的 Verifier 是外挂式质量保证——这在多 Agent 场景下是必要的，但应考虑**将部分纪律内置到子 Agent 的角色定义中**，而不仅依赖事后验证。

**（3）消耗品心态。** 不应该为一次性任务构建永久结构。MAO 生成的 DAG、角色分配、gate 配置应该是临时的、一次性的产物。MPS 的 deprecated/ 桶启示我们：**主动弃用是健康的设计行为**，不是失败。

**（4）信息层级思维。** MPS 的三级信息层级（in-skill step → in-skill reference → external reference）可直接映射到 MAO 的角色定义：角色模板的核心纪律始终可见（in-skill step），详细的工具使用指南延迟加载（in-skill reference），领域特定知识通过外部引用访问（external reference）。

### 7.3 当前不适合借鉴的

| 不适合借鉴的点 | 原因 |
|---------------|------|
| **完全去中心化（无编排引擎）** | MAO 的核心价值是**自动编排**——处理 10+ 并行子任务的调度、依赖管理、错误恢复。MPS 的无编排模式适用于 3-5 步的线性人工 pipeline，不适配 MAO 的场景 |
| **无状态管理** | MPS 不持久化运行状态，依赖对话上下文 + 文件制品。MAO 需要跨 session 的断点续传和恢复，这是硬需求 |
| **无显式角色系统** | MPS 的"角色"内化在技能定义中。MAO 需要显式的角色系统来处理异构 Agent（不同模型、不同工具集、不同约束） |
| **无显式错误分级和恢复** | MPS 的 "Stop and say so" 适用于单 Agent 场景。MAO 的 10 Agent 并行编排需要 E1/E2/E3 三级错误分级来处理复杂的失败传播 |
| **完全依赖人工触发 Pipeline** | MAO 的用户期望"输入目标，自动编排"。MPS 的"人按顺序调用技能"模式与这一期望不兼容 |

---

## 8. 结论

Matt Pocock 的 skills 系统代表了一种与 Multi-Agent Orchestrator 互补的 Agent 设计范式。如果说 MAO 是**"用调度保证质量"**——通过 DAG、Verifier、HITL gate 等重机制来管理多 Agent 协作的复杂性，那么 MPS 就是**"用纪律保证质量"**——通过精准的概念锚定（leading words）、严格的信息层级、内建的完成标准来约束单个 Agent 的行为。

两者的优势领域不同：MAO 擅长**大任务的多 Agent 并行分解**（10+ 子任务、跨模型调度、复杂依赖管理），MPS 擅长**单 Agent 的行为可预测性**（需求对齐、代码质量、调试纪律）。两者的弱点也恰好互补：MAO 的编排机制重但纪律内化不足（依赖事后 Verifier），MPS 的纪律强但编排能力弱（不适合自动并行调度）。

最有价值的启示来自交叉点：**MAO 应该借鉴 MPS 的纪律内化思想**——将 Leading Words、Completion Criteria、词汇基础设施融入子 Agent 的角色定义中，让纪律成为 Agent 的默认行为而非外部约束。同时，**MPS 的"薄壳+厚原语"分层模式也是 MAO 角色系统演进的参考方向**——Coordinator 应更"薄"（只做路由和决策），而子 Agent 应更"厚"（内建更丰富的纪律约束）。

最终，两个系统的共同目标是一致的：**让 AI Agent 的行为可预测**。MPS 通过词汇和纪律实现，MAO 通过调度和验证实现。最好的系统可能位于两者之间——用词汇基础设施提升每个 Agent 的内在纪律，用编排引擎管理 Agent 间的协作复杂性。
