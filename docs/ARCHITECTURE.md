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
pages/Index.ets            应用壳：编排会话、调用 agent、挂载 sheet
   │
   ├── view/*              纯展示组件（消息、工具卡、Markdown、输入栏、sheet）
   ├── model/Render.ets    会话日志 → 有序渲染视图模型
   │
   └── service/*           能力层
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

## 6. 目标模式

`session.goal` 是一个持久化的状态机：`active → paused / complete / blocked`。

- 每轮回复正常结束（没有工具调用、不是 `max_tokens` 截断）后，`maybeContinueGoal()`
  会把 `rounds` 加一，并在系统提示词里追加一段 Round directive，让模型接着干。
- 达到 `maxRounds` 自动转 `paused`，避免无限消耗。
- 模型自己可以通过 `update_goal` 把目标标记为 `complete` 或 `blocked`。
- 目标的推进记录以 `role=system` 消息写进会话，UI 渲染成居中的小灰条；这些消息
  不会进入请求历史（目标状态走系统提示词）。

## 7. 错误处理

错误码沿用上游的稳定词表（`AUTH` / `QUOTA` / `RATE_LIMIT` / `INVALID_REQUEST` /
`SERVER` / `TIMEOUT` / `ABORTED` / `CONTENT_REFUSED` / `STREAM_CLOSED` …），
`common/Errors.ets` 负责映射到本地化文案。

设计原则：**任何一次失败都要以一条 `tool_result` 或一条可见错误收尾**，绝不留下让
历史变非法的中间态。

## 8. 主题与国际化

- `common/Theme.ets` 定义一套 `Palette` 接口和明暗两份实例；组件通过
  `@StorageLink(KEY_PALETTE)` 读当前调色板，不读全局单例，预览和测试都方便。
- 文案用 `i18n/Strings.ets` 的扁平表；缺 key 会直接显示 key 本身，方便开发时发现。
- 语言变化会写回 `AppStorage`，所有 `@StorageLink(KEY_LANG)` 的组件同帧刷新。

## 9. 有意为之的简化

| 简化 | 原因 | 影响 |
| --- | --- | --- |
| 不做自动上下文压缩 | 需要额外一次模型调用，且手机上更该让用户主动管理 | 上下文满时报明确错误 |
| 图片走内联 base64 | Files API 需要额外上传与配额管理 | 单请求体积略大 |
| 搜索解析 HTML | 无内置搜索 API，且不强制用户配第三方 Key | 引擎改版时可能失效 |
| 不用关系型数据库 | 会话是文档型数据，文件足够了 | 数据量大时列表靠索引，不扫全表 |
| 单 bindSheet 复用三个面板 | ArkUI 一个组件只能绑一个 sheet | 切换面板时复用同一容器 |
