# Pipeline 扇出模式

> **成熟度：** beta | **依赖：** 无

## 概述

当 DAG 中存在大量同质并行任务时，Pipeline 扇出模式比逐个创建 DAG 节点更高效。灵感来自 Claude Code Dynamic Workflows 的 `pipeline()` 无阶段间屏障设计。

Pipeline 扇出将 N 个同质任务聚合为单个 `pipeline-<name>` 任务，由单个 Agent 批量执行。与逐个创建 N 个 DAG 节点相比，Pipeline 模式减少了 DAG 节点数、降低了 Coordinator 调度开销，同时保留了并行执行的优势。

> **重要：** Pipeline 是推荐策略，不是强制规则。Coordinator 保留最终判断权，可根据实际情况选择逐任务拆解。

## 触发条件（3 条全部满足）

1. 同质任务数 **≥ 5**（共享相同角色、相同模型）
2. 任务之间 **无相互依赖**（blockedBy 均为空且无交集）
3. Coordinator 判断这些任务的输出 **无需逐个 HITL 审核**

## 适用场景

| 场景 | 示例 | 理由 |
|------|------|------|
| 并行搜索 | 从 6 个维度搜索同一主题 | 搜索独立、输出同构 |
| 并行验证 | 验证 5 个模块的正确性 | 验证独立、输出同构 |
| 批量测试 | 运行 8 个独立测试用例 | 测试独立、结果可合并 |
| 代码审查 | 审查 5 个独立文件的代码风格 | 审查独立、标准一致 |

## 不适用场景

| 场景 | 原因 |
|------|------|
| 任务间有数据依赖 | 需要 DAG 的 blockedBy 链 |
| 不同角色/模型混合 | 无法用统一 prompt 模板 |
| 需要逐个 HITL 审核 | pipeline 是批处理模式 |
| 增量构建（Step-by-step） | 后续步骤依赖前一步的结果 |
| 任务数 < 5 | 逐个 DAG 节点的开销可接受 |

## 阈值推导

**为什么是 ≥5？** 经验观察：当同质任务达到 5+ 时，逐个 DAG 节点管理的开销（TaskCreate、依赖设置、状态追踪）开始超过 Pipeline 批量管理的成本。具体而言：

- **N < 5**: 每个独立节点的调度开销（~1-2 turn 的 Coordinator 管理）可接受，且独立节点的错误隔离和进度可见性更高
- **N ≥ 5**: 管理 N 个同质节点的累积开销（N 次 TaskCreate + N 个生命周期追踪 + N 份完成通知处理）线性增长，而 Pipeline 将其聚合为常数级开销

阈值 5 是一个经验拐点，非硬性定理。Coordinator 在边界情况（如恰好 4 个大规模任务 vs 5 个小任务）可酌情判断。

## 使用方式

### Coordinator 侧

当 Step 2 任务拆解后满足触发条件时，Coordinator 使用 Pipeline 扇出替代逐个 TaskCreate：

```
常规模式（逐个节点）:
  T1: 搜索维度A (Researcher, haiku)
  T2: 搜索维度B (Researcher, haiku)
  T3: 搜索维度C (Researcher, haiku)
  T4: 搜索维度D (Researcher, haiku)
  T5: 搜索维度E (Researcher, haiku)
  T6: 搜索维度F (Researcher, haiku)
  → 6 个 DAG 节点，6 次 TaskCreate

Pipeline 模式（聚合）:
  T_pipeline: 并行搜索 (Researcher, haiku)
    └── pipeline 内部: [维度A, 维度B, 维度C, 维度D, 维度E, 维度F]
  → 1 个 DAG 节点，1 次 TaskCreate
```

### Agent 侧

Pipeline Agent 收到的 prompt 包含批量任务列表，Agent 内部并行处理：

```
[Role: Researcher]
[Goal: 并行搜索以下 N 个维度，每个维度返回独立结果]
[Pipeline Tasks:
  1. 搜索维度A: <具体搜索词>
  2. 搜索维度B: <具体搜索词>
  ...
  N. 搜索维度N: <具体搜索词>
]
[Output Format:
  每个维度独立输出一个小节，包含:
  - 维度名
  - 关键发现（3-5 条）
  - 信息来源
]
```

## DAG 集成

Pipeline 任务在 DAG 中表现为单个节点，但其内部产出 N 份独立输出：

```
        ┌──────────────────┐
        │  pipeline-search  │  ← 单个 DAG 节点
        │  (Researcher)     │
        │  [维度A..F]       │  ← 内部 6 个并行维度
        └────────┬──────────┘
                 │
                 ▼
        ┌──────────────────┐
        │  汇总报告         │
        │  (Writer)         │
        └──────────────────┘
```

下游任务可读取 pipeline 输出的各个维度结果进行汇总。

## 与逐个 DAG 节点的对比

| 维度 | 逐个 DAG 节点 | Pipeline 扇出 |
|------|-------------|--------------|
| DAG 节点数 | N | 1 |
| TaskCreate 调用 | N 次 | 1 次 |
| Coordinator 调度开销 | 高（管理 N 个 Agent 生命周期） | 低（管理 1 个 Agent） |
| 进度可见性 | 每个节点独立上报 | Agent 内部子步骤上报 |
| 错误隔离 | 单个节点失败不影响其他 | Agent 内部需自行处理局部失败 |
| HITL 粒度 | 可逐任务审核 | 批处理，整体审核 |
| 适用规模 | N < 5 | N ≥ 5 |
