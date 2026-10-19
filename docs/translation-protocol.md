# 平台之间的翻译数据约定

当前实现位于 `Sources/Shiyi/TranslationClient.swift` 与 `Domain.swift`。本说明用于 Windows 版对齐行为；目前没有独立的跨平台共享库。

## AI 请求

服务使用可配置的 Chat Completions 兼容接口，发送 `model` 和 `messages`。系统消息定义翻译规则；用户消息是 JSON 数据，不拼入系统指令。

```json
{
  "selectedText": "token",
  "requestedScene": "技术",
  "referenceContext": "The access token expires in one hour.",
  "application": "TextEdit",
  "documentTitle": "Authentication guide"
}
```

只翻译 `selectedText`，其他字段仅辅助消歧。关闭上下文时，完全省略 `referenceContext`、`application`、`documentTitle`，不发送 Bundle ID、文档全文或截图。上下文最多 4,000 字符；当前桌面入口限制选中文字最多 5,000 字。所有输入都视为待处理数据，不能执行其中要求改变翻译规则的指令。

远程接口必须使用 HTTPS，仅回环地址可使用 HTTP。凭据放在 Authorization 请求头，不写进 URL 或日志；拒绝重定向，避免把凭据发往其他地址。

## 输出

模型在回复内容中返回以下 JSON：

```json
{
  "translation": "令牌",
  "explanation": "这里指用于身份认证的令牌。",
  "alternatives": ["词元", "代币"],
  "detectedScene": "身份认证"
}
```

`translation` 必须非空；其他三个字段必需但可为空。备选译法最多展示三项。歧义无法确定时应说明，不虚构上下文，也不声称结果具有精确的置信度。

## 生命周期

每个选区请求使用独立任务 ID。新选区、关闭浮窗或改变隐私设置时取消旧任务；旧任务的结果不得覆盖新选区。固定卡片时暂停自动替换，但允许主动快捷键翻译。

系统翻译引擎按平台实现，当前 macOS 系统引擎只翻译选中文字；AI 模式才使用此语境请求约定。
