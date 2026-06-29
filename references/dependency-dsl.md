# 声明式任务依赖 DSL

借鉴 CrewAI 的 `@listen`/`@router` 装饰器思想，提供一种比 JSON 更简洁的声明式语法来表达任务 DAG。Coordinator 在拆解阶段可选择使用 DSL 或 JSON 格式。

## 设计原则

- **比 JSON 更可读** — 适合人类直接编写和审查
- **可编译为 JSON** — DSL 编译后输出标准 JSON 任务定义（SKILL.md §3）
- **非强制** — Coordinator 可自由选择 DSL 或 JSON，DSL 是语法糖
- **向后兼容** — 纯文本格式，不影响现有检查点系统

## 语法

### @plan — 工作流声明

```
@plan "用户认证系统开发"
```

### @task — 任务定义

```
@task "注册模块" {
  描述: "实现用户注册功能，含邮箱验证"
  角色: developer
  模型: sonnet
  输出: "注册模块完整代码 + 单元测试"
}
```

### 依赖声明

```
@depends_on("登录模块")     # 显式依赖：本任务依赖指定任务
@after("架构设计")          # 语义糖：等价于 @depends_on
@after_all(["模块A", "模块B"])  # 等待多个任务全部完成
```

### @parallel — 并行组

```
@parallel:
  @task "模块A" { 描述: "..." 角色: developer }
  @task "模块B" { 描述: "..." 角色: developer }
  @task "模块C" { 描述: "..." 角色: developer }
```

### @conditional — 条件分支

```
@conditional
  when: "task_3.output.contains('ERROR')"
  then: @task "错误修复" { ... }
  else: @task "继续部署" { ... }
```

### @human_approval — HITL 门禁

```
@human_approval {
  问题: "请确认模块设计"
  超时: 3600
  模式: approval
}
```

## 完整字段参考

### @task 块内字段

| 字段 | 必需 | 类型 | 说明 |
|------|------|------|------|
| `描述` | yes | string | 任务描述（注入 Agent prompt） |
| `角色` | yes | string | developer/architect/qa/researcher/writer/reviewer/verifier |
| `模型` | no | string | haiku/sonnet/opus/fable（默认 sonnet） |
| `输出` | no | string | 期望的输出格式描述 |
| `关键度` | no | string | critical/normal/optional（默认 normal） |
| `超时` | no | int | 超时分钟数（默认 60） |
| `重试` | no | int | 最大重试次数（默认 1） |
| `验证` | no | string | light/standard/strict（默认 standard） |

### @human_approval 块内字段

| 字段 | 必需 | 说明 |
|------|------|------|
| `问题` | yes | 展示给用户的问题 |
| `超时` | no | 等待秒数（默认 3600） |
| `模式` | no | approval/input/review（默认 approval） |
| `选项` | no | 逗号分隔的选项列表 |

## 完整示例

### 示例 1: 认证系统开发

```
# auth-system.dsl

@plan "用户认证系统开发"

@parallel:
  @task "注册模块" {
    描述: "实现用户注册功能，含邮箱验证和密码强度校验"
    角色: developer
    模型: sonnet
    输出: "注册模块代码 + 单元测试"
    关键度: critical
    验证: standard
  }

  @task "登录模块" {
    描述: "实现用户登录功能，含会话管理和失败锁定"
    角色: developer
    模型: sonnet
    输出: "登录模块代码 + 单元测试"
    关键度: critical
  }

  @task "JWT中间件" {
    描述: "实现 JWT 认证中间件，支持 RS256 签名"
    角色: developer
    模型: sonnet
    输出: "JWT 中间件代码 + 使用文档"
    验证: strict
  }

@task "密码重置" {
  描述: "实现密码重置流程，含邮箱验证码"
  角色: developer
  模型: sonnet
  输出: "密码重置模块代码 + 测试"
}
@depends_on("登录模块")

@task "集成测试" {
  描述: "对所有模块进行端到端集成测试"
  角色: qa
  模型: sonnet
  输出: "集成测试报告"
  关键度: critical
  验证: strict
}
@after_all(["注册模块", "登录模块", "JWT中间件", "密码重置"])

@task "代码审查" {
  描述: "审查全部代码的质量和安全性"
  角色: reviewer
  模型: opus
  输出: "审查报告 + 修改建议"
}
@after("集成测试")
@human_approval {
  问题: "集成测试已完成，请查看报告后决定是否进入代码审查"
  模式: review
}
```

### 示例 2: 技术研究报告

```
# tech-research.dsl

@plan "微服务框架选型对比研究"

@parallel:
  @task "搜索Spring Cloud" {
    描述: "搜索 Spring Cloud 最新版本、生态、生产案例"
    角色: researcher
    模型: haiku
    验证: light
  }

  @task "搜索Go Kit" {
    描述: "搜索 Go Kit 最新版本、生态、生产案例"
    角色: researcher
    模型: haiku
  }

  @task "搜索K8s native方案" {
    描述: "搜索 Kubernetes native 微服务方案（Istio/Linkerd/Dapr）"
    角色: researcher
    模型: haiku
  }

  @task "搜索第三方评测" {
    描述: "搜索独立的框架对比评测和基准测试"
    角色: researcher
    模型: haiku
  }

@task "验证搜索质量" {
  描述: "验证四个搜索维度的覆盖面和来源可信度"
  角色: verifier
  模型: sonnet
  验证: light
}
@after_all(["搜索Spring Cloud", "搜索Go Kit", "搜索K8s native方案", "搜索第三方评测"])

@parallel:
  @task "整理框架对比表" {
    描述: "将搜索结果整理为结构化对比表"
    角色: writer
    模型: sonnet
  }
  @after("验证搜索质量")

  @task "整理案例分析" {
    描述: "整理各框架的生产案例和迁移经验"
    角色: writer
    模型: sonnet
  }
  @after("验证搜索质量")

@task "合成最终报告" {
  描述: "合并对比表和案例分析，输出完整选型报告"
  角色: writer
  模型: opus
  输出: "结构化的技术选型报告，含 TL;DR/对比表/建议"
}
@after_all(["整理框架对比表", "整理案例分析"])
@human_approval {
  问题: "报告初稿已完成，请审阅后确认方向"
  模式: review
}
```

## DSL → JSON 编译规则

Coordinator 在拆解阶段将 DSL 编译为 JSON 任务定义（见 SKILL.md §3）：

```
DSL 编译流程:
  1. @plan → json.plan 字段
  2. @task → json.tasks[] 元素
     - 描述 → description
     - 角色 → role
     - 模型 → model
     - 关键度 → criticality
     - 验证 → 注入 verify gate 配置
  3. @depends_on / @after → depends_on[]
  4. @after_all → depends_on[]（展开为列表）
  5. @parallel → 清除组内 depends_on（无依赖=并行）
  6. @conditional → 创建条件任务 + 运行时判断逻辑
  7. @human_approval → json.hitl_gates[] 元素
```

## 使用建议

- **简单任务用 JSON** — 2-5 个任务时 JSON 更直接
- **复杂任务用 DSL** — 6+ 个任务、多层依赖时 DSL 更清晰
- **协作审查用 DSL** — DSL 文件可作为设计文档供人审查
- **DSL 是可选的** — Coordinator 的 JSON 格式始终是权威的内部表示
