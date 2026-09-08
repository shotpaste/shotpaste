# 文档导航与语言约定

ShotPaste 以简体中文维护项目文档。产品界面仍支持十种语言，文档语言策略不改变应用本地化范围。

## 语言与同步规则

- 开发、架构、功能契约、评审方案、安全、协作与仓库维护文档只维护中文主文档，
  不增加平行英文版本。文件名沿用现有名称，避免路径改动。
- 仓库根目录 `README.md` 默认使用简体中文，英文译本为 `README.en.md`，其余语言沿用现有后缀。
  `README.zh-CN.md` 仅保留旧链接入口，不重复维护正文。README 保留现有十种语言；用户介绍、平台要求、构建入口与下载说明变化时同步全部版本。
- 面向用户的使用指南以无语言后缀文件作为中文主文档，英文译本使用 `.en.md`。
  如需其它语言，沿用 README 的语言后缀；更新时同步已有译本，不以默认数量要求新增语言。
  每份译本提供到中文主文档及其它已有译本的入口。
- 使用指南包括操作步骤、配置、排障、自动化接入与发布启动说明。
  当前发布介绍在同一文件中保留中英双语，以兼容既有发布脚本。
- 命令、路径、API/协议字段、配置键、代码标识符、机器输出和版本号保留原样。
  翻译标题时保留被引用的旧锚点；技术事实和历史验证范围不因翻译改变。
- `LICENSE` 及第三方许可证、版权声明和授权文本保留原文；其外围说明使用中文。

## 项目维护文档

| 文档 | 职责 |
| --- | --- |
| [AGENTS.md](../AGENTS.md) | 研发 Agent 执行规则与验证门禁 |
| [功能契约](FEATURES.md) | 跨平台产品流程、语言及隐私边界 |
| [开发指南](DEVELOPMENT.md) | 构建、测试、签名、发布、配置与代码职责 |
| [贡献指南](../CONTRIBUTING.md) | 贡献流程、分支与 PR 规则 |
| [安全政策](../SECURITY.md) | 私密漏洞报告、安全模型与发布信任 |
| [行为准则](../CODE_OF_CONDUCT.md) | 社区参与与执行规则 |
| [第三方声明](../THIRD_PARTY_NOTICES.md) | 依赖用途、版权与许可证原文 |
| [发布签名身份](../.github/signing/README.md) | 公开证书与凭据边界 |
| [工程简化方案](ENGINEERING_SIMPLIFICATION_PLAN.md) | 工程复杂度审计及渐进重构记录 |
| [转写改造方案](VOLCENGINE_TRANSCRIPTION_REFACTOR_PLAN.md) | 选型、存储设计及历史验证记录 |
| [macOS UI/UX 方案](ui-ux-optimization-plan-mac.md) | 界面与交互改造计划 |
| [Windows UI/UX 台账](../platforms/windows/WINDOWS_MACOS_UI_UX_AUDIT.md) | 平台对齐审查与验证台账 |

## 使用指南与译本

| 主题 | 中文 | English |
| --- | --- | --- |
| 产品介绍 | [README](../README.md) | [README](../README.en.md)（页面内含其余八种语言入口） |
| 录音与转写 | [使用指南](RECORDING_TRANSCRIPTION.md) | [Guide](RECORDING_TRANSCRIPTION.en.md) |
| URL Scheme / MCP | [自动化](AUTOMATION.md) | [Automation](AUTOMATION.en.md) |
| Agent Mode | [使用与配置](AGENT_MODE.md) | [Usage and configuration](AGENT_MODE.en.md) |
| 排障与求助 | [使用支持](../SUPPORT.md) | [Support](../SUPPORT.en.md) |

发布介绍：[macOS（中英双语）](release/RELEASE-NOTES-INTRO-macOS.md)、
[Windows（中英双语）](release/RELEASE-NOTES-INTRO-Windows.md)。
