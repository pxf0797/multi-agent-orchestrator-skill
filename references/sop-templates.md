# 领域 SOP 模板库 — Primitive 层（厚）

> **两层结构中属于 Primitive 层（厚）：** 本文件包含每个 SOP 的完整执行指南（阶段细节、角色定义、并行度、验证强度、输出格式、HITL 位置、反模式）。场景匹配使用 **Shell 层**（skill.md Step 1 的 SOP 表格），确定具体场景后才按需加载本文件中的对应 SOP 章节。
>
> **维护约定：** 新增 SOP 时需同时更新两处 — skill.md Step 1 表格（Shell，追加一行）和本文件（Primitive，追加完整章节）。修改 SOP 的阶段细节只需改本文件。文件名约定：如未来某个 SOP 的 Primitive 过长（>200 行），可拆分为独立文件 `sop-<场景名>-detail.md`，在本文件中保留链接。

借鉴 MetaGPT 的固定 SOP 流程思想，为常见任务类型预定义标准化操作流程。SOP 提供流程骨架，Coordinator 填充具体任务内容。

## SOP 与 DAG 的关系

```
SOP 模板 = 领域最佳实践的固化流程（"这个领域通常怎么分阶段做"）
    │
    ▼
Coordinator 根据场景选择 SOP
    │
    ▼
SOP 实例化为具体 DAG（根据用户目标填充参数，"这次具体做什么"）
    │
    ▼
DAG 调度执行
```

> **HITL 列符号说明：** `yes` = 标准检查点 HITL gate（在调度循环阶段1处理）；`inline` = Coordinator 内联交互（不经过检查点系统，由 Coordinator 直接用 `AskUserQuestion` 等工具与用户交互，适用于检查点创建前的早期阶段）；`no` = 无人工交互。

---

## SOP 1: 软件开发 (software-dev)

**触发**: `code_dev` 场景
**描述**: 从需求到代码审查的完整软件开发流程。在任务拆解前新增**方案自审查阶段**（Coordinator 内部），确保方向正确后再派发 Agent 任务。

| 阶段 | 角色 | 并行度 | 输出 | HITL | 验证 |
|------|------|--------|------|------|------|
| 0. 方案设计与自审查 | Coordinator | 1 | 初步方案(initial-plan.md) | inline(歧义时) | — |
| 1. 需求分析与架构设计 | Architect | 1 | 模块划分方案、接口契约 | yes | — |
| 2. 并行模块开发 | Developer | max(6) | 各模块代码+测试 | no | Standard |
| 3. 集成测试 | QA | 1 | 集成测试报告 | yes | Strict |
| 4. 代码审查 | Reviewer | 1 | 审查报告 | no | — |

**Phase 0 说明：** Coordinator 先自行完成方案设计与自审查（生成方案 → 审查问题 → 修正或澄清歧义 → 确认），通过后才进入 Phase 1 派发 Architect Agent。详见 skill.md §1.5。

**Phase 0 假设清单：** 方案文档中必须包含"假设清单"段，每个技术决策标注:
- 依赖什么假设（如"所有 TF DB 格式一致"、"cutoff 一定在下一周期"）
- 置信度（高/中/低）
- 运行时验证方式

**DAG 流程:**
```
方案自审查(Coordinator) → [HITL: 歧义澄清(仅在歧义时触发)]
  → 需求分析与架构设计(Architect) → [HITL: 方案审批]
  → 并行模块开发(Developer×N) → 并行验证(Verifier×N, Standard)
  → 集成测试(QA) → 集成验证(Verifier×3, Strict)
  → [HITL: 测试报告审批]
  → 代码审查(Reviewer)
```

**Review 阶段增强检查项 [beta]:**
1. **配对函数一致性**: 识别共享同一隐式假设的函数对/组，变更其中一个时必须逐一验证另一个
2. **模式扫描**: 当修复了"数据追加/替换"类 bug 后，在相关函数中搜索相同的模式（`append`/`extend`/`+=`），检查是否存在同类问题
3. **假设验证**: 对照 Phase 0 的假设清单，逐一确认每个假设在实现中是否仍然成立

**模块开发 Agent Prompt 模板:**
```
[Role: Developer]
功能描述：<具体需求>
技术栈：<语言/框架>
接口契约：<输入/输出/API 约定>
文件路径：<创建/修改的文件>

要求：
1. 只实现本模块，不触及依赖的其他模块
2. 遵守接口契约中定义的边界
3. 包含基本的错误处理
4. 完成后记录做了什么
```

---

## SOP 2: 研究报告 (research-report)

**触发**: `deep_research` 场景
**描述**: 从课题拆解到最终报告的多维度深度研究。在课题拆解前新增**轻量方案阶段**（Coordinator 内部），仅做需求理解复述和歧义澄清，不做自审查循环。

| 阶段 | 角色 | 并行度 | 输出 | HITL | 验证 |
|------|------|--------|------|------|------|
| 0. 研究简报 | Coordinator | 1 | 研究简报(research-brief.md) | inline(歧义时) | — |
| 1. 课题拆解 | Coordinator | 1 | 搜索维度列表 | yes | — |
| 2. 并行信息搜集 | Researcher | max(12) | 各维度原始资料 | no | Light |
| 3. 分类整理 | Writer | max(3) | 分类整理稿 | no | Light |
| 4. 报告合成 | Writer | 1 | 完整报告 | yes | Standard |
| 5. 质量审核 | Verifier | 1 | 审核意见 | no | — |

**Phase 0 说明：** Coordinator 先做需求理解复述（核心问题/拆解维度/范围边界/不确定项），确认对研究方向的理解无误后再进入课题拆解。研究天然是探索性的，因此跳过自审查循环。详见 skill.md §1.5B。

**DAG 流程:**
```
研究简报(Coordinator) → [HITL: 歧义澄清(仅在歧义时触发)]
  → 课题拆解(Coordinator) → [HITL: 研究方向确认]
  → 并行搜索(Researcher×N) → 搜索验证(Verifier, Light)
  → 并行写作(Writer×N) → 写作验证(Verifier×N, Light)
  → 汇总报告(Writer) → 报告验证(Verifier, Standard)
  → [HITL: 报告审阅]
```

**搜索 Agent Prompt 模板:**
```
[Role: Researcher]
研究课题：<用户原始问题>
搜索维度：<本维度>
输出路径：~/.claude/orchestrator/output/<orch-id>/search-<dim>.md

要求：
1. 使用 WebSearch 搜索多个关键词
2. 对关键页面使用 WebFetch 获取详细内容
3. 标注信息的发布时间和可信度
4. 只做信息整理，不做深入分析
5. 发现关键信息时追加到 shared.jsonl
```

---

## SOP 3: 代码审查 (code-review)

**触发**: 审查/安全检查/审计
**描述**: 多维度并行代码审查，关注正确性、安全性和可维护性。本 SOP 有双重用途：(1) 作为 `code_dev` 场景 Phase 4 的审查模板嵌入开发流程；(2) 用户显式调用时（如 `/orchestrate review 这个 PR`）作为独立流程执行。**不作为独立场景自动触发。**

| 阶段 | 角色 | 并行度 | 输出 | HITL | 验证 |
|------|------|--------|------|------|------|
| 1. 静态分析 | Reviewer | 1 | 静态分析报告 | no | — |
| 2. 并行审查（逻辑/安全/性能） | Reviewer | max(3) | 各维度问题清单 | no | — |
| 3. 合成报告 | Reviewer | 1 | 综合审查报告 | no | — |

**DAG 流程:**
```
静态分析(Reviewer)
  → 并行审查: 逻辑审查 + 安全审查 + 性能审查(Reviewer×3)
  → 合成报告(Reviewer)
```

**审查维度:**
- **静态分析**: 代码结构、复杂度、死代码、依赖问题
- **逻辑审查**: 正确性、边界条件、错误处理、数据流
- **安全审查**: 注入风险、凭证泄露、权限检查、敏感数据处理
- **性能审查**: 算法复杂度、资源泄露、并发安全、缓存策略

---

## SOP 4: 部署验证 (deploy-verify)

**触发**: 部署/上线/发布/验证
**描述**: 上线前的完整验证流程

| 阶段 | 角色 | 并行度 | 输出 | HITL | 验证 |
|------|------|--------|------|------|------|
| 1. 环境检查 | QA | 1 | 环境检查报告 | no | — |
| 2. 并行功能验证 | QA | max(8) | 各功能验证结果 | no | — |
| 3. 性能基准测试 | QA | 1 | 性能报告 | no | — |
| 4. 部署决策 | Coordinator | 1 | 上线/回滚建议 | yes | — |

**DAG 流程:**
```
环境检查(QA)
  → 并行功能验证(QA×N: 核心路径/边界条件/异常场景/回归测试)
  → 性能基准测试(QA)
  → [HITL: 上线决策]
```

**验证维度:**
- **核心路径**: 用户关键操作流程端到端验证
- **边界条件**: 空值/超长/并发/超时等边界场景
- **异常场景**: 依赖故障、网络中断、数据不一致
- **回归测试**: 已有功能的自动化回归

---

## SOP 5: Bug 修复 (bug-fix)

**触发**: `general` 场景（bug-fix 为意图子类型）
**描述**: 从问题复现到回归验证的轻量修复流程。区别于 software-dev（从零开发），bug-fix 跳过方案设计和架构设计阶段，直接进入复现与根因追踪。

| 阶段 | 角色 | 并行度 | 输出 | HITL | 验证 |
|------|------|--------|------|------|------|
| 0. 问题复现 | Developer | 1 | 复现步骤 + 实际 vs 期望行为 | no | — |
| 1. 根因定位 | Trace Agent / Developer | 1 | 根因分析报告（含代码位置、触发条件、影响范围） | no | — |
| 2. 修复实现 | Developer | 1 | 修复代码 + 单元测试 | no | Standard |
| 3. 回归验证 | QA | 1 | 回归测试报告 | yes | Strict |

**DAG 流程:**
```
问题复现(Developer)
  → 根因定位(Trace Agent/Developer) → 三维追问(Coordinator 委托 Agent)
  → 修复实现(Developer) → 修复验证(Verifier, Standard)
  → 回归验证(QA) → 回归验证(Verifier, Strict)
  → [HITL: 修复审批]
```

**Intent 检测与 SOP 分支规则：**

Coordinator 在匹配到 software-dev 关键词后，执行 Intent 子类型检测：

| 子类型 | 检测条件 | 实际 SOP | 跳过阶段 |
|--------|---------|---------|---------|
| 从零开发 | 无已有代码库、功能全新 | software-dev（完整） | — |
| 重构 | 关键词含"重构/重写/整理"，且目标行为不变 | software-dev（精简） | Phase 0（方案自审查） |
| Bug 修复 | 关键词含"修bug/修复/debug/报错/异常/不对" | bug-fix | Phase 0+1（方案设计+架构设计） |
| 功能增强 | 在已有模块上添加功能 | software-dev（完整） | — |

> **检测优先级：** 若用户请求同时匹配多个子类型（如"重构并修复bug"），Coordinator 应通过 HITL 确认后拆分为两个独立编排。

---

## 高级验证模式（Tournament / Adversarial）

以下两种高级验证模式为 **opt-in**（需用户确认），不纳入标准 SOP 流程自动触发。Coordinator 在 DAG 设计阶段根据任务特征识别适用场景，通过 HITL gate 告知用户成本与风险，获得确认后激活。

### Tournament 触发场景

适用条件：同一目标存在 ≥2 种合理方案，且方案选择后果重大。

| SOP | 触发条件 | 验证对象 | 成本警告 |
|-----|---------|---------|---------|
| `software-dev` | 架构方案存在 ≥2 种合理技术路线、关键算法选型 | 架构设计方案 | ~6x 单 Agent |
| `research-report` | 研究议题存在 ≥2 个对立观点、高争议结论需要公平对比 | 对立观点方案 | ~6x 单 Agent |
| `general` | Coordinator 判断存在多种等效方案且决策后果重大 | 竞争方案 | ~6x 单 Agent |

**不适用：** 需求明确的 CRUD 开发、信息收集类任务、成本敏感的批量任务。

### Adversarial 触发场景

适用条件：错误成本极高（安全漏洞/合规风险/资金损失），需要 refute-first 对抗审查。

| SOP | 触发条件 | 验证对象 | 安全约束 |
|-----|---------|---------|---------|
| `software-dev` | 认证模块、加密代码、支付逻辑、权限系统 | 安全关键代码 | 对抗Agent只批判不修正 |
| `research-report` | 涉及法规/合规的结论、可能产生实际影响的建议 | 核心结论的事实基础 | 对抗Agent只批判不修正 |
| `deploy-verify` | 生产环境部署前的最终安全审查 | 部署安全清单 | 对抗Agent只批判不修正 |
| `general` | Coordinator 判断错误成本极高的任务 | 关键交付物 | 对抗Agent只批判不修正 |

**不适用：** 格式验证、常规 CRUD 业务逻辑、低风险信息整理。

> **与 Standard/Strict 的关系：** Tournament 和 Adversarial 是 Standard/Strict 的上层补充，非替代。Tournament 用于"方案择优"（方案级别），Strict 用于"产出验证"（产出级别）。Adversarial 用于"安全对抗"（refute-first），Strict 用于"共识投票"（consensus）。两者可组合使用（如 Tournament 选出的方案再由 Adversarial 做安全审查）。

---

## SOP 选择规则

| 关键词 | 匹配 SOP |
|--------|---------|
| 实现/开发/重构/写代码/添加功能/写测试 | software-dev |
| 修bug/修复/debug/报错/异常/不对 | bug-fix（详见 §SOP 5 的 Intent 检测分支表） |
| 研究/调查/分析/报告/对比/总结/侦查/scout/调研/深入 | research-report |
| 审查/安全检查/审计/code review | code-review（嵌入式 SOP，不作为独立场景自动触发） |
| 部署/上线/发布/验证/灰度 | deploy-verify |
| 不匹配上述 | 动态推断（general DAG） |

## 自定义 SOP

在 `~/.claude/skills/multi-agent-orchestrator/references/sops/` 目录下新增 `.md` 文件。Coordinator 启动时扫描该目录，场景识别时优先匹配自定义 SOP。
