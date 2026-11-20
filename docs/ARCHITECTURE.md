# 架构说明

这份文档记录手机版怎么拆、为什么这么拆，以及和桌面版（`deepseek-harness@0.2.2-rc.5`）
的对应关系。改代码前先看这里能少踩一些坑。

## 1. 总体取舍

桌面版是 Electron + Node 的组合，能力来自「本地进程 + 插件系统」：shell、文件、
子代理、MCP、工作流都建立在能起子进程的前提上。手机上没有这个前提，所以移植策略是：

1. **保留协议与交互语义**，丢掉平台能力。
   线上协议（Messages 兼容端点 + SSE 事件）与桌面版逐字段对齐；思考过程、工具卡片、
   目标模式这些用户可感知的交互也照搬。
2. **用网络工具替代本地工具**。
   桌面版最强的工具是 shell；手机端换成 `web_search` / `web_fetch`，这是手机上唯一
   能真正扩展模型信息面的手段。
3. **一层一层剥开，不让 UI 知道协议**。
   UI 只认识「渲染视图模型」，协议细节封在 service 层。

## 2. 分层

```
pages/Index.ets            应用壳：编排会话、调用 agent、挂载 sheet      (.ets)
   │
   ├── view/*              纯展示组件（消息、工具卡、Markdown、输入栏、sheet）  (.ets)
   ├── model/Render.ts     会话日志 → 有序渲染视图模型                      (.ts)
   │
   └── service/*           能力层                                          (.ts)
        ├── AgentLoop     一轮对话的驱动者
        ├── LlmClient     HTTP + SSE
        ├── Tools         工具执行
        ├── Prompt        系统提示词 / 工具 schema
        ├── SessionStore  持久化 + 搜索
        ├── SettingsService / SecretService / AppContext
        └── ImageService / SpeechService / WebTool / TitleService
```

依赖方向是单向的：`view → model → service → common`，反向依赖只在
`service/SessionStore` 写 AppStorage 通知列表刷新这一处（`bumpRevision`），
属于刻意保留的广播通道。

### 文件扩展名约定

| 扩展名 | 放什么 | 判定标准 |
| --- | --- | --- |
| `.ets` | 声明式 UI 与 Ability | 用到 `@Component` / `struct` / `@State` / `@Entry`，或由 `module.json5` 直接引用 |
| `.ts` | 纯逻辑 | 其余全部：模型、协议、存储、工具、提示词、i18n 文本表 |

ArkTS 编译器两种都收，但 `.ets` 是唯一能承载 ArkUI 装饰器的格式。把逻辑放 `.ts` 有三个好处：
逻辑可以脱离 UI 单独推理、`node --experimental-strip-types` 能直接跑测试、GitHub 的语言统计也能
正确显示（它没有 `.ets` 的语法定义，见 `.gitattributes` 里的映射说明）。

比例大致是 11 个 `.ets`（UI）对 31 个 `.ts`（逻辑）。

## 3. 一轮对话的数据流

```
用户点发送
  │
  ├─ Index.send()            追加 user 消息到 session.messages
  │                          取 API Key（Asset Store）
  │                          建 CancelToken
  │
  ├─ AgentRuntime.run()      ┌─ 循环开始
  │   ├─ buildRequest()      │   buildWireMessages() 把日志转成 wire messages
  │   │                      │   buildSystemPrompt() 注入环境、工具策略、待办、目标
  │   ├─ LlmClient.stream()  │   POST /v1/messages，SSE 逐行解析
  │   │      └─ onEvent ─────┼──► AgentEvents（phase / text / reasoning / tool-delta）
  │   ├─ commit assistant    │   把拼好的块写回 session.messages，持久化
  │   ├─ 有 tool_call?       │
  │   │   ├─ 是 → ToolRunner.execute() 逐个执行
  │   │   │        追加 role=tool 消息（含 toolCallId），持久化
  │   │   │        下一轮
  │   │   └─ 否 → 检查 goal 是否要自动续跑
  │   │             ├─ 是 → 轮次 +1，注入 Round directive，继续
  │   │             └─ 否 → 结束
  │   └─ 循环结束
  │
  └─ Index 收尾               清空 streaming 状态、重建渲染列表、可选生成标题
```

`AgentRuntime` 不碰任何 UI：它只通过 `AgentEvents` 上报进度。这样聊天页可以把流式
文本放在独立字段里，而不是重建整个消息列表。

### 状态字段的分工

| 位置 | 内容 | 为什么 |
| --- | --- | --- |
| `Index.items` | 已提交消息的渲染模型 | 只在消息提交时重建 |
| `Index.liveText` / `liveReasoning` | 正在流式输出的文本 | 逐 token 更新，只有这一处重渲染 |
| `Index.liveTools` | 正在流式拼 JSON 的工具调用 | 同上 |
| `AppStorage` | 语言、主题、调色板、会话版本号 | 跨组件广播 |

## 4. 协议映射

请求体字段与上游 `packages/llm/llm-deepseek/src/serialize.ts` 一一对应：

| 本地 | 线上 | 备注 |
| --- | --- | --- |
| `reasoningEffort` | `thinking.type` + `output_config.effort` | `off` → `thinking.type=disabled` 且不发 `output_config` |
| 工具声明 | `tools[].{name,description,input_schema}` | 由 `Prompt.toolDefs()` 提供 JSON Schema |
| 图片附件 | `image` 块，`source.type=base64` | 上游优先 Files API，手机端用内联 base64（官方回退路径） |
| 文本 | `text` 块 | 空文本块不发送 |
| 思考 | `thinking` 块 + `signature` | 历史里原样带回 |
| 工具调用 | `tool_use` 块 | `input` 必须是对象；坏 JSON 历史降级为 `{}` |
| 工具结果 | `tool_result` 块 | 放回 `user` 轮，必须紧跟对应的 `tool_use` |

### 完整性保证

`buildWireMessages()` 在返回前做一次校验：任何没有对应 `tool_result` 的 `tool_use`
都会补一个本地结果（`Cancelled before completion.`，`is_error: true`）。这解决了
「用户在工具执行到一半时点停止」导致的非法历史问题 —— 不补的话下一次请求会直接被
服务端拒掉。

### SSE 解析

`LlmClient` 按行解析，而不是按 `\n\n` 分帧：Anthropic 的 `data:` 负载是单行 JSON，
按行处理对半包更稳。事件语义照抄 `translate.ts`：

- `message_start` 里取首次 usage
- `content_block_start` → 建块，`text`/`thinking` 若自带内容立即吐 delta，`tool_use` 先吐一条空 delta 表明身份
- `content_block_delta` → `text_delta` / `thinking_delta` / `signature_delta` / `input_json_delta`
- `content_block_stop` → 落最终块（工具调用此时把累积的 JSON 定稿）
- `message_delta` → `stop_reason`（`refusal` 单独记录）
- `message_stop` → 先 usage 后 finish；`refusal` 时改抛 `CONTENT_REFUSED`

## 5. 持久化

```
<files>/sessions/<sessionId>.json    一个会话一个文档
<files>/sessions/index.json          列表索引（标题、时间、预览、目标状态）
<files>/images/<id>.<ext>            图片附件副本
```

- 写入走「临时文件 + rename」，进程被杀不会留下半截文档。
- 图片只存路径，`base64` 在构建请求时才生成 —— 否则一段带截图的对话会把 JSON 撑到
  几 MB，且每次保存都在做无用编码。
- 索引损坏会自动扫描目录重建（`rebuildIndex`）。
- 搜索先匹配标题，再逐会话匹配正文，命中给出上下文片段。
- 每个会话的正文会**压平成一段纯文本并缓存**（含小写副本，上限 64 个会话，LRU 淘汰）。
  早期实现每敲一个字符就把所有 JSON 解析一遍，现在重复搜索只是字符串扫描；
  保存 / 删除会话时对应缓存条目失效。

## 6. 目标模式

`session.goal` 是一个持久化的状态机：`active → paused / complete / blocked`。

- 每轮回复正常结束（没有工具调用、不是 `max_tokens` 截断）后，`maybeContinueGoal()`
  会把 `rounds` 加一，并在系统提示词里追加一段 Round directive，让模型接着干。
- 达到 `maxRounds` 自动转 `paused`，避免无限消耗。
- 模型自己可以通过 `update_goal` 把目标标记为 `complete` 或 `blocked`。
- 目标的推进记录以 `role=system` 消息写进会话，UI 渲染成居中的小灰条；这些消息
  不会进入请求历史（目标状态走系统提示词）。

## 7. 长期记忆

上下文窗口是模型侧固定的 1,048,576 tokens，客户端改不了。所以「记得住」不是靠更大的窗口，
而是分层：**近期内容进上下文，久远内容进本地存档，需要时再取回**。

| 层 | 载体 | 进上下文的方式 | 容量 |
| --- | --- | --- | --- |
| 工作记忆 | `session.messages` | 原样序列化发送 | 受窗口限制 |
| 情节记忆 | `sessions/*.json` | 模型调 `search_history` → `read_session` | 无上限（磁盘） |
| 语义记忆 | `memory.json` | 每轮按相关度注入 ≤8 条 / ≤1200 字符 | 300 条，超出淘汰最旧非置顶 |
| 归档 | 原始文档 | 不发送 | 无上限 |

### 语义记忆

`MemoryStore` 只存**一句话事实**（项目、偏好、长期约定），不存任务细节——后者属于工作记忆。
写入时把空白归一化后查重，重复内容只更新时间戳，避免模型反复记同一件事。

注入走 `Prompt.buildSystemPrompt()`：取当前用户消息，用 `TextRank` 打分，置顶条目优先，
再按分数补齐，超出字符预算就截断。预算是硬的，防止「捡了记忆、挤掉当前问题」。

设置页有一张「长期记忆」卡片：列出条目、可置顶、可单条删除、可清空全部。
模型侧的 `remember` / `recall` / `forget` 与这张卡片读写同一个 `memory.json`，
所以用户在界面上做的修改立即影响下一轮的注入。

### 检索打分

没有 embedding 模型，召回靠三层打分（`common/TextRank.ts` 的 `scoreWithKeywords`）：

| 层 | 做法 | 解决什么 |
| --- | --- | --- |
| 字面 | 中文二元组、拉丁词，算「查询命中比例 ÷ 文本长度阻尼」 | 「我上次说的那个项目」 |
| 同义词 | 记忆写入时一并存下的 2–4 个近义词，单独算分后再乘 1.2 | 「健身」↔「锻炼」这类换词 |
| 模糊 | 字符二元组的 Dice 系数，低于 0.4 不计 | 错字、语序颠倒、词形变化 |

**同义词层是刻意设计出来的，不是补丁**：真正的向量检索需要一个量化过的 embedding 模型
（几十 MB）和转换工具链，这个项目没有随包分发模型，也没法在 CI 里验证模型加载，
写出来只会是无法验证的死代码。所以换个思路——**让写记忆的那个模型顺便把它能接受的
近义词一起写下来**。同一次请求、零额外开销、完全离线，对个人助手的场景覆盖已经够用。

真要做向量检索，接入点很干净：把 `scoreWithKeywords()` 换成向量余弦相似度即可，
`MemoryStore.relevant()` / `search()` 的签名不用动。届时向量应当在写入时算好存进
`memory.json`（新增 `vector` 字段），查询时只算一次查询向量，避免每轮注入路径上出现网络等待。

### 向量插槽（已预留，未启用）

代码里已经留好了位置，默认是**惰性**的：没有注册 provider 时，整条路径返回 0，行为与纯词法召回完全一致。

| 位置 | 作用 |
| --- | --- |
| `service/Embedding.ts` | `EmbeddingProvider` 接口 + `EmbeddingRegistry` 注册表，默认空 |
| `MemoryEntry.vector` | 记忆的向量字段，随 `memory.json` 持久化，缺失表示该条只能词法召回 |
| `common/Vector.ts` | `dot` / `norm` / `cosine`（映射到 0–1）/ `unit` / `toVector` |
| `combineScore()` | 词法分与语义分的合并规则：语义 ≥0.62 且高于词法才采用 |
| `MemoryStore.setQueryVector()` | 每轮开始前注入当前问题的查询向量 |
| `MemoryStore.refreshVectors()` | 批量补齐缺失向量，单次最多 32 条 |
| `Index.send()` | 已接好：provider 不存在就清空向量，存在就先算查询向量再进循环 |

启用只需要三步，其他代码都不用动：

1. 实现 `EmbeddingProvider`（HTTP embeddings 端点，或用 MindSpore Lite 包一个本地模型）
2. 启动时 `EmbeddingRegistry.register(provider)`
3. 调用一次 `MemoryStore.refreshVectors()` 回填历史记忆

阈值 0.62 是刻意留高的一版：无关句子在常见 embedding 模型上余弦也常在 0.5 附近，
门槛低了会把噪音注入每一轮。真正接入时应当用自己模型的实际分布重新校准这个数。

### 主动 vs 被动

- **主动**：`search_history` / `read_session` 由模型判断「这事以前聊过」时调用，准确率高
- **被动**：语义记忆每轮自动注入，保证基础背景不丢

两者互补：只做被动注入会漏，只做主动检索则依赖模型自觉。

### 作用域与删除

记忆是**全局共享**的：`memory.json` 只有一份，注入时不按会话过滤——这正是「换会话还记得」的来源。
`sourceSession` 只记录出处，不参与检索。

为了避免个别对话污染全局记忆，留了两个控制点：

| 控制点 | 行为 |
| --- | --- |
| `ChatSession.memoryExcluded` | 私密会话：跳过自动提炼，`remember` 工具直接拒绝（返回说明给模型），列表显示「私密」标记 |
| `MemoryStore.removeFromSession()` | 删除会话时若存在来源记忆，二次询问「保留 / 一并删除」 |

私密开关只影响**以后**的提炼；之前已经提炼出的记忆不会自动消失，需要用户自己决定——
静默删除用户数据比留下一条可删的记忆更糟。

### 自动提炼

只靠模型自愿调 `remember`，实际很难积累。所以每轮结束后还有一个旁路的提炼：

1. 会话里的 `memoryUpto` 记录已处理到第几条消息；未处理的新消息不足 4 条就直接跳过
2. 把这段窗口压成 `User:` / `Assistant:` 文本（`model/Transcript.ts`，工具与系统提示不参与）
3. 用一次小请求（`thinking: disabled`、`max_tokens: 400`）要求返回 JSON 数组，
   并把已有的前 20 条记忆一起给它，要求不要重复
4. `common/FactParse.ts` 从回复里抠出数组：容忍代码围栏、前后废话、坏 JSON、非字符串项
5. 逐条交给 `MemoryStore.add`（自己去重），然后把 `memoryUpto` 推进到当前消息数

几个刻意的决定：

- **失败也推进水位**：否则接口一次抖动就会让每一轮都重试，白烧 token
- **不阻塞对话**：提炼在回复已提交、已落盘之后才发起，失败了最多丢一条记忆
- **会话切换保护**：只在用户仍停留在被提炼的会话时才落盘，避免写错对象
- **可关闭**：设置里的「自动提炼长期记忆」直接短路整条路径

## 8. 错误处理

错误码沿用上游的稳定词表（`AUTH` / `QUOTA` / `RATE_LIMIT` / `INVALID_REQUEST` /
`SERVER` / `TIMEOUT` / `ABORTED` / `CONTENT_REFUSED` / `STREAM_CLOSED` …），
`common/Errors.ts` 负责映射到本地化文案。

设计原则：**任何一次失败都要以一条 `tool_result` 或一条可见错误收尾**，绝不留下让
历史变非法的中间态。

## 9. 主题与国际化

- `common/Theme.ts` 定义一套 `Palette` 接口和明暗两份实例；组件通过
  `@StorageLink(KEY_PALETTE)` 读当前调色板，不读全局单例，预览和测试都方便。
- 文案用 `i18n/Strings.ts` 的扁平表；缺 key 会直接显示 key 本身，方便开发时发现。
- 语言变化会写回 `AppStorage`，所有 `@StorageLink(KEY_LANG)` 的组件同帧刷新。

## 10. 有意为之的简化

| 简化 | 原因 | 影响 |
| --- | --- | --- |
| 不做自动上下文压缩 | 需要额外一次模型调用，且手机上更该让用户主动管理 | 上下文满时报明确错误 |
| 图片走内联 base64 | Files API 需要额外上传与配额管理 | 单请求体积略大 |
| 搜索解析 HTML | 无内置搜索 API，且不强制用户配第三方 Key | 引擎改版时可能失效 |
| 不用关系型数据库 | 会话是文档型数据，文件足够了 | 数据量大时列表靠索引，不扫全表 |
| 单 bindSheet 复用三个面板 | ArkUI 一个组件只能绑一个 sheet | 切换面板时复用同一容器 |
