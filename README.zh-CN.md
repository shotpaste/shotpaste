# Lite Screen

面向 macOS 与 Windows 的原生、本地优先截屏与录屏工具。

[English](README.md) · [Tiếng Việt](README.vi.md) · **简体中文** ·
[繁體中文](README.zh-TW.md) · [Español](README.es.md) ·
[日本語](README.ja.md) · [한국어](README.ko.md) ·
[Русский](README.ru.md) · [Français](README.fr.md) ·
[Deutsch](README.de.md)

Lite Screen 为 macOS 和 Windows 提供彼此独立的原生客户端。截屏、OCR、
录屏、历史记录、剪贴板处理和配置都保存在本机。项目不提供账号、遥测、云上传、
远程存储或同步服务。

## 功能

- **One Shot：**只选择一次区域，即可切换截图、滚动截屏、录屏或剪贴板历史。
- **截图：**冻结选区、窗口识别、输出格式、命名、缩放、光标和桌面显示设置。
- **内联标注：**选择、形状、箭头、文字、高亮、马赛克、聚光灯、序号、画笔、
  撤销/重做、OCR、二维码、复制和贴图。
- **滚动截屏：**手动/自动滚动、实时预览、方向和重复帧保护、长图拼接。
- **录屏：**区域视频或 GIF、系统声音、麦克风、鼠标效果、按键显示、暂停、
  重录、丢弃、快照和实时画笔。
- **Quick Access 与贴图：**可配置的捕获后卡片、复制/保存/打开、拖拽、滑动、
  倒计时和置顶图片。
- **剪贴板历史：**本地 SQLite 保存截图、录屏、文本、图片和复制的文件，支持
  搜索、筛选、保留策略和清理。
- **自定义：**全局快捷键、捕获后动作、输出目录、外观、诊断、URL 命令和
  10 种界面语言。

完整说明见[功能列表](docs/FEATURES.md)。

## 平台

| | macOS | Windows |
| --- | --- | --- |
| 系统要求 | macOS 13+，Apple Silicon | Windows 10 2004+，x64 |
| 原生技术 | SwiftUI、AppKit、ScreenCaptureKit、Vision | WPF、Win32、Windows 截屏/OCR/媒体 API |
| 源码目录 | `platforms/mac` | `platforms/windows` |

两个客户端共享产品行为与本地化资源，但不共享应用代码或跨平台 UI 框架。

## 构建

macOS：

```bash
./scripts/build_and_run.sh build
./scripts/run-tests.sh
```

Windows PowerShell：

```powershell
./scripts/build-windows.ps1 -Configuration Debug
```

参见[项目结构与构建说明](docs/DEVELOPMENT.md)。

## 下载

可在 [GitHub Releases](https://github.com/ahtcfg24/LiteScreen/releases) 下载
最新的 macOS DMG 或 Windows 便携 ZIP。打开安装包前，请核对随附的校验和并阅读
[发布信任说明](SECURITY.md#release-trust)。

## 协议与致谢

Lite Screen 使用 [BSD 3-Clause License](LICENSE)。项目致谢与来源历史见
[NOTICE.md](NOTICE.md)，依赖项协议见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

欢迎参与贡献；提交拉取请求前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。使用帮助
和安全问题报告方式见 [SUPPORT.md](SUPPORT.md) 与 [SECURITY.md](SECURITY.md)。
