# 深度研究 DAG 模板

## 触发条件

关键词：研究/调查/分析/报告/对比/总结/侦查/scout/调研/深入/看看/了解一下

## DAG 结构

```
              ┌──────────────┐
              │  Coordinator  │  拆解研究课题为搜索维度
              └──────┬───────┘
                     │
       ┌─────────────┼─────────────┐
       ▼             ▼             ▼
┌───────────┐ ┌───────────┐ ┌───────────┐
│ 维度 A 搜索│ │ 维度 B 搜索│ │ 维度 C 搜索│  ← 并行搜索
│(Researcher)│ │(Researcher)│ │(Researcher)│     各自全新上下文
└─────┬─────┘ └─────┬─────┘ └─────┬─────┘
      │              │              │
      ▼              ▼              ▼
┌───────────┐ ┌───────────┐ ┌───────────┐
│ Verify A  │ │ Verify B  │ │ Verify C  │  ← 并行验证 (Light级)
│(Verifier) │ │(Verifier) │ │(Verifier) │      校验搜索覆盖面+来源可信度
└─────┬─────┘ └─────┬─────┘ └─────┬─────┘
      └──────────────┼──────────────┘
                     │ blockedBy: [全部搜索+验证]
       ┌─────────────┼─────────────┐
       ▼             ▼             ▼
┌───────────┐ ┌───────────┐ ┌───────────┐
│ 维度 A 整理│ │ 维度 B 整理│ │ 维度 C 整理│  ← 并行写作
│  (Writer)  │ │  (Writer)  │ │  (Writer)  │     各自整理搜索结果
└─────┬─────┘ └─────┬─────┘ └─────┬─────┘
      │              │              │
      ▼              ▼              ▼
┌───────────┐ ┌───────────┐ ┌───────────┐
│ Verify A  │ │ Verify B  │ │ Verify C  │  ← 并行验证 (Light级)
│(Verifier) │ │(Verifier) │ │(Verifier) │      校验结构化+引用来完整性
└─────┬─────┘ └─────┬─────┘ └─────┬─────┘
      └──────────────┼──────────────┘
                     │ blockedBy: [全部写作+验证]
                     ▼
            ┌───────────────┐
            │   汇总报告     │  合并所有维度，结构化输出
            │   (Writer)    │
            └───────┬───────┘
                    │ blockedBy: [汇总报告]
                    ▼
            ┌───────────────┐
            │ Verify 报告    │  报告验证 (Standard级)
            │  (Verifier)   │      结论一致性+数据准确性+完整性
            └───────────────┘
```

## 任务拆解原则

1. **维度拆分**：按研究方向/角度/信息源划分子任务
2. **搜索和整理分离**：搜索 Agent 负责搜集原始材料，写作 Agent 负责结构化整理
3. **搜索 Agent 用 WebSearch/WebFetch**：获取最新信息
4. **汇总 Agent 用大模型**：需要全局视角合成结论

## Agent Prompt 模板

### 搜索 Agent

```
你的任务是对以下维度进行信息搜集：<搜索维度>

研究课题：<用户原始问题>
搜索范围：<指定来源或开放搜索>

要求：
1. 使用 WebSearch 搜索多个关键词
2. 对关键页面使用 WebFetch 获取详细内容
3. 整理搜集到的原始信息到 ~/.claude/orchestrator/output/search-<dimension>.md
4. 格式：标题 + 来源链接 + 关键摘要（不要做深入分析，只做信息整理）
5. 标注信息的发布时间和可信度
6. 发现关键信息时，追加到共享上下文（每次 2-5 条）：
   echo '{"type":"finding","agent":"<N>","finding":"<100字发现>","source":"<URL>","confidence":"high|medium|low"}' >> ~/.claude/orchestrator/output/<orch-id>-shared.jsonl
7. 开始搜索前，检查共享上下文了解并行 Agent 方向：
   tail -10 ~/.claude/orchestrator/output/<orch-id>-shared.jsonl 2>/dev/null || echo "尚未有共享记录"
```

### 写作 Agent

```
你的任务是基于搜索结果整理以下维度的报告：<维度>

搜索原始材料：~/.claude/orchestrator/output/search-<dimension>.md

要求：
1. 阅读原始搜索结果
2. 结构化整理：核心观点 → 支撑论据 → 案例/数据
3. 去重：不同来源的相同信息合并
4. 标注所有引用来源
5. 输出到 ~/.claude/orchestrator/output/write-<dimension>.md
```

### 汇总 Agent

```
你的任务是将以下各维度报告合成为一份完整的最终报告：

维度报告：
- <维度A>: ~/.claude/orchestrator/output/write-A.md
- <维度B>: ~/.claude/orchestrator/output/write-B.md
...

研究课题：<用户原始问题>

要求：
1. 阅读所有维度报告
2. 提炼关键结论和共识
3. 标注争议点和不同观点
4. 使用对比表格呈现多维度信息
5. 生成最终的 Markdown 报告，包含：
   - TL;DR（3-5 条核心结论）
   - 分维度详述
   - 综合分析与建议
   - 信息来源附录
6. 输出到工作目录或用户指定位置
```

## 示例

### 输入
"深入研究一下 Claude Code 和 Cursor 在 Agent 能力上的差异，出一个对比报告"

### 拆解结果

| Task ID | 子任务 | blockedBy | criticality | Agent 类型 |
|---|---|---|---|---|---|
| T1 | 搜索 Claude Code Agent 能力 | [] | critical | general-purpose |
| T2 | 搜索 Cursor Agent 能力 | [] | critical | general-purpose |
| T3 | 搜索第三方对比评测 | [] | normal | general-purpose |
| T4 | 搜索 Anthropic/Cursor 官方文档 | [] | normal | general-purpose |
| T5 | Verify: 搜索质量 (Light) | [T1, T2, T3, T4] | normal | general-purpose |
| T6 | 整理 Claude Code 部分 | [T5] | critical | general-purpose |
| T7 | 整理 Cursor 部分 | [T5] | critical | general-purpose |
| T8 | Verify: 写作质量 (Light) | [T6, T7] | normal | general-purpose |
| T9 | 合成最终对比报告 | [T8] | critical | general-purpose |
| T10 | Verify: 报告质量 (Standard) | [T9] | optional | general-purpose |

T1/T2/T3/T4 并行 → T5 验证搜索 → T6+T7 并行写作 → T8 验证写作 → T9 汇总 → T10 最终验证
