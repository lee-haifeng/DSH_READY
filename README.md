# DSH Mobile

把 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 桌面版搬到鸿蒙手机上的原生客户端。
自用为主，顺手开源。

- 纯 ArkTS / ArkUI，无 WebView、无第三方运行时
- 直接对接 DeepSeek 官方 Messages 兼容端点，与桌面版同一套线上协议
- 不收集任何数据；API Key 存在系统凭据库

> 非官方项目。上游行为以 `deepseek-harness@0.2.2-rc.5` 为基准。

---

## 功能对照

| 能力 | 桌面版 | 手机版 | 说明 |
| --- | --- | --- | --- |
| 流式回复 | ✅ | ✅ | 同一套 SSE 事件语义 |
| 推理过程（thinking） | ✅ | ✅ | 可折叠，实时显示 |
| 工具调用卡片 | ✅ | ✅ | 折叠态一行摘要，展开看参数与结果 |
| 多会话 + 历史 | ✅ | ✅ | 每个会话一个 JSON 文档，原子写入 |
| 会话搜索 | ✅ | ✅ | 标题 + 全文匹配，命中片段高亮 |
| 自动生成标题 | ✅ | ✅ | 首轮对话后异步生成，失败静默 |
| 目标模式（goal） | ✅ | ✅ | 多轮自动续跑、轮次上限、受阻原因 |
| 任务清单（todo） | ✅ | ✅ | 模型通过 `todo_write` 维护，界面常驻进度 |
| 图片输入 | ✅ | ✅ | 系统相册选择，附件落盘、请求时再编码 |
| 语音输入 | ✅ | ✅ | 系统语音识别（CoreSpeechKit） |
| 明暗主题 / 中英文 | ✅ | ✅ | 可跟随系统，也可强制 |
| API Key 安全存储 | ✅ | ✅ | Asset Store Kit，不落普通配置文件 |
| Shell / 本地文件工具 | ✅ | ❌ | 手机端无 shell，改为纯网络工具 |
| 插件与 MCP | ✅ | ❌ | 见「后续计划」 |
| 多智能体 / 工作流 | ✅ | ❌ | 见「后续计划」 |

## 工具集

模型可用工具：`web_search`、`web_fetch`、`todo_write`、`ask_user_question`、
`create_goal`、`get_goal`、`update_goal`。

搜索默认走 DuckDuckGo 的 HTML 端点（失败自动回退 Bing），不需要任何搜索 API Key。
网页抓取会把 HTML 转成正文再交给模型，超出预算自动截断。

## 环境要求

| 项 | 版本 |
| --- | --- |
| DevEco Studio | 6.0 及以上 |
| HarmonyOS SDK | API 26（compatibleSdkVersion 6.1.1(24)） |
| 设备 | HarmonyOS 6 手机 / 平板 |

## 构建

### 用 DevEco Studio

直接 `File → Open` 本目录，等待同步完成，连接设备后点运行。

### 用命令行

```powershell
# Windows PowerShell
$env:PSExecutionPolicyPreference = 'Bypass'
.\scripts\build.ps1
```

产物在 `entry/build/default/outputs/default/entry-default-unsigned.hap`。
脚本会自行设置 `DEVECO_SDK_HOME` / `JAVA_HOME`，并把构建缓存放进工作区内的
`.buildhome/`，不污染用户目录。若 DevEco 不在 `E:\DevEco Studio`，改脚本顶部的
`$deveco` 变量。

安装到设备：

```powershell
hdc install -r entry\build\default\outputs\default\entry-default-unsigned.hap
```

> 未签名 HAP 只能装到已开启调试的设备；正式自用请在 DevEco 里配置自己的签名。

## 首次使用

1. 打开 App，点右上角 ⚙ → **API Key**，粘贴 DeepSeek API Key 并保存。
2. 可选：在设置里选模型（`deepseek-flash` 支持图片，`deepseek-v4-pro` 纯文本）、
   推理强度、主题和语言。
3. 回到对话页直接开聊。

## 目录结构

```
entry/src/main/ets/
├── common/          常量、主题令牌、日志、工具函数、错误映射
├── i18n/            中英文文案表
├── model/           数据类型与会话→渲染视图模型
├── service/
│   ├── LlmClient    Messages 流式客户端（SSE 解析）
│   ├── AgentLoop    智能体循环：流式→工具→续跑→目标
│   ├── Tools        工具执行器
│   ├── Prompt       系统提示词与工具 schema
│   ├── SessionStore 会话持久化与搜索
│   ├── SettingsService / SecretService  设置与密钥
│   ├── ImageService / SpeechService     图片与语音
│   └── WebTool      网页抓取与搜索
├── view/            消息气泡、工具卡片、Markdown、输入栏、各个 sheet
└── pages/Index.ets  应用主壳
```

## 设计说明

- **协议对齐**：`LlmClient` 严格复刻上游 `translate.ts` 的语义 —— `content_block_start`
  / `delta` / `stop` 的块序、`thinking` 与 `signature` 的透传、`tool_use` 的 JSON
  增量拼接、`refusal` 与空响应的错误分类。
- **请求体对齐**：`thinking.type`、`output_config.effort`、`tools[].input_schema`
  与上游 `serialize.ts` 一致；历史里每个 `tool_use` 都有配对的 `tool_result`，
  被中断的调用会在发送前补一个本地结果，保证请求合法。
- **性能**：流式文本放在独立状态字段里，只有它跟着 token 重渲染；已提交的消息列表
  按 `messageId` 做 key，不参与逐 token 刷新。
- **数据安全**：API Key 走 Asset Store；会话是纯文本 JSON，写在应用沙箱内。

更细的架构与移植取舍见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 已知限制

- 搜索依赖搜索引擎的 HTML 结构，对方改版时可能短期失效（会自动回退另一个引擎）。
- 单轮工具调用上限 40 轮；目标模式上限 60 轮，达到后暂停并提示。
- 长对话不做自动压缩（上下文满时会明确报错），请新建会话。
- 平板仅做了基础适配，布局以手机为主。

## 后续计划

- [ ] 技能（Skill）：把可复用的提示词包做成可导入的 Markdown
- [ ] 插件化：对齐上游的 bundle 概念，支持导入自定义工具
- [ ] MCP 客户端：连接远程 MCP 服务
- [ ] 子代理：把长任务拆给子会话
- [ ] 会话压缩：接近上下文上限时自动摘要

## 致谢

- [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) —— 上游项目，
  这个客户端的行为基准与灵感来源。
- DeepSeek 官方的 Messages 兼容接口。

## 许可证

[MIT](LICENSE)。上游同样以 MIT 发布。本项目与 DeepSeek 官方无关。
