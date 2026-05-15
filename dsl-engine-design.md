# DSL 解析引擎设计 — 完整规范

**日期**: 2026-05-15 | **上下文**: Multi-Agent Orchestrator Skill P2 目标 | **前置依赖**: design.md §12

---

## 目录

1. [EBNF 语法规范](#1-ebnf-语法规范)
2. [解析器架构](#2-解析器架构)
3. [编译管线](#3-编译管线)
4. [错误处理](#4-错误处理)
5. [实现路径](#5-实现路径)
6. [完整示例](#6-完整示例)

---

## 1. EBNF 语法规范

### 1.1 词法规则 (Lexical Grammar)

```ebnf
(* ─── 基本字符集 ─── *)
letter           = "A".."Z" | "a".."z" | "_" ;
digit            = "0".."9" ;
alphanumeric     = letter | digit ;
ident_char       = alphanumeric | "-" ;

(* ─── 注释 ─── *)
comment          = "#" , { ? any character except newline ? } , newline ;

(* ─── 字面量 ─── *)
string_literal   = "\"" , { ? any character except "\"" ? } , "\"" ;
integer_literal  = digit , { digit } ;

(* ─── 标识符 ─── *)
identifier       = ( letter , { ident_char } ) | ( "\"" , { ? any character except "\"" ? } , "\"" ) ;

(* ─── 数组 ─── *)
array_literal    = "[" , [ identifier , { "," , identifier } ] , "]" ;

(* ─── 空白 ─── *)
whitespace       = ? space | tab | newline ? ;
```

### 1.2 语法规则 (Syntax Grammar)

```ebnf
(* ─── 顶层 ─── *)
dsl_file         = plan_declaration , { task_statement | parallel_block | comment } ;

(* ─── @plan 声明 ─── *)
plan_declaration = "@plan" , string_literal , newline ;

(* ─── 任务声明 ─── *)
task_statement   = task_header , newline ,
                   task_body ,
                   { dependency_decl | hitl_decl | comment } ;

task_header      = "@task" , string_literal | identifier ;

task_body        = indent ,
                   "描述:" , string_literal , newline ,
                   [ "角色:" , role_value , newline ] ,
                   [ "模型:" , model_value , newline ] ,
                   [ "输出:" , string_literal , newline ] ,
                   dedent ;

role_value       = "developer" | "researcher" | "writer"
                 | "reviewer" | "qa" | "architect"
                 | identifier ;  (* 允许自定义角色 *)

model_value      = "haiku" | "sonnet" | "opus"
                 | "deepseek-flash" | "deepseek-pro"
                 | identifier ;  (* 允许自定义模型 *)

(* ─── 依赖声明 ─── *)
dependency_decl  = ( depends_on_decl | after_decl | after_all_decl ) , newline ;

depends_on_decl  = "@depends_on(" , identifier , ")" ;
after_decl       = "@after(" , identifier , ")" ;          (* 语法糖: 等价于 @depends_on *)
after_all_decl   = "@after_all(" , array_literal , ")" ;

(* ─── 并行块 ─── *)
parallel_block   = "@parallel" , [ ":" ] , newline ,
                   indent ,
                   { task_statement | comment } ,
                   dedent ;

(* ─── 条件分支 ─── *)
conditional_stmt = "@conditional" , newline ,
                   indent ,
                   "when:" , string_literal , newline ,
                   "then:" , inline_task , newline ,
                   [ "else:" , inline_task , newline ] ,
                   dedent ;

inline_task      = "@task" , string_literal | identifier ,
                   "{" , { ? task_field ? } , "}" ;

task_field       = "描述:" , string_literal
                 | "角色:" , role_value
                 | "模型:" , model_value
                 | "输出:" , string_literal ;

(* ─── 人机协作 ─── *)
hitl_decl        = "@human_approval" , [ "{" , newline ,
                   indent ,
                   "问题:" , string_literal , newline ,
                   [ "超时:" , integer_literal , newline ] ,
                   dedent , "}" ] , newline ;

(* ─── 缩进辅助 ─── *)
indent           = ? increase indentation level ? ;
dedent           = ? decrease indentation level ? ;
```

### 1.3 语法要点说明

| 设计决策 | 理由 |
|---|---|
| 缩进敏感（类似 Python/YAML） | 避免冗余的 `{}` 或 `end` 关键字，语法更简洁 |
| `@depends_on` 和 `@after` 等价 | 提供语义糖，`@after` 读起来更自然 |
| 任务名可用 `"引号字符串"` 或裸标识符 | 裸标识符限于 `[a-zA-Z_][a-zA-Z0-9_-]*`，含空格需引号 |
| `@parallel` 可选冒号 | `@parallel:` 和 `@parallel` 均可，兼容两种风格 |
| `@human_approval` 的大括号可选 | 单行 `@human_approval` 可省略配置块，使用默认超时 |
| `inline_task` 用大括号 | 条件分支内的内联任务需紧凑表示，避免缩进歧义 |

---

## 2. 解析器架构

### 2.1 两阶段管道总览

```
┌──────────────┐     ┌──────────────────────┐     ┌──────────────────────┐
│  .dsl 源文件   │ ──→ │  Stage 1: 解析器      │ ──→ │  Stage 2: 编译器      │
│               │     │  (Parser)             │     │  (Compiler)           │
│  *.dsl 文本   │     │                      │     │                      │
│               │     │  .dsl text → AST      │     │  AST → JSON Plan     │
└──────────────┘     └──────────────────────┘     └───────────┬──────────┘
                                                              │
                                                              ▼
                                                   ┌──────────────────────┐
                                                   │  TaskCreate 序列      │
                                                   │                      │
                                                   │  JSON → Task API     │
                                                   │  调用序列             │
                                                   └──────────────────────┘
```

### 2.2 AST 节点类型定义

#### 节点类型清单

| AST 节点 | 字段 | 说明 |
|---|---|---|
| `DSLDocument` | `plan: PlanNode`, `statements: Statement[]` | 根节点，包含 @plan 和所有子语句 |
| `PlanNode` | `name: string`, `line: number` | @plan 声明 |
| `TaskNode` | `name: string`, `body: TaskBody`, `deps: Dependency[]`, `hitl: HITLGateNode \| null`, `line: number` | 单个 @task 定义 |
| `TaskBody` | `description: string`, `role: string`, `model: string`, `output: string` | 任务属性体 |
| `ParallelBlock` | `tasks: TaskNode[]`, `line: number` | @parallel 块，包含一组可并行任务 |
| `ConditionalStmt` | `condition: string`, `thenBranch: TaskNode`, `elseBranch: TaskNode \| null`, `line: number` | @conditional 分支 |
| `HITLGateNode` | `question: string`, `timeout: number \| null`, `line: number` | @human_approval 关卡 |
| `DependencyEdge` | `kind: "single" \| "all"`, `targets: string[]`, `line: number` | 依赖边（单一依赖或多依赖） |
| `InlineTaskDef` | `name: string`, `fields: Record<string, string>`, `line: number` | 条件分支内的内联任务 |

#### TypeScript 类型定义

```typescript
// ─── AST 节点类型 ───

interface ASTNode {
  line: number;
}

interface DSLDocument extends ASTNode {
  kind: "document";
  plan: PlanNode;
  statements: TopLevelStatement[];
}

type TopLevelStatement =
  | TaskNode
  | ParallelBlock
  | ConditionalStmt;

interface PlanNode extends ASTNode {
  kind: "plan";
  name: string;
}

interface TaskNode extends ASTNode {
  kind: "task";
  name: string;
  body: TaskBody;
  deps: DependencyEdge[];
  hitl: HITLGateNode | null;
}

interface TaskBody extends ASTNode {
  kind: "task_body";
  description: string;
  role: string;
  model: string;
  output: string;
}

interface ParallelBlock extends ASTNode {
  kind: "parallel_block";
  tasks: TaskNode[];
}

interface ConditionalStmt extends ASTNode {
  kind: "conditional";
  condition: string;       // 运行时求值的表达式
  thenBranch: TaskNode;
  elseBranch: TaskNode | null;
}

interface HITLGateNode extends ASTNode {
  kind: "hitl_gate";
  question: string;
  timeout: number | null;  // 秒，null 表示使用默认值
}

interface DependencyEdge extends ASTNode {
  kind: "dep_single";      // @depends_on / @after
  target: string;
  | kind: "dep_all";       // @after_all
  targets: string[];
}

interface InlineTaskDef extends ASTNode {
  kind: "inline_task";
  name: string;
  fields: Record<string, string>;
}
```

### 2.3 解析器状态机

解析器基于缩进驱动，维护一个状态栈：

```
状态转换图:

  START ──→ AFTER_PLAN ──→ IN_TASK ──→ AFTER_DECL
                │              │            │
                │              ▼            │
                └──→ IN_PARALLEL            │
                      │                     │
                      └──→ IN_TASK ─────────┘
                      │         │
                      │         ▼
                      └──→ AFTER_DECL
                                    │
                                    ▼
                                 DONE

状态栈:
  [{line: 0, indent: 0}]                    ← 初始
  [{line: 1, indent: 0, type: "parallel"}]  ← 进入 @parallel
  [{line: 1, indent: 0, type: "parallel"},
   {line: 2, indent: 2, type: "task"}]      ← 进入 parallel 内 task
  [{line: 1, indent: 0, type: "parallel"}]  ← 退出 task (dedent)
  []                                         ← 退出 parallel (dedent)
```

### 2.4 解析算法伪代码

```
function parse(source: string): DSLDocument
  1. 预处理: 去除空行, 规范化缩进 (tab→2空格)
  2. 按行扫描:
     a. 去除行首尾空白，跳过空行和注释行
     b. 计算行缩进层级 (每2空格 = 1级)
     c. 匹配行首关键字:
        "@plan"   → 提取计划名, 校验唯一性
        "@task"   → 进入任务头解析模式
        "@parallel" → 推入并行块上下文
        "@depends_on" → 提取依赖目标
        "@after_all"  → 提取依赖数组
        "@human_approval" → 提取审批配置
        "@conditional" → 进入条件分支解析
        其他 → 匹配任务体字段 (描述:/角色:/模型:/输出:)
  3. 构建 AST:
     a. 关联依赖声明到前一个 @task
     b. 关联 HITL 声明到前一个 @task
     c. 验证 parallel 块内的 task 无显式依赖
     d. 收集所有语句到 DSLDocument.statements
  4. 返回 DSLDocument
```

---

## 3. 编译管线

### 3.1 AST → JSON Plan 转换规则

#### 总映射

```
┌──────────────────────┐        ┌──────────────────────────────┐
│       AST            │        │       JSON Plan              │
│                      │        │                              │
│ DSLDocument          │ ────→  │ {                            │
│   .plan              │        │   "plan": "...",             │
│   .statements[]      │        │   "tasks": [...],            │
│     TaskNode         │        │   "hitl_gates": [...],       │
│     ParallelBlock    │        │   "conditions": [...]        │
│     ConditionalStmt  │        │ }                            │
│     HITLGateNode     │        │                              │
└──────────────────────┘        └──────────────────────────────┘
```

#### 规则 1: @plan → JSON plan 字段

```
plan_declaration → JSON root:
  {
    "plan": <plan.name>,
    "sop": <根据场景自动检测, 或显式指定>,
    "tasks": [],
    "hitl_gates": [],
    "conditions": []
  }
```

#### 规则 2: @parallel → blockedBy 空数组

```
ParallelBlock → JSON tasks[]:

  输入: @parallel 块内有 Task_A, Task_B, Task_C
  输出:
    {
      "id": "1", "subject": "Task_A", "blockedBy": [], ...
    }
    {
      "id": "2", "subject": "Task_B", "blockedBy": [], ...
    }
    {
      "id": "3", "subject": "Task_C", "blockedBy": [], ...
    }

  规则: parallel 块内所有任务的 blockedBy 为空数组。
       并行性由执行引擎保证——所有 blockedBy=[] 的任务同时调度。

  约束检查: @parallel 块内不可出现 @depends_on/@after/@after_all。
```

#### 规则 3: @depends_on / @after / @after_all → blockedBy 数组

```
@depends_on("X") → blockedBy: ["X"]
  语义: "本任务在 X 之后执行"

  Task_B 在 body 后声明 @depends_on("Task_A")
  输出:
    {
      "id": "2",
      "subject": "Task_B",
      "blockedBy": ["1"],  // 引用 Task_A 的 ID
      ...
    }

  解析过程:
    1. 从依赖声明中提取目标任务名 "Task_A"
    2. 在已注册的任务名→ID 映射表中查找 Task_A 的 ID
    3. 若找到: blockedBy 填入 ["<Task_A_ID>"]
    4. 若未找到: 延迟解析 (允许前向引用) 或报错 E002

依赖合并规则:
  @depends_on("A") + @depends_on("B") → blockedBy: ["<A_ID>", "<B_ID>"]
  @after("A") + @after_all(["B", "C"]) → blockedBy: ["<A_ID>", "<B_ID>", "<C_ID>"]
```

#### 规则 4: @conditional → 条件任务 + JSON conditions 数组

```
@conditional → JSON task + conditions entry:

  输入:
    @conditional
      when: "task_3.output.contains('ERROR')"
      then: @task "错误修复" { ... }
      else: @task "继续部署" { ... }

  输出 (tasks[]):
    {
      "id": "4",
      "subject": "$conditional_决策路由器",
      "description": "运行时条件判断: task_3.output.contains('ERROR')",
      "role": "coordinator",      // 由 Coordinator Agent 执行
      "model": "opus",            // 用大模型做判断
      "blockedBy": ["3"],         // 等待条件依赖的任务完成
      "is_conditional_router": true,
      "condition": "task_3.output.contains('ERROR')"
    }
    {
      "id": "5",
      "subject": "错误修复",
      "description": "...",
      "role": "developer",
      "model": "sonnet",
      "blockedBy": ["4"],         // 依赖决策路由器的判断结果
      "conditional_branch": "then"
    }
    {
      "id": "6",
      "subject": "继续部署",
      "description": "...",
      "role": "developer",
      "model": "sonnet",
      "blockedBy": ["4"],         // 依赖决策路由器的判断结果
      "conditional_branch": "else"
    }

  输出 (conditions[]):
    {
      "router_task_id": "4",
      "condition_expr": "task_3.output.contains('ERROR')",
      "then_task_ids": ["5"],
      "else_task_ids": ["6"]
    }

  运行时行为:
    1. Task 4 (决策路由器) 被调度, blockedBy=["3"]
    2. Task 3 完成后, Task 4 自动解锁
    3. Coordinator 读取 Task 3 的输出
    4. 求值 condition_expr:
       - true  → 解锁 Task 5 (then 分支), Task 6 保持 blocked
       - false → 解锁 Task 6 (else 分支), Task 5 保持 blocked
       - 表达式无法求值 → 用大模型 (Opus) 分析 Task 3 输出,
         得出布尔结论
    5. 未选中的分支标记为 "skipped"
```

#### 规则 5: @human_approval → hitl_gates 数组

```
@human_approval → JSON hitl_gates[]:

  输入 (接在 @task "集成测试" 之后):
    @human_approval {
      问题: "集成测试已完成，请查看报告后决定是否进入代码审查"
      超时: 3600
    }

  输出 (hitl_gates[]):
    {
      "gate_id": "approval-<task_id>",
      "after_task": "5",                  // 关联的上游 Task ID
      "mode": "approval",
      "question": "集成测试已完成，请查看报告后决定是否进入代码审查",
      "timeout": 3600,
      "default_action": "pause",
      "status": "pending"
    }

  关联规则:
    @human_approval 紧跟在 @task 后面时,
    隐式关联到该 task: gate.after_task = "<当前task的ID>"

  当 @human_approval 单独出现（不与 task 相邻）:
    gate.after_task = <前一个 task 的 ID>

  调度行为:
    - after_task 完成 → 检查是否有关联的 HITL gate
    - 有 → 暂停调度, 展示 question, 等待用户响应
    - 用户 approve → gate.status = "approved", 解锁下游任务
    - 用户 reject  → gate.status = "rejected", DAG 进入修改循环
```

#### 规则 6: 角色/模型 → Agent prompt 注入

```
TaskBody.role + TaskBody.model → Agent 参数:

  {
    "id": "1",
    "subject": "注册模块",
    "role": "developer",
    "model": "sonnet",
    ...
  }

  编译输出:
    1. role "developer" → 加载 roles/developer.md 角色模板
    2. 将 role+goal+backstory+skills 注入 Agent prompt 前缀
    3. model "sonnet" → Agent 调用时设置 model: "sonnet"

  映射规则:
    role 名称 → roles/<role>.md 模板文件
    model 名称 → Agent(model: <model_name>)
```

### 3.2 JSON Plan → TaskCreate 序列

#### 转换算法

```
function compileToTaskCreate(jsonPlan: JSONPlan): TaskCreateSequence

  for each task in jsonPlan.tasks:

    1. TaskCreate:
       TaskCreate(
         id: task.id,
         subject: task.subject,
         description: task.description,
         prompt: buildAgentPrompt(task, jsonPlan),
         model: task.model,
         subagent_type: "general-purpose",
         run_in_background: true
       )

    2. 依赖注册 (仅 blockedBy 非空):
       if task.blockedBy.length > 0:
         addBlockedBy(taskId: task.id, blockedBy: task.blockedBy)

    3. HITL gate 关联 (仅任务关联了 gate):
       if taskHasHitlGate(task.id, jsonPlan.hitl_gates):
         registerGate(afterTask: task.id, ...)

    4. 条件分支注册 (仅 is_conditional_router):
       if task.is_conditional_router:
         registerCondition(
           routerTask: task.id,
           condition: task.condition,
           thenBranch: ..., elseBranch: ...
         )

    5. 序列化:
       每一步调用记录追加到 TaskCreateSequence[]
```

#### Agent Prompt 构建

```
function buildAgentPrompt(task, plan):
  1. 加载角色模板: 从 roles/<role>.md 读取
     - 注入 [Role], [Goal], [Backstory], [Skills], [Constraints]
  2. 注入任务描述:
     - task.description
  3. 注入输出格式:
     - task.body.output
  4. 注入全局上下文:
     - plan.name
  5. 注入任务依赖上下文:
     - 如果 blockedBy 非空: 注入上游任务的输出摘要
       (从检查点文件读取)
  6. 返回完整 prompt 字符串
```

#### TaskCreate 调用序列示例

```
[
  // Step 1: 创建 Task 1 (注册模块, 无依赖)
  { "action": "TaskCreate", "params": { "id": "1", "subject": "注册模块", ... } },

  // Step 2: 创建 Task 2 (登录模块, 无依赖)
  { "action": "TaskCreate", "params": { "id": "2", "subject": "登录模块", ... } },

  // Step 3: 创建 Task 3 (JWT中间件, 无依赖)
  { "action": "TaskCreate", "params": { "id": "3", "subject": "JWT中间件", ... } },

  // Step 4: 创建 Task 4 (密码重置, 依赖 Task 2)
  { "action": "TaskCreate", "params": { "id": "4", "subject": "密码重置", ... } },
  { "action": "addBlockedBy", "params": { "id": "4", "blockedBy": ["2"] } },

  // Step 5: 创建 Task 5 (集成测试, 依赖 Task 1,2,3,4)
  { "action": "TaskCreate", "params": { "id": "5", "subject": "集成测试", ... } },
  { "action": "addBlockedBy", "params": { "id": "5", "blockedBy": ["1","2","3","4"] } },

  // Step 6: 注册 HITL gate (Task 5 完成后暂停)
  { "action": "registerGate", "params": {
      "gate_id": "approval-5",
      "after_task": "5",
      "question": "集成测试已完成..."
  }},

  // Step 7: 创建 Task 6 (代码审查, 依赖 Task 5)
  { "action": "TaskCreate", "params": { "id": "6", "subject": "代码审查", ... } },
  { "action": "addBlockedBy", "params": { "id": "6", "blockedBy": ["5"] } }
]
```

### 3.3 编译管线流程图

```
┌─────────────────────────────────────────────────────────────┐
│                     编译管线 (Compile Pipeline)               │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  AST                                                         │
│   │                                                         │
│   ▼                                                         │
│  Pass 1: 任务注册 (Task Registry)                             │
│   ├── 遍历所有 TopLevelStatement                              │
│   ├── 展平 parallel 块 (并行任务各自独立注册)                    │
│   ├── 展开 conditional 块 (then/else 各自注册)                │
│   └── 输出: 任务名 → {id, metadata} 映射表                    │
│   │                                                         │
│   ▼                                                         │
│  Pass 2: 依赖解析 (Dependency Resolution)                     │
│   ├── 遍历每个任务的 DependencyEdge                           │
│   ├── @depends_on("X") → 查映射表, 填入 blockedBy            │
│   ├── @after_all(["A","B"]) → 查映射表, 填入 blockedBy 数组  │
│   ├── parallel 块内验证无依赖声明                              │
│   └── 输出: 每个任务的完整 blockedBy 数组                      │
│   │                                                         │
│   ▼                                                         │
│  Pass 3: 循环依赖检测 (Cycle Detection)                       │
│   ├── 对 DAG 执行拓扑排序                                    │
│   ├── 若无法拓扑排序 → 报告 E001 + 输出循环路径                │
│   └── 若通过 → 生成拓扑执行顺序                               │
│   │                                                         │
│   ▼                                                         │
│  Pass 4: 条件 + HITL 处理                                    │
│   ├── @conditional → 创建条件路由器任务 + conditions 条目     │
│   ├── @human_approval → 创建 hitl_gates 条目                │
│   └── 与上下游任务的连接 blockedBy 补全                       │
│   │                                                         │
│   ▼                                                         │
│  Pass 5: 角色+模型绑定                                       │
│   ├── 角色名 → 校验是否为预置角色或自定义角色                    │
│   ├── 模型名 → 校验是否在允许列表中                            │
│   └── 生成 Agent prompt 所需参数                              │
│   │                                                         │
│   ▼                                                         │
│  Pass 6: JSON 序列化 + 检查点写入                             │
│   ├── 输出完整 JSON Plan                                     │
│   ├── 写入检查点文件                                         │
│   └── 可选: 输出 TaskCreate 调用序列                         │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 4. 错误处理

### 4.1 错误类型总览

| 错误码 | 名称 | 阶段 | 严重度 |
|---|---|---|---|
| E001 | 循环依赖检测 (Cyclic Dependency) | 编译 | FATAL |
| E002 | 未定义任务引用 (Undefined Task Reference) | 编译 | FATAL |
| E003 | 并行块内依赖冲突 (Parallel-DependsOn Conflict) | 解析 | FATAL |
| E004 | 缺少 @plan 声明 (Missing Plan Declaration) | 解析 | FATAL |
| E005 | 角色/模型值非法 (Invalid Role or Model) | 编译 | WARNING |
| E006 | 重复任务名 (Duplicate Task Name) | 编译 | FATAL |
| E007 | 条件表达式为空 (Empty Condition Expression) | 解析 | FATAL |

### 4.2 错误详情与修复建议

#### E001 — 循环依赖检测

```
错误码:    E001
严重度:    FATAL
阶段:      编译 (Pass 3: 循环依赖检测)
描述:      DAG 中存在循环依赖，导致任务永远无法开始

检测方法:  对 blockedBy 关系执行 DFS 拓扑排序，
           若存在后向边 (back edge) 则判定为循环

触发示例:
  @task "模块A"
  @depends_on("模块B")    // A → B

  @task "模块B"
  @depends_on("模块C")    // B → C

  @task "模块C"
  @depends_on("模块A")    // C → A (循环!)

错误输出:
  [E001] 检测到循环依赖: 模块A → 模块B → 模块C → 模块A
  建议修复: 移除以下依赖之一:
    - @task "模块C" 中的 @depends_on("模块A")
    - 或 @task "模块A" 中的 @depends_on("模块B")

修复优先级:
  1. 检查是否真的需要循环——DAG 不允许循环
  2. 如需要双向依赖，拆分为 3 个阶段:
     A→B→C (第一阶段) → 合并结果 → 条件性重执行 (第二阶段)
```

#### E002 — 未定义任务引用

```
错误码:    E002
严重度:    FATAL
阶段:      编译 (Pass 2: 依赖解析)
描述:      @depends_on / @after / @after_all 引用的任务名不存在

触发示例:
  @task "模块A"
  @depends_on("不存在的模块")

错误输出:
  [E002] 第 3 行: @depends_on("不存在的模块") — 未找到引用的任务
  建议修复 1: 检查 "不存在的模块" 是否拼写正确
  建议修复 2: 确认 @task "不存在的模块" 是否已定义
  建议修复 3: 如果 "不存在的模块" 是未来的任务，请先定义它

处理策略:
  1. 第一遍扫描: 收集所有任务名 → 映射表
  2. 第二遍扫描: 解析依赖, 未命中则报错
  3. 不支持前向引用穿透 (所有任务必须在使用前定义)
```

#### E003 — 并行块内依赖冲突

```
错误码:    E003
严重度:    FATAL
阶段:      解析 (ParallelBlock 构建)
描述:      @parallel 块内的任务不能有显式 @depends_on / @after

触发示例:
  @parallel:
    @task "模块A"
    @task "模块B"
    @depends_on("模块A")    // 语义冲突!

错误输出:
  [E003] 第 5 行: @parallel 块内的 @task "模块B" 声明了 @depends_on
        并行块内的所有任务必须无依赖(blockedBy=[])
  建议修复:
    选项 1: 将 @depends_on 任务移出 @parallel 块
    选项 2: 使用 @after_all 在 parallel 块外声明跨块依赖
    选项 3: 如果模块B确实需要依赖模块A，拆分为两个独立声明:
      @task "模块A" { ... }
      @task "模块B" { ... } @depends_on("模块A")
```

#### E004 — 缺少 @plan 声明

```
错误码:    E004
严重度:    FATAL
阶段:      解析 (文件级校验)
描述:      .dsl 文件必须以 @plan 开头

触发示例:
  # 文件缺少第一行 @plan
  @task "模块A" { ... }

错误输出:
  [E004] 第 1 行: 文件必须以 @plan "..." 声明开头
  建议修复: 在文件第一行添加 @plan "你的计划名称"
  示例:     @plan "用户认证系统开发"

设计理由:
  - @plan 提供必要的命名空间和上下文
  - 编译时需要 plan name 作为 JSON root 和检查点文件名
  - 强制结构化和可读性
```

#### E005 — 角色/模型值非法

```
错误码:    E005
严重度:    WARNING (不阻塞编译, 但输出警告)
阶段:      编译 (Pass 5: 角色+模型绑定)
描述:      role 或 model 字段使用了未识别的值

触发示例:
  @task "模块A"
    角色: super_coder    // 非预置角色
    模型: gpt-4          // 非支持的模型

错误输出:
  [E005/WARN] 第 3 行: 角色 "super_coder" 不是预置角色
  预置角色: developer, researcher, writer, reviewer, qa, architect
  当前处理: 跳过角色模板注入, 使用通用 Agent prompt
  建议修复: 使用预置角色名称, 或在 roles/ 目录下创建 super_coder.md

  [E005/WARN] 第 4 行: 模型 "gpt-4" 不在支持列表中
  支持模型: haiku, sonnet, opus, deepseek-flash, deepseek-pro
  当前处理: 降级为默认模型 (sonnet)
  建议修复: 使用支持的模型名

处理策略:
  - WARNING 级别: 编译继续, 但输出警告信息
  - 未知角色: 跳过模板注入, 使用通用 prompt
  - 未知模型: 降级为默认模型 (sonnet)
```

#### E006 — 重复任务名

```
错误码:    E006
严重度:    FATAL
阶段:      编译 (Pass 1: 任务注册)
描述:      两个或多个 @task 使用了相同的名称

触发示例:
  @task "模块A" { ... }
  @task "模块A" { ... }    // 重复名

错误输出:
  [E006] 第 5 行: @task "模块A" 与第 1 行定义重复
  建议修复: 重命名其中一个任务, 确保任务名唯一

注意事项:
  - 任务名是依赖引用的唯一标识 (@depends_on("模块A"))
  - 重复名会导致 @depends_on 引用歧义
  - 大小写敏感: "ModuleA" 和 "moduleA" 是不同的任务
```

#### E007 — 条件表达式为空

```
错误码:    E007
严重度:    FATAL
阶段:      解析 (@conditional 处理)
描述:      @conditional 的 when: 表达式为空或缺失

触发示例:
  @conditional
    when: ""              // 表达式为空!
    then: @task "A" { ... }

错误输出:
  [E007] 第 2 行: @conditional 的 when 表达式不能为空
  建议修复: 提供一个有效的运行时判断条件
  示例:     when: "task_3.output.contains('ERROR')"
```

### 4.3 错误处理流程

```
解析开始
   │
   ▼
┌─ 语法错误检查 ─────┐
│ E004 (缺@plan)      │ ← FATAL, 立即终止
│ E007 (条件为空)      │ ← FATAL, 立即终止
│ E003 (并行内依赖)    │ ← FATAL, 立即终止
└────────────────────┘
   │ 通过
   ▼
┌─ 语义错误检查 (Pass 1-2) ─┐
│ E006 (重复任务名)           │ ← FATAL, 立即终止
│ E002 (未定义引用)           │ ← FATAL, 立即终止
└──────────────────────────┘
   │ 通过
   ▼
┌─ 编译期错误检查 (Pass 3-5) ──┐
│ E001 (循环依赖)               │ ← FATAL, 立即终止
│ E005 (角色/模型非法, WARNING) │ ← 继续, 记录警告
└────────────────────────────┘
   │ 通过或跳过
   ▼
┌─ 输出 ─────────────┐
│ JSON Plan + Warnings│
│ (或错误信息)         │
└────────────────────┘
```

---

## 5. 实现路径

### 5.1 解析器语言选择

| 维度 | Shell awk/sed 轻量方案 | Python Lark 完整方案 |
|---|---|---|
| **实现成本** | 1-2 天 | 3-5 天 |
| **语法覆盖** | 仅 @task + @depends_on + @parallel | 完整语法 (含 @conditional, 嵌套) |
| **错误信息** | 简陋 (行号 + 文本) | 精确 (行号+列号+期望/找到) |
| **AST 操作** | 文本行处理, 无真正 AST | 完整 AST, 可遍历/转换 |
| **缩进处理** | awk 难以处理缩进敏感语法 | Python 内置缩进感知 |
| **EBNF 匹配** | 手工实现模式匹配 | Lark 自动生成解析器 (from EBNF) |
| **循环依赖** | 需手写 DFS | 可复用 networkx 或手写 |
| **依赖** | 无 (内嵌 Shell) | Python3 + Lark |
| **维护成本** | 低 (简单但脆弱) | 中 (复杂但健壮) |
| **Skill 集成** | 直接 Bash 调用 | 需检查 Python 环境 |

#### 推荐策略: 双层方案

```
短期 (Phase 1): Shell 原型 — 快速验证 DSL 可用性
  - 支持 @plan, @task (含 body 字段), @depends_on, @after_all, @parallel
  - 输出 JSON Plan
  - 不做 @conditional 和嵌套语法
  - 使用 sed/awk 逐行解析

长期 (Phase 2): Python Lark 完整方案
  - 完整 EBNF 语法支持
  - 完整的 AST + 6-pass 编译管线
  - 精确错误报告
  - 条件分支 + HITL 完整支持

迁移路径: Phase 1 解析器 → 接口兼容 → Phase 2 解析器替换
          对外接口相同 (输入 .dsl → 输出 JSON Plan)
```

### 5.2 CLI 接口设计

```
parse-dsl — Multi-Agent Orchestrator DSL 编译器

用法:
  parse-dsl <file.dsl>                       # 编译 .dsl 文件输出 JSON Plan
  parse-dsl <file.dsl> --check               # 仅语法检查, 不输出 JSON
  parse-dsl <file.dsl> --taskcreate          # 输出 TaskCreate 调用序列
  parse-dsl <file.dsl> --ast                 # 输出 AST (调试用)
  parse-dsl <file.dsl> --verbose             # 详细输出 (含警告信息)
  parse-dsl <file.dsl> --output <file.json>  # 指定输出文件路径
  parse-dsl --help                           # 帮助信息

输出格式 (默认):
  JSON Plan (与设计.md §4 检查点格式兼容)

输出格式 (--taskcreate):
  JSON 数组, 每个元素为 TaskCreate / addBlockedBy 调用的描述

退出码:
  0  — 编译成功
  1  — 编译错误 (FATAL)
  2  — 语法警告 + 编译成功 (有 WARNING)
```

### 5.3 与现有 Skill 的集成

```
集成点 1: Step 3 替代方案
  当前: Coordinator 手写 JSON → TaskCreate 调用
  替换后:
    Coordinator 生成 .dsl 文本 (从 DAG 模板推理)
    → parse-dsl 编译为 JSON Plan
    → 从 JSON Plan 生成 TaskCreate 调用

集成点 2: Skill 触发路径
  /orchestrate: 用户输入 → Coordinator 拆解 → (生成 DSL → parse-dsl) → TaskCreate
  差异: 括号内为新增步骤, 前后流程不变

集成点 3: 检查点兼容
  parse-dsl 输出的 JSON Plan 结构与现有检查点兼容,
  可直接写入 ~/.claude/orchestrator/checkpoints/<id>.json

集成点 4: 文件目录
  ~/.claude/skills/multi-agent-orchestrator/
    ├── dsl/
    │   └── parse-dsl       ← 解析器脚本 (Shell or Python)
    ├── templates/
    │   └── *.dsl           ← DSL 模板 (可复用的 DAG 结构)
    └── examples/
        └── *.dsl           ← 示例 DSL 文件
```

### 5.4 Phase 1 Shell 原型架构

```
parse-dsl (Shell 实现):

  输入: .dsl 文件路径
  输出: STDOUT JSON Plan
  实现: awk 逐行解析 + 临时文件收集

  工作方式:
    1. 读取文件, 去除注释和空行
    2. 扫描 @plan → 提取计划名
    3. 扫描 @task → 进入任务收集模式
    4. 在任务体内匹配 描述:/角色:/模型:/输出: 字段
    5. 匹配 @depends_on / @after_all → 收集依赖
    6. 检测 @parallel → 标记任务组 (blockedBy=[])
    7. 匹配 @human_approval → 收集 HITL gate
    8. 依赖解析: 任务名 → task ID 映射
    9. 循环依赖检测: DFS (使用临时文件记录访问状态)
    10. 输出 JSON

  限制:
    - 不支持 @conditional
    - 缩进错误容忍度低
    - 错误信息有限
    - 不支持内联任务
```

### 5.5 Phase 2 Python 完整架构

```
项目结构:
  dsl-engine/
    ├── __init__.py            # 导出 compile() 入口
    ├── __main__.py            # CLI 入口 (python -m dsl-engine)
    ├── grammar.lark           # EBNF 语法文件 (Lark LALR)
    ├── lexer.py               # (可选) 自定义词法分析器
    ├── parser.py              # Lark 解析器工厂
    ├── ast.py                 # AST 节点类型定义 (dataclass)
    ├── passes/
    │   ├── __init__.py
    │   ├── pass1_registry.py  # 任务注册 + 映射表
    │   ├── pass2_deps.py      # 依赖解析
    │   ├── pass3_cycle.py     # 循环依赖检测 (DFS)
    │   ├── pass4_special.py   # 条件 + HITL 处理
    │   ├── pass5_bindings.py  # 角色 + 模型校验
    │   └── pass6_serialize.py # JSON 序列化
    ├── errors.py              # 错误类型定义 + 格式化
    └── cli.py                 # CLI 参数解析

核心依赖:
  - lark-parser (EBNF → LALR parser)
  - Python >= 3.10 (dataclass + match statement)

入口函数:
  def compile_dsl(source: str) -> CompileResult:
      """将 .dsl 源文本编译为 JSON Plan"""
      tree = parse(source)        # Stage 1
      plan = compile_ast(tree)    # Stage 2
      return CompileResult(
          success=True,
          plan=plan.json(),
          tasks=plan.to_task_create_sequence(),
          warnings=plan.warnings
      )
```

### 5.6 实现路线图

| 阶段 | 内容 | 预估工时 | 依赖 |
|---|---|---|---|
| **P0** | Phase 1 Shell 原型: @task + @depends_on + @parallel | 2 天 | — |
| **P0** | JSON Plan 输出与检查点兼容 | 0.5 天 | Phase 1 |
| **P0** | E001/E002/E004 错误检测 | 1 天 | Phase 1 |
| **P1** | Phase 2 Python Lark 迁移: 完整语法 | 3 天 | Lark 安装 |
| **P1** | @conditional + @human_approval 完整支持 | 2 天 | Phase 2 |
| **P1** | 6-pass 编译管线 | 1.5 天 | Phase 2 AST |
| **P1** | 精确错误报告 (行列定位 + 修复建议) | 1 天 | Phase 2 |
| **P2** | CLI 接口 (--check / --taskcreate / --ast) | 1 天 | Phase 2 |
| **P2** | IDE 集成 / VSCode 语法高亮 | 3 天 | Phase 2 |
| **P2** | DSL 模板库 + 示例 | 1 天 | Phase 2 |

---

## 6. 完整示例

### 6.1 场景: 用户认证系统开发

```
输入: "帮我实现用户认证系统，需要注册、登录、JWT中间件、密码重置四个模块"
```

### 6.2 .dsl 源文件

```dsl
# ============================================================
# 认证系统开发 DAG — orchestrator-auth-system.dsl
# ============================================================

@plan "用户认证系统开发"

# ── 第一阶段: 并行开发 (无依赖模块) ─────────────────
@parallel:
  @task "注册模块"
    描述: "实现用户注册功能，含邮箱验证和密码哈希存储"
    角色: developer
    模型: sonnet
    输出: "注册模块完整代码 + 单元测试"

  @task "登录模块"
    描述: "实现用户登录功能，含会话管理和 JWT 签发"
    角色: developer
    模型: sonnet
    输出: "登录模块完整代码 + 单元测试"

  @task "JWT中间件"
    描述: "实现 JWT 认证中间件，含 Token 验证和刷新"
    角色: developer
    模型: sonnet
    输出: "JWT 中间件代码 + 使用文档"

# ── 第二阶段: 依赖开发 ────────────────────────────
@task "密码重置"
  描述: "实现密码重置流程，含邮件发送和 Token 验证"
  角色: developer
  模型: sonnet
  输出: "密码重置模块代码 + 测试"
@depends_on("登录模块")

# ── 第三阶段: 集成测试 ─────────────────────────────
@task "集成测试"
  描述: "对所有模块进行集成测试，验证端到端流程"
  角色: qa
  模型: sonnet
  输出: "集成测试报告"
@after_all(["注册模块", "登录模块", "JWT中间件", "密码重置"])
@human_approval {
  问题: "集成测试已完成，请查看测试报告后决定是否进入代码审查"
  超时: 3600
}

# ── 第四阶段: 安全审查 (条件性) ──────────────────────
@conditional
  when: "集成测试.output.contains('CRITICAL_FAILURE')"
  then: @task "紧急修复" {
    描述: "修复集成测试发现的严重问题"
    角色: developer
    模型: opus
    输出: "修复后的代码 + 重新测试结果"
  }
  else: @task "代码审查" {
    描述: "审查全部代码质量和安全性"
    角色: reviewer
    模型: opus
    输出: "审查报告 + 修改建议"
  }
@human_approval {
  问题: "代码审查已完成，请确认是否合并代码"
}
```

### 6.3 AST (解析器 Stage 1 输出)

```json
{
  "kind": "document",
  "plan": {
    "kind": "plan",
    "name": "用户认证系统开发",
    "line": 5
  },
  "statements": [
    {
      "kind": "parallel_block",
      "line": 8,
      "tasks": [
        {
          "kind": "task",
          "name": "注册模块",
          "line": 9,
          "body": {
            "kind": "task_body",
            "description": "实现用户注册功能，含邮箱验证和密码哈希存储",
            "role": "developer",
            "model": "sonnet",
            "output": "注册模块完整代码 + 单元测试"
          },
          "deps": [],
          "hitl": null
        },
        {
          "kind": "task",
          "name": "登录模块",
          "line": 15,
          "body": {
            "description": "实现用户登录功能，含会话管理和 JWT 签发",
            "role": "developer",
            "model": "sonnet",
            "output": "登录模块完整代码 + 单元测试"
          },
          "deps": [],
          "hitl": null
        },
        {
          "kind": "task",
          "name": "JWT中间件",
          "line": 21,
          "body": {
            "description": "实现 JWT 认证中间件，含 Token 验证和刷新",
            "role": "developer",
            "model": "sonnet",
            "output": "JWT 中间件代码 + 使用文档"
          },
          "deps": [],
          "hitl": null
        }
      ]
    },
    {
      "kind": "task",
      "name": "密码重置",
      "line": 28,
      "body": {
        "description": "实现密码重置流程，含邮件发送和 Token 验证",
        "role": "developer",
        "model": "sonnet",
        "output": "密码重置模块代码 + 测试"
      },
      "deps": [
        {
          "kind": "dep_single",
          "target": "登录模块",
          "line": 32
        }
      ],
      "hitl": null
    },
    {
      "kind": "task",
      "name": "集成测试",
      "line": 35,
      "body": {
        "description": "对所有模块进行集成测试，验证端到端流程",
        "role": "qa",
        "model": "sonnet",
        "output": "集成测试报告"
      },
      "deps": [
        {
          "kind": "dep_all",
          "targets": ["注册模块", "登录模块", "JWT中间件", "密码重置"],
          "line": 40
        }
      ],
      "hitl": {
        "kind": "hitl_gate",
        "question": "集成测试已完成，请查看测试报告后决定是否进入代码审查",
        "timeout": 3600,
        "line": 41
      }
    },
    {
      "kind": "conditional",
      "line": 47,
      "condition": "集成测试.output.contains('CRITICAL_FAILURE')",
      "thenBranch": {
        "kind": "inline_task",
        "name": "紧急修复",
        "fields": {
          "描述": "修复集成测试发现的严重问题",
          "角色": "developer",
          "模型": "opus",
          "输出": "修复后的代码 + 重新测试结果"
        }
      },
      "elseBranch": {
        "kind": "inline_task",
        "name": "代码审查",
        "fields": {
          "描述": "审查全部代码质量和安全性",
          "角色": "reviewer",
          "模型": "opus",
          "输出": "审查报告 + 修改建议"
        }
      }
    },
    {
      "kind": "task",
      "name": "文档与部署",
      "line": 60,
      "body": {
        "description": "生成 API 文档和部署说明",
        "role": "writer",
        "model": "sonnet",
        "output": "API 文档 + Docker Compose 配置"
      },
      "deps": [],
      "hitl": {
        "kind": "hitl_gate",
        "question": "代码审查已完成，请确认是否合并代码",
        "timeout": null,
        "line": 63
      }
    }
  ]
}
```

### 6.4 JSON Plan (编译器 Stage 2 输出)

```json
{
  "plan": "用户认证系统开发",
  "sop": "software-dev",
  "checkpoint_mode": "full",
  "tasks": [
    {
      "id": "1",
      "subject": "注册模块",
      "description": "实现用户注册功能，含邮箱验证和密码哈希存储",
      "role": "developer",
      "model": "sonnet",
      "output_format": "注册模块完整代码 + 单元测试",
      "blockedBy": [],
      "status": "pending",
      "sub_steps": [
        { "step_id": "1.1", "description": "分析需求与接口设计", "status": "pending" },
        { "step_id": "1.2", "description": "编写核心逻辑", "status": "pending" },
        { "step_id": "1.3", "description": "编写单元测试", "status": "pending" }
      ]
    },
    {
      "id": "2",
      "subject": "登录模块",
      "description": "实现用户登录功能，含会话管理和 JWT 签发",
      "role": "developer",
      "model": "sonnet",
      "output_format": "登录模块完整代码 + 单元测试",
      "blockedBy": [],
      "status": "pending",
      "sub_steps": [
        { "step_id": "2.1", "description": "分析需求与接口设计", "status": "pending" },
        { "step_id": "2.2", "description": "编写核心逻辑", "status": "pending" },
        { "step_id": "2.3", "description": "编写单元测试", "status": "pending" }
      ]
    },
    {
      "id": "3",
      "subject": "JWT中间件",
      "description": "实现 JWT 认证中间件，含 Token 验证和刷新",
      "role": "developer",
      "model": "sonnet",
      "output_format": "JWT 中间件代码 + 使用文档",
      "blockedBy": [],
      "status": "pending",
      "sub_steps": [
        { "step_id": "3.1", "description": "实现 Token 生成与验证", "status": "pending" },
        { "step_id": "3.2", "description": "实现 Refresh Token", "status": "pending" },
        { "step_id": "3.3", "description": "编写使用文档", "status": "pending" }
      ]
    },
    {
      "id": "4",
      "subject": "密码重置",
      "description": "实现密码重置流程，含邮件发送和 Token 验证",
      "role": "developer",
      "model": "sonnet",
      "output_format": "密码重置模块代码 + 测试",
      "blockedBy": ["2"],
      "status": "pending",
      "sub_steps": [
        { "step_id": "4.1", "description": "实现密码重置 Token 生成", "status": "pending" },
        { "step_id": "4.2", "description": "实现邮件发送逻辑", "status": "pending" },
        { "step_id": "4.3", "description": "编写测试", "status": "pending" }
      ]
    },
    {
      "id": "5",
      "subject": "集成测试",
      "description": "对所有模块进行集成测试，验证端到端流程",
      "role": "qa",
      "model": "sonnet",
      "output_format": "集成测试报告",
      "blockedBy": ["1", "2", "3", "4"],
      "status": "pending",
      "sub_steps": [
        { "step_id": "5.1", "description": "搭建测试环境", "status": "pending" },
        { "step_id": "5.2", "description": "执行端到端测试", "status": "pending" },
        { "step_id": "5.3", "description": "生成测试报告", "status": "pending" }
      ]
    },
    {
      "id": "6",
      "subject": "$conditional_决策路由器",
      "description": "运行时判断: 集成测试输出是否包含 CRITICAL_FAILURE",
      "role": "coordinator",
      "model": "opus",
      "blockedBy": ["5"],
      "is_conditional_router": true,
      "condition": "集成测试.output.contains('CRITICAL_FAILURE')"
    },
    {
      "id": "7",
      "subject": "紧急修复",
      "description": "修复集成测试发现的严重问题",
      "role": "developer",
      "model": "opus",
      "output_format": "修复后的代码 + 重新测试结果",
      "blockedBy": ["6"],
      "conditional_branch": "then",
      "status": "pending"
    },
    {
      "id": "8",
      "subject": "代码审查",
      "description": "审查全部代码质量和安全性",
      "role": "reviewer",
      "model": "opus",
      "output_format": "审查报告 + 修改建议",
      "blockedBy": ["6"],
      "conditional_branch": "else",
      "status": "pending"
    },
    {
      "id": "9",
      "subject": "文档与部署",
      "description": "生成 API 文档和部署说明",
      "role": "writer",
      "model": "sonnet",
      "output_format": "API 文档 + Docker Compose 配置",
      "blockedBy": ["7", "8"],
      "status": "pending"
    }
  ],
  "conditions": [
    {
      "router_task_id": "6",
      "condition_expr": "集成测试.output.contains('CRITICAL_FAILURE')",
      "then_task_ids": ["7"],
      "else_task_ids": ["8"]
    }
  ],
  "hitl_gates": [
    {
      "gate_id": "approval-5",
      "after_task": "5",
      "mode": "approval",
      "question": "集成测试已完成，请查看测试报告后决定是否进入代码审查",
      "timeout": 3600,
      "default_action": "pause",
      "status": "pending"
    },
    {
      "gate_id": "approval-8",
      "after_task": "8",
      "mode": "approval",
      "question": "代码审查已完成，请确认是否合并代码",
      "timeout": null,
      "default_action": "pause",
      "status": "pending"
    }
  ]
}
```

### 6.5 DAG 可视化

```
                         ┌─────────────────┐
                         │  @plan "认证系统"  │
                         └─────────────────┘
                                  │
           ┌──────────────────────┼──────────────────────┐
           │                      │                      │
           ▼                      ▼                      ▼
    ┌─────────────┐      ┌─────────────┐      ┌─────────────┐
    │  Task 1     │      │  Task 2     │      │  Task 3     │
    │  注册模块    │      │  登录模块    │      │  JWT中间件  │
    │  blocked: [] │      │  blocked: [] │      │  blocked: [] │
    └─────────────┘      └──────┬──────┘      └─────────────┘
                                │ @depends_on
                                ▼
                         ┌─────────────┐
                         │  Task 4     │
                         │  密码重置    │
                         │  blocked: [2]│
                         └─────────────┘
                                │
           ┌────────────────────┼────────────────────┐
           │  @after_all        │                     │
           ▼                    ▼                     ▼
    ┌─────────────────────────────────────────────────────┐
    │                  Task 5  集成测试                     │
    │               blockedBy: [1, 2, 3, 4]               │
    │                  [HITL Gate: 审批门]                  │
    └────────────────────────┬────────────────────────────┘
                             │
                             ▼
                    ┌─────────────────┐
                    │  Task 6 决策路由器 │
                    │  @conditional    │
                    │  blocked: [5]    │
                    └────────┬────────┘
                             │
              ┌──────────────┼──────────────┐
              │ true         │              │ false
              ▼              │              ▼
    ┌────────────────┐      │    ┌────────────────┐
    │  Task 7        │      │    │  Task 8         │
    │  紧急修复       │      │    │  代码审查        │
    │  blocked: [6]  │      │    │  blocked: [6]   │
    │  (then 分支)   │      │    │  (else 分支)     │
    └────────────────┘      │    └───────┬────────┘
              └──────────────┼───────────┘
                             │
                             ▼
                    ┌─────────────────┐
                    │  Task 9          │
                    │  文档与部署       │
                    │  blocked: [7,8]  │
                    │  [HITL Gate: 合并确认]│
                    └─────────────────┘
```

### 6.6 TaskCreate 调用序列

```json
[
  // ── Pass 1: 并行模块 (blockedBy=[]) ──
  {
    "action": "TaskCreate",
    "params": {
      "id": "1",
      "subject": "注册模块",
      "prompt": "[Role: 高级软件工程师]\n[Goal: 编写清晰、可维护、充分测试的代码]\n[Backstory: ...]\n---\n实现用户注册功能，含邮箱验证和密码哈希存储\n输出格式: 注册模块完整代码 + 单元测试",
      "model": "sonnet",
      "subagent_type": "general-purpose",
      "run_in_background": true
    }
  },
  {
    "action": "TaskCreate",
    "params": {
      "id": "2",
      "subject": "登录模块",
      "prompt": "[Role: 高级软件工程师]\n[Goal: ...]\n[Backstory: ...]\n---\n实现用户登录功能，含会话管理和 JWT 签发\n输出格式: 登录模块完整代码 + 单元测试",
      "model": "sonnet",
      "subagent_type": "general-purpose",
      "run_in_background": true
    }
  },
  {
    "action": "TaskCreate",
    "params": {
      "id": "3",
      "subject": "JWT中间件",
      "prompt": "[Role: 高级软件工程师]\n---\n实现 JWT 认证中间件，含 Token 验证和刷新\n输出格式: JWT 中间件代码 + 使用文档",
      "model": "sonnet",
      "subagent_type": "general-purpose",
      "run_in_background": true
    }
  },

  // ── Pass 2: 依赖任务 ──
  {
    "action": "TaskCreate",
    "params": {
      "id": "4",
      "subject": "密码重置",
      "prompt": "上游 Task 2 (登录模块) 输出已准备好。\n---\n实现密码重置流程，含邮件发送和 Token 验证\n输出格式: 密码重置模块代码 + 测试",
      "model": "sonnet",
      "subagent_type": "general-purpose",
      "run_in_background": true
    }
  },
  {
    "action": "addBlockedBy",
    "params": { "id": "4", "blockedBy": ["2"] }
  },

  // ── Pass 3: 集成测试 ──
  {
    "action": "TaskCreate",
    "params": {
      "id": "5",
      "subject": "集成测试",
      "prompt": "上游模块: 注册模块, 登录模块, JWT中间件, 密码重置\n---\n对所有模块进行集成测试，验证端到端流程\n输出格式: 集成测试报告",
      "model": "sonnet",
      "subagent_type": "general-purpose",
      "run_in_background": true
    }
  },
  {
    "action": "addBlockedBy",
    "params": { "id": "5", "blockedBy": ["1", "2", "3", "4"] }
  },

  // ── Pass 4: 条件分支路由器 ──
  {
    "action": "TaskCreate",
    "params": {
      "id": "6",
      "subject": "$conditional_决策路由器",
      "prompt": "请在 Task 5 (集成测试) 完成后，分析其输出。\n如果输出包含 'CRITICAL_FAILURE'，请解锁 Task 7 (紧急修复)。\n否则，解锁 Task 8 (代码审查)。",
      "model": "opus",
      "subagent_type": "general-purpose",
      "run_in_background": false
    }
  },
  {
    "action": "addBlockedBy",
    "params": { "id": "6", "blockedBy": ["5"] }
  },

  // ── Pass 4b: 条件分支 (then) ──
  {
    "action": "TaskCreate",
    "params": {
      "id": "7",
      "subject": "紧急修复",
      "prompt": "[Role: 高级软件工程师]\n---\n修复集成测试发现的严重问题\n输出格式: 修复后的代码 + 重新测试结果",
      "model": "opus",
      "subagent_type": "general-purpose",
      "run_in_background": true
    }
  },
  {
    "action": "addBlockedBy",
    "params": { "id": "7", "blockedBy": ["6"] }
  },

  // ── Pass 4c: 条件分支 (else) ──
  {
    "action": "TaskCreate",
    "params": {
      "id": "8",
      "subject": "代码审查",
      "prompt": "[Role: 代码审查专家]\n[Goal: 发现代码中的逻辑缺陷、安全隐患和风格问题]\n[Backstory: ...]\n---\n审查全部代码质量和安全性\n输出格式: 审查报告 + 修改建议",
      "model": "opus",
      "subagent_type": "general-purpose",
      "run_in_background": true
    }
  },
  {
    "action": "addBlockedBy",
    "params": { "id": "8", "blockedBy": ["6"] }
  },

  // ── Pass 4d: HITL Gate 注册 (关联 Task 5) ──
  {
    "action": "registerGate",
    "params": {
      "gate_id": "approval-5",
      "after_task": "5",
      "mode": "approval",
      "question": "集成测试已完成，请查看测试报告后决定是否进入代码审查",
      "timeout": 3600,
      "default_action": "pause"
    }
  },

  // ── Pass 5: 最终任务 ──
  {
    "action": "TaskCreate",
    "params": {
      "id": "9",
      "subject": "文档与部署",
      "prompt": "上游条件分支已完成。\n---\n生成 API 文档和部署说明\n输出格式: API 文档 + Docker Compose 配置",
      "model": "sonnet",
      "subagent_type": "general-purpose",
      "run_in_background": true
    }
  },
  {
    "action": "addBlockedBy",
    "params": { "id": "9", "blockedBy": ["7", "8"] }
  },

  // ── Pass 5b: HITL Gate 注册 (关联 Task 8) ──
  {
    "action": "registerGate",
    "params": {
      "gate_id": "approval-8",
      "after_task": "8",
      "mode": "approval",
      "question": "代码审查已完成，请确认是否合并代码",
      "default_action": "pause"
    }
  }
]
```

### 6.7 执行流程时序

```
时序:

    t=0s     Task 1,2,3 同时启动           (并行开发)
             ├── Agent(注册模块)
             ├── Agent(登录模块)
             └── Agent(JWT中间件)

    t=30s    Task 1,3 完成
    t=45s    Task 2 完成 → Task 4 解锁     (依赖Task 2)
             ├── Agent(密码重置)

    t=75s    Task 4 完成 → Task 5 解锁     (@after_all 全部完成)
             ├── Agent(集成测试)

    t=105s   Task 5 完成
             │
             ├── [HITL Gate] 暂停          (等待用户审批)
             │    "集成测试已完成，请查看报告后决定是否进入代码审查"
             │   用户: "批准，继续"
             │
             ├── Task 6 启动               (条件路由器)
             │   分析 Task 5 输出:
             │   - contains("CRITICAL_FAILURE")? → true
             │   - 解锁 Task 7 (紧急修复)
             │   - Task 8 保持 blocked (标记为 skipped)

    t=110s   Task 6 完成
    t=115s   Task 7 启动 (紧急修复, 1个retry)
    t=175s   Task 7 完成
             │
             ├── Task 9 解锁               (文档与部署)
             ├── Agent(文档与部署)

    t=205s   Task 9 完成
             │
             ├── [HITL Gate] 暂停          (确认合并)
             │   "代码审查已完成，请确认是否合并代码"
             │   用户: "确认合并"
             │
             ├── Coordinator 汇总结果
             └── 输出最终交付物
```

---

*本文档定义 Multi-Agent Orchestrator Skill 的 DSL 解析引擎完整设计。与 design.md §12 (声明式任务依赖 DSL) 和 SKILL.md Step 3 (TaskCreate 生成) 形成配套规范。实现时建议从 Phase 1 Shell 原型开始，逐步过渡到 Phase 2 Python 完整方案。*
