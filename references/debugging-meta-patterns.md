# 调试元模式 — 认知检查清单

从多次深度调试会话中提取的高层方法论，跨场景通用。这些不是代码技巧，是 Coordinator 的**认知行为准则**。

---

## 元模式 1: 假设追踪（Assumption Tracking）

> "Bug 不是代码写错了，是假设不成立了。"

每次设计决策都携带隐式假设。运行时假设被打破 → Bug。Coordinator 的职责是**让假设显式化**。

### 触发条件
- 任何 Step 1.5（方案设计）阶段
- 任何修复后问题仍存在时

### 行为
1. **设计阶段**: 在方案文档中增加"假设清单"段，每个技术决策标注显式假设
2. **修复阶段**: 每次 Agent 完成产出后，Coordinator 追问: "这个产出依赖什么假设？在运行时还成立吗？"
3. 假设清单格式:
   ```
   | 决策 | 假设 | 置信度 | 验证方式 |
   |------|------|--------|---------|
   | 使用 cutoff >= period_start | cutoff 一定在下一周期 | 高 | 日线同一天测试 |
   | 所有 TF 同时区 | yfinance 对所有 TF 用同一时区 | 中 | 检查 DB 实际数据 |
   ```

### 典型反例
- 时区 bug 修复了 3 轮才发现真正的假设错误: "分钟级 TF 有时区后缀，日线级 TF 没有"
- `_needs_synthesis` 的 "下一周期" 假设对日线天然不成立

---

## 元模式 2: 根因三角定位（Root Cause Triangulation）

> "修了但没好 = 修的是症状分支，不是根因主干。"

### 触发条件
- 同一问题修复 ≥2 次仍未解决时

### 行为
1. **列出所有可能原因**（≥3 个），按因果链排序
2. **从最上游验证**，不从上一次修复的下游开始
3. 构建"原因树":
   ```
   症状: 价格不对齐
     ├── 分支A: 时区格式（v1→v2→v3 修了 3 次）
     ├── 分支B: _needs_synthesis 逻辑
     └── 主干: 配对函数不一致
   ```
4. 每次修复后检查: "症状改善了多少？完全消失了吗？" — 如果只是部分改善，继续向上游追踪

### 典型反例
- 时区修复了三轮（v1 边界 bar 遗漏 → v2 反向边界 → v3 跨时区假转换），每次症状都"好一点"，但根因 (`_needs_synthesis` 逻辑 + `_get_query_start_for_synthesis` 不一致) 直到 5 轮后才定位

---

## 元模式 3: 具体优先（Concrete over Abstract）

> "跑一次真实数据比读十遍代码更有效。"

### 触发条件
- 以下任一条件满足时，**必须**调度 Trace Agent:
  - (a) 同一问题修复 ≥2 次仍未解决
  - (b) Bug 涉及时间/数值比较
  - (c) Bug 涉及级联/流水线/多级数据传递
  - (d) Coordinator 自己也无法确定根因

### Trace Agent 定义
参见 `references/role-templates.md` §Trace Agent。

与普通分析 Agent 的区别:
| | 分析 Agent | Trace Agent |
|---|---|---|
| 输入 | 源代码 | 源代码 + 实际 DB 数据 |
| 方法 | 读代码推理 | 运行函数，输出每一步中间值 |
| 输出 | 分析文档 | 逐行追踪日志 + 具体数值 |
| 可靠性 | 中（推理可能遗漏） | 高（事实即代码行为） |

### 典型反例
- 15 轮静态分析没找到根因，4 次"跑一下试试"全部命中

---

## 元模式 4: 三维扩展验证（Systematic Expansion）

> "找到一个 bug → 横向扫描同类模式 → 纵向追踪上下游 → 枚举所有边界。"

### 触发条件
- 任何 bug 修复完成后

### 三个维度

```
        边界维 (edge)
        ┌─ 空/单条/跨夜/精确相等/跨时区 ─┐
        │                                 │
  横向维 (horizontal)                 纵向维 (vertical)
  同模式的其他函数                    上下游依赖
  _build_output_df 的 append           _needs_synthesis 改了
  → _synthesize_incomplete_bar        → _get_query_start_for_synthesis
  也有同样问题                         也必须改
```

### 行为 — Coordinator 的三个追问
1. **横向**: "还有哪些函数/模块有同样的代码模式？" → 派 Agent 搜索相似模式
2. **纵向**: "这个修复会影响哪些下游/上游逻辑？" → 派 Agent 追踪调用链
3. **边界维**: "所有边界条件都验证了吗？" → 对照 `boundary-checklist.md`

### 典型反例
- `_build_output_df` 的 append→replace 修复后，`_synthesize_incomplete_bar` 里同样的 append 模式 5 轮后才被发现

---

## 协调器集成

在 SKILL.md 中:
- §1.5 方案设计增加"假设清单"段
- §5.3 增加 Trace Agent 分发规则
- §5.6 质检门禁增加三维扩展检查

在 role-templates.md 中:
- 新增 Trace Agent 角色定义

在 sop-templates.md 中:
- code_dev SOP Review 阶段增加"配对函数一致性"和"模式扫描"检查项
