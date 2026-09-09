<a id="security-policy"></a>

# 安全政策

<a id="reporting-a-vulnerability"></a>

## 报告漏洞

不要在公开 Issue、讨论或 Pull Request 中披露疑似漏洞。请使用 GitHub 私密漏洞报告流程：

[私密报告漏洞](https://github.com/shotpaste/shotpaste/security/advisories/new)

请提供受影响平台与版本、影响、复现步骤或概念验证，以及建议的缓解措施。
不要包含真实剪贴板数据、捕获内容、凭据或其它个人信息；请使用合成示例。

我们力争在三个工作日内确认收到完整报告，七个工作日内给出初步严重性评估，
之后至少每十四天提供一次进展。这是志愿维护项目的响应目标，不是保证的服务级别。
公开披露前请给予合理修复时间。我们会按报告者意愿致谢，除非署名会泄露敏感信息。

<a id="supported-versions"></a>

## 支持版本

| 版本 | 是否支持 |
| --- | --- |
| 最新 macOS 发布版 | 是 |
| 最新 Windows 发布版 | 是 |
| 当前 `release` 分支 | 是 |
| 当前 `main` 分支 | 是 |
| 更早版本 | 否，请升级至最新版本 |

<a id="scope"></a>

## 范围

重点关注任意代码执行、不安全 URL 或文件处理、权限边界绕过、意外捕获或剪贴板泄露、
发布产物篡改及依赖受损。

社会工程、未支持的操作系统，以及要求公开他人私有数据的攻击通常不在范围内。
请只测试自己拥有或获授权的账户、设备及数据。遵循本政策的善意研究不会仅因
为证明问题而绕过控制措施被项目追究。

<a id="security-model"></a>

## 安全模型

ShotPaste 采用本地优先设计：

- 捕获、录制、OCR、二维码识别、历史与剪贴板处理在本地进行。
- 主动开启录制转写后，仅将选定音频通过单独配置的凭据发送至火山引擎。
  可选 Agent AI 整理向配置的 LLM 端点发送转写文字与分句 ID。
  捕获本身不需要这两类网络服务。macOS 转写凭据使用本地 UserDefaults 档案，
  与 LLM API Key 一致；这不是 Keychain 加密。界面掩码显示已保存值，
  配置导出、任务记录和日志排除凭据。Debug/Release Bundle 身份隔离档案。
  Windows 使用 DPAPI 保护凭据。
- 项目不运营账号服务、遥测收集器或上传中转。
- 应用不提供通用远程存储或同步。两平台的可选转写仅在用户自有私有 TOS 存储中暂存音频。
  签名 GET URL 仅存在于内存，有效期最长 24 小时，只发送到固定 ASR 主机。
  重定向不携带鉴权信息。按前缀限制的两天对象过期规则补充即时删除与独立清理重试。
  macOS 持久化任务 JSON 排除凭据、请求体和签名 URL。
  Windows 私有捕获/任务回执保留 DPAPI 加密账户快照，使恢复和删除使用原始凭据；
  导出同时排除加密快照、明文密钥和签名 URL。
  原始转写与待处理音频分段使用私有、按构建身份隔离的应用支持目录。
  切换账户时保留旧任务用于清理的本地凭据档案，新密钥不得删除其它档案的对象。
- 已保存转写与 AI 笔记独立于剪贴板历史保留。删除历史项或源媒体不删除这些内容。
  云音频清理不删除本地转写；评估备份或数据移除时应考虑私有任务存储。
  见[录音与转写指南](docs/RECORDING_TRANSCRIPTION.md)。
- OCR 链接与二维码载荷视为文本，不自动打开或执行。

macOS 应用启用 hardened runtime，未启用 App Sandbox。
捕获请求屏幕录制权限，启用语音录制时请求麦克风权限，
仅需要观察全局输入的功能请求辅助功能/输入监控权限。
用户选定文件访问与 macOS 快捷键设置只读访问在 entitlements 中声明。

Windows 使用原生捕获与全局输入 API，应用数据位于用户本地应用数据目录。
纯录音使用 WASAPI，不创建屏幕流。临时 PCM 和音源音频仅保留在本地，
仅在安全保存或显式丢弃后移除。

<a id="release-trust"></a>

## 发布信任

- macOS 包使用项目固定自签名证书。
- Windows 便携包目前未使用 Authenticode 签名。
- 每次发布包含 `SHA256SUMS.txt`，打开安装包前应核对校验和。
- 发布签名材料不得提交到仓库或附在 Issue 中。

<a id="dependencies"></a>

## 依赖

macOS 除 Apple 框架外使用 GRDB.swift 和 Swift-WebP。
Windows 使用 ScreenRecorderLib、Microsoft.Data.Sqlite、SQLitePCLRaw、SkiaSharp 和 ZXing.Net。
依赖声明维护于 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)，自动依赖更新需经评审。

<a id="disclosure-and-release-handling"></a>

## 披露与发布处理

安全修复在可行时私下开发，在受影响原生平台测试，发布时简明说明影响及升级方式。
发布产物和校验和仅由仓库发布工作流生成并公布。
