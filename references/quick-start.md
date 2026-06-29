# 快速入门指南

通过 3 个真实示例快速上手 Multi-Agent Orchestrator。

## 示例 1: 深度研究 — 技术选型报告

**用户输入**:
```
/orchestrate 研究一下微服务框架选型：对比 Spring Cloud、Go Kit、Kubernetes native 方案
```

**Coordinator 内部流程**:

1. **场景识别**: `deep_research`（关键词：研究、对比）
2. **加载 SOP**: `research-report`
3. **拆解任务**:

```json
{
  "plan": "微服务框架选型对比研究",
  "sop": "research-report",
  "tasks": [
    {"id": "1", "subject": "搜索 Spring Cloud 最新动态", "role": "researcher", "model": "haiku", "depends_on": []},
    {"id": "2", "subject": "搜索 Go Kit 最新动态", "role": "researcher", "model": "haiku", "depends_on": []},
    {"id": "3", "subject": "搜索 K8s native 方案", "role": "researcher", "model": "haiku", "depends_on": []},
    {"id": "4", "subject": "搜索第三方对比评测", "role": "researcher", "model": "haiku", "depends_on": []},
    {"id": "5", "subject": "验证搜索质量", "role": "verifier", "model": "sonnet", "depends_on": ["1","2","3","4"]},
    {"id": "6", "subject": "整理 Spring Cloud 部分", "role": "writer", "model": "sonnet", "depends_on": ["5"]},
    {"id": "7", "subject": "整理 Go Kit 部分", "role": "writer", "model": "sonnet", "depends_on": ["5"]},
    {"id": "8", "subject": "整理 K8s native 部分", "role": "writer", "model": "sonnet", "depends_on": ["5"]},
    {"id": "9", "subject": "合成最终对比报告", "role": "writer", "model": "opus", "depends_on": ["6","7","8"]}
  ]
}
```

4. **DAG 执行**: T1/T2/T3/T4 并行(haiku, ~2min) → T5 验证(sonnet, ~30s) → T6/T7/T8 并行(sonnet, ~1min) → T9 汇总(opus, ~2min)
5. **输出**: `微服务框架选型对比-研究报告.md`

---

## 示例 2: 代码开发 — 认证系统

**用户输入**:
```
/orchestrate 帮我实现用户认证系统，包括注册、登录、JWT中间件、密码重置
```

**Coordinator 内部流程**:

1. **场景识别**: `code_dev`（关键词：实现）
2. **加载 SOP**: `software-dev`
3. **拆解任务**:

```json
{
  "plan": "用户认证系统开发",
  "sop": "software-dev",
  "tasks": [
    {"id": "1", "subject": "架构设计：认证系统方案", "role": "architect", "model": "opus", "depends_on": []},
    {"id": "2", "subject": "实现注册模块", "role": "developer", "model": "sonnet", "depends_on": ["1"]},
    {"id": "3", "subject": "实现登录模块", "role": "developer", "model": "sonnet", "depends_on": ["1"]},
    {"id": "4", "subject": "实现JWT中间件", "role": "developer", "model": "sonnet", "depends_on": ["1"]},
    {"id": "5", "subject": "实现密码重置", "role": "developer", "model": "sonnet", "depends_on": ["3"]},
    {"id": "6", "subject": "验证注册模块", "role": "verifier", "model": "sonnet", "depends_on": ["2"]},
    {"id": "7", "subject": "验证登录模块", "role": "verifier", "model": "sonnet", "depends_on": ["3"]},
    {"id": "8", "subject": "验证JWT中间件", "role": "verifier", "model": "sonnet", "depends_on": ["4"]},
    {"id": "9", "subject": "验证密码重置", "role": "verifier", "model": "sonnet", "depends_on": ["5"]},
    {"id": "10", "subject": "集成测试", "role": "qa", "model": "sonnet", "depends_on": ["6","7","8","9"]},
    {"id": "11", "subject": "代码审查", "role": "reviewer", "model": "opus", "depends_on": ["10"]}
  ],
  "hitl_gates": [
    {"after": "1", "mode": "approval", "question": "架构设计方案是否满足需求？"},
    {"after": "10", "mode": "review", "question": "集成测试完成，请审阅后决定是否进入代码审查"}
  ]
}
```

4. **DAG 执行**: T1(opus) → [HITL] → T2/T3/T4 并行(sonnet) + T5(等T3) → T6-T9 并行验证 → T10 集成 → [HITL] → T11 审查
5. **输出**: 各模块代码文件 + 测试报告 + 审查报告

---

## 示例 3: Pipeline 串联 — 三阶段项目

**用户输入**:
```
/orchestrate pipeline init my-project research design implement
```

第一阶段 — 研究:
```
/orchestrate 深入研究微服务框架选型，输出对比报告
```

第二阶段 — 设计（自动读取上游输出）:
```
/orchestrate 基于研究报告设计系统架构
```

第三阶段 — 实现:
```
/orchestrate 实现核心模块：服务注册、配置中心、API网关
```

**Pipeline 进度查看**:
```
/orchestrate pipeline status my-project

Pipeline: my-project (pipeline-20260629-230000)
Status: in_progress
Current run: 3/3

  ✅ Run 1: research — completed
     Output: ~/.claude/orchestrator/pipelines/my-project/run-01-research/final-report.md
  ✅ Run 2: design — completed
     Output: ~/.claude/orchestrator/pipelines/my-project/run-02-design/architecture-design.md
  🔄 Run 3: implement — in_progress
```

---

## 常用命令速查

| 命令 | 说明 |
|------|------|
| `/orchestrate <目标>` | 单次编排：拆解→调度→汇总 |
| `/swarm <目标>` | 同 `/orchestrate`，语义偏向并行 |
| `/orchestrate pipeline init <name> <runs...>` | 初始化多 Run 管线 |
| `/orchestrate pipeline status <name>` | 查看管线进度 |
| `/orchestrate pipeline resume` | 恢复最近中断的管线 |

## 自动触发关键词

以下关键词会自动激活 Orchestrator（无需显式 `/orchestrate`）:

`并行` `多个agent` `同时` `swarm` `team` `分阶段` `工作流` `workflow` `pipeline` `多步骤`

## 下一步

- **多阶段项目**: 参考 [pipeline-chaining.md](pipeline-chaining.md) 了解手动串联
- **自动化串联**: 使用 `workflow-manager` skill 实现 YAML 定义 + 自动调度
- **角色配置**: 查看 [role-templates.md](role-templates.md) 了解 7 种角色定义
- **流程定制**: 查看 [sop-templates.md](sop-templates.md) 了解 4 个领域 SOP
