<a id="support"></a>

# 使用支持

**简体中文** · [English](SUPPORT.en.md)

ShotPaste 是由社区维护的开源项目。

<a id="before-opening-an-issue"></a>

## 提交 Issue 前

1. 阅读 [README](README.md)、[功能契约](docs/FEATURES.md)和[开发指南](docs/DEVELOPMENT.md)。
2. 搜索已有 Issue，并在可行时尝试最新发布版。
3. 收集 ShotPaste 版本、操作系统版本、安装方式、准确步骤和已脱敏诊断信息。

可复现缺陷、功能请求和使用问题请使用仓库 Issue 表单。
表单说明所需证据，并帮助区分平台问题。
上传前从截图、录屏和日志中移除捕获内容、剪贴板数据、凭据、签名材料、个人文件路径及其它私有数据。
疑似漏洞请按[安全政策](SECURITY.md)私密报告。

<a id="macos-diagnostics"></a>

## macOS 诊断

收集近期崩溃报告与脱敏错误日志：

```bash
./scripts/collect-crash-logs.sh
```

若隐私权限状态异常，先阅读[开发指南](docs/DEVELOPMENT.md)中的签名说明，再运行交互式重置工具：

```bash
./scripts/reset-permissions.sh
```

卸载工具可移除应用，并按选择删除本地数据。
请仔细阅读提示，捕获与剪贴板历史可能被删除：

```bash
./scripts/uninstall.sh
```
