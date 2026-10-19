# Windows 版

状态：计划中，当前没有 Windows 可执行程序。

Windows 应用代码、项目文件及平台构建脚本后续放在此目录，和仓库中的 macOS 原生版本共同维护。暂不把 macOS 的 Swift/AppKit 界面抽象为跨平台 UI。

接入时需要实现：

- 通过 Windows UI Automation 获取选区及有限上下文，提供快捷键取词和手动粘贴。
- 托盘入口、自动触发、可固定的翻译浮窗及应用排除。
- 使用 Windows 凭据存储保护 API Key。
- 遵循 [翻译数据约定](../../docs/translation-protocol.md)，对齐 AI 模式的输入、输出及隐私设置。
- 增加 Windows CI 和独立的 Release 安装包；不修改 macOS 安装包的文件名或架构标识。

Windows 原生翻译引擎的选择与语言支持需要在实现时单独验证，不依赖 macOS 的 Apple Translation。
