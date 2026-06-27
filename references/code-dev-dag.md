# 代码开发 DAG 模板

## 触发条件

关键词：实现/开发/重构/写代码/修bug/修复/添加功能/优化性能/写测试

## DAG 结构

```
              ┌──────────────┐
              │  Coordinator  │  拆解开发需求为独立模块
              └──────┬───────┘
                     │
       ┌─────────────┼─────────────┐
       ▼             ▼             ▼
┌───────────┐ ┌───────────┐ ┌───────────┐
│  模块 A    │ │  模块 B    │ │  模块 C    │  ← 并行开发（无依赖）
│(Developer) │ │(Developer) │ │(Developer) │
└─────┬─────┘ └─────┬─────┘ └─────┬─────┘
      │              │              │
      ▼              ▼              ▼
┌───────────┐ ┌───────────┐ ┌───────────┐
│ Verify A  │ │ Verify B  │ │ Verify C  │  ← 并行验证 (Standard级)
│(Verifier) │ │(Verifier) │ │(Verifier) │      不通过→退回Developer修正
└─────┬─────┘ └─────┬─────┘ └─────┬─────┘
      └──────────────┼──────────────┘
                     │ blockedBy: [Verify A, B, C]
                     ▼
            ┌───────────────┐
            │   集成汇总     │  整合所有模块、解决冲突
            │   (QA Agent)  │
            └───────┬───────┘
                    │ blockedBy: [集成汇总]
                    ▼
            ┌───────────────┐
            │ Verify 集成    │  集成验证 (Strict级, 3 Verifier投票)
            │  (Verifier×3) │      不通过→退回QA修正
            └───────┬───────┘
                    │ blockedBy: [Verify 集成]
                    ▼
            ┌───────────────┐
            │  Code Review  │  最终代码审查
            │  (Reviewer)   │
            └───────────────┘
```

## 任务拆解原则

1. **模块化拆分**：每个 Agent 负责一个独立模块（文件/组件/功能点）
2. **接口先行**：Coordinator 在拆解时明确模块间的接口契约
3. **独立可测**：每个模块应有独立的测试标准
4. **集成后 Review**：汇总后运行测试 + Code Review

## Agent Prompt 模板

### 模块开发 Agent

```
你的任务是实现以下模块：<模块名>

功能描述：<具体需求>
技术栈：<语言/框架>
接口契约：<输入/输出/API 约定>
文件路径：<创建/修改的文件>

要求：
1. 只实现本模块，不触及依赖的其他模块
2. 遵守接口契约中定义的边界
3. 包含基本的错误处理
4. 完成后写入 ~/.claude/orchestrator/output/<module-name>.txt 简要记录做了什么
```

### 集成汇总 Agent

```
你的任务是整合以下模块：<模块列表>

各模块的输出文件：
- <模块A>: <文件路径>
- <模块B>: <文件路径>
...

要求：
1. 读取所有模块文件
2. 解决接口冲突
3. 确保整体功能完整可用
4. 运行集成测试（如果有）
5. 汇总输出到 ~/.claude/orchestrator/output/integration-summary.txt
```

### Code Review Agent（可选）

```
审查以下代码变更，关注：
1. 模块间接口是否一致
2. 边界情况处理
3. 安全隐患（SQL注入、XSS、凭证泄露等）
4. 代码可读性

输出审查报告到 ~/.claude/orchestrator/output/review-report.txt
```

### Verifier Agent（质检门禁）

```
[Role: Verifier]
[Goal: 严格验证模块输出质量，判定是否通过验证]
[验证强度: Standard]

验证目标：<模块名> 的实现代码
需求规格：<该模块的接口契约和功能要求>

验证维度：
1. **接口契约符合度** — 输入/输出是否完全匹配契约定义
2. **功能完整性** — 是否覆盖了所有要求的功能点
3. **边界处理** — 空值/超长/非法输入是否有基本处理
4. **代码安全性** — 无注入风险、无凭证硬编码、无路径遍历等

输出格式（JSON）：
{
  "pass": true|false,
  "score": 0-100,
  "issues": [{"severity": "critical|major|minor", "location": "文件名:行号", "description": "...", "suggestion": "..."}],
  "summary": "整体评价"
}

如果 pass=false，请给出具体、可操作的修正建议，以便 Developer 直接修改。
```

## 示例

### 输入
"帮我实现一个用户认证系统，包括注册、登录、JWT 中间件、密码重置"

### 拆解结果

| Task ID | 子任务 | blockedBy | Agent 类型 |
|---|---|---|---|
| T1 | 实现注册模块（/api/register） | [] | general-purpose |
| T2 | 实现登录模块（/api/login） | [] | general-purpose |
| T3 | 实现 JWT 中间件 | [] | general-purpose |
| T4 | 实现密码重置（/api/reset-password） | [T2] | general-purpose |
| T5 | Verify: 注册模块 (Standard) | [T1] | general-purpose |
| T6 | Verify: 登录模块 (Standard) | [T2] | general-purpose |
| T7 | Verify: JWT 中间件 (Standard) | [T3] | general-purpose |
| T8 | Verify: 密码重置 (Standard) | [T4] | general-purpose |
| T9 | 集成测试 + 入口文件 | [T5, T6, T7, T8] | general-purpose |
| T10 | Verify: 集成验证 (Strict) | [T9] | general-purpose |
| T11 | Code Review | [T10] | code-reviewer |

T1/T2/T3 并行 → T4 等待 T2 → T5-8 并行验证 → T9 集成 → T10 严格验证 → T11
