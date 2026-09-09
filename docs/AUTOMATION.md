<a id="shotpaste-automation"></a>

# ShotPaste 自动化

**简体中文** · [English](AUTOMATION.en.md)

ShotPaste macOS 通过 URL Scheme 与本地 Model Context Protocol（MCP）服务暴露同一套白名单命令。
两种接口都操作可见应用界面，不提供 shell、AppleScript、任意文件访问或无人值守屏幕交互。

## URL Scheme

Release 仅注册并接受 `shotpaste://`，Debug 仅注册并接受 `shotpaste-debug://`，
定向 Apple event 不能跨越两种应用身份。

| 操作 | 标准 URL |
| --- | --- |
| 以截图模式启动 One Shot | `shotpaste://capture/screenshot` |
| 以滚动截屏模式启动 One Shot | `shotpaste://capture/scrolling` |
| 以录屏模式启动 One Shot | `shotpaste://record/screen` |
| 使用模式参数启动 One Shot | `shotpaste://capture/one-shot?mode=screenshot` |
| 取消活动 One Shot 会话 | `shotpaste://capture/cancel` |
| 使用已配置筛选打开历史 | `shotpaste://open/history` |
| 打开筛选历史 | `shotpaste://open/history?filter=clipboard` |
| 打开设置 | `shotpaste://settings?tab=general` |
| 暂停、继续或停止录制 | `shotpaste://recording/pause`、`shotpaste://recording/resume`、`shotpaste://recording/stop` |

两平台的暂停/继续/停止录制控制也通过音频协调器操作活动录音。
停止保存 M4A；macOS 内部 MOV 不进入视频后处理，Windows 通过 WASAPI 直接捕获音频。
工具白名单与鉴权要求保持不变，不提供开始录音命令。

捕获模式为 `screenshot`、`scrolling` 和 `recording`。
历史筛选为 `all`、`screenshot`、`scrolling`、`recording` 和 `clipboard`。
设置标签为 `general`、`capture`、`quick-access`、`history`、`agent`、`shortcuts`、`permissions` 和 `advanced`。

示例：

```bash
open 'shotpaste://capture/one-shot?mode=scrolling'
open 'shotpaste://open/history?filter=recording'
```

自动化 Debug 时，将协议替换为 `shotpaste-debug://`。

可在**设置 → 通用 → 自动化**中关闭 URL Scheme 集成。
未知路由及参数会被拒绝，不回退到更宽泛的操作。

<a id="mcp-server"></a>

## MCP 服务

macOS 应用实现 MCP `2025-11-25` Streamable HTTP 传输，兼容 `2025-06-18` 与 `2025-03-26` 客户端。
服务默认关闭。

1. 打开**设置 → 通用 → 自动化**。
2. 启用 **MCP 服务**。
3. 点击**复制到剪贴板**，将 `mcpServers` 配置粘贴到支持 Streamable HTTP 的客户端。
4. 客户端连接期间保持 ShotPaste 运行。

Release 默认端点为 `http://127.0.0.1:48123/mcp`，Debug 为 `http://127.0.0.1:48124/mcp`，
允许两应用同时运行服务。每个应用生成自己的 Bearer Token。
复制配置包含对应 Token，并使用 `shotpaste` 或 `shotpaste-debug` 作为客户端键名；
禁止公开或提交 Token。端口可在对应本地 TOML 修改：
Release 为 `~/.config/shotpaste/config.toml`，Debug 为 `~/.config/shotpaste-debug/config.toml`。

```toml
[general]
mcp_server_enabled = true
mcp_server_port = 48123
```

鉴权 Token 不进入 TOML 导出或备份文档。

<a id="tools"></a>

### 工具

| 工具 | 用途 |
| --- | --- |
| `shotpaste.get_status` | 读取捕获、录制与历史界面状态。 |
| `shotpaste.start_capture` | 按指定模式启动可见 One Shot 界面。 |
| `shotpaste.cancel_capture` | 取消活动 One Shot 会话。 |
| `shotpaste.open_history` | 打开历史，可选筛选条件。 |
| `shotpaste.open_settings` | 打开设置，可选标签页。 |
| `shotpaste.control_recording` | 暂停、继续或停止活动录制。 |

工具结果同时包含 MCP 文本内容及如下结构的 `structuredContent`：

```json
{
  "ok": true,
  "message": "Started One Shot in screenshot mode.",
  "state": {
    "oneShot": "active",
    "recording": "idle"
  }
}
```

<a id="transport-security"></a>

### 传输安全

内嵌服务：

- 仅绑定 IPv4 回环地址 `127.0.0.1`。
- 每次请求都要求生成的 Bearer Token。
- 验证 `Host` 及存在时的 `Origin` 请求头，防止 DNS 重绑定。
- 不启用 CORS 或浏览器可访问的回退方式。
- 限制请求头与请求体大小。
- 仅暴露上述工具。

关闭 MCP 设置会立即关闭监听器及活动连接。
捕获与录制仍需要正常 macOS 权限，每个 MCP 操作均在 ShotPaste 界面可见。
