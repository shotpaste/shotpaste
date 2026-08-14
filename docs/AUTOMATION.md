# ShotPaste automation

ShotPaste for macOS exposes the same allow-listed command model through URL
Scheme links and a local Model Context Protocol (MCP) server. Both interfaces
operate the visible application UI; they do not provide shell, AppleScript,
arbitrary file access, or unattended screen interaction.

## URL Scheme

Release builds register and accept only `shotpaste://`. Debug builds register
and accept only `shotpaste-debug://`, so a directed Apple event cannot cross
the two app variants.

| Action | Canonical URL |
| --- | --- |
| Start One Shot in screenshot mode | `shotpaste://capture/screenshot` |
| Start One Shot in scrolling mode | `shotpaste://capture/scrolling` |
| Start One Shot in recording mode | `shotpaste://record/screen` |
| Start One Shot with a mode parameter | `shotpaste://capture/one-shot?mode=screenshot` |
| Cancel the active One Shot session | `shotpaste://capture/cancel` |
| Open history with its configured filter | `shotpaste://open/history` |
| Open filtered history | `shotpaste://open/history?filter=clipboard` |
| Open settings | `shotpaste://settings?tab=general` |
| Pause, resume, or stop recording | `shotpaste://recording/pause`, `shotpaste://recording/resume`, `shotpaste://recording/stop` |

Capture modes are `screenshot`, `scrolling`, and `recording`. History filters
are `all`, `screenshot`, `scrolling`, `recording`, and `clipboard`. Settings
tabs are `general`, `capture`, `quick-access`, `history`, `shortcuts`,
`permissions`, and `advanced`.

For example:

```bash
open 'shotpaste://capture/one-shot?mode=scrolling'
open 'shotpaste://open/history?filter=recording'
```

When automating Debug, replace the scheme with `shotpaste-debug://`.

The URL Scheme integration can be disabled in **Settings → General →
Automation**. Unknown routes and parameter values are rejected rather than
falling back to a broader action.

## MCP server

The macOS app implements the MCP `2025-11-25` Streamable HTTP transport and
accepts compatible `2025-06-18` and `2025-03-26` clients. The server is off by
default.

1. Open **Settings → General → Automation**.
2. Enable **MCP server**.
3. Select **Copy to Clipboard** and paste the copied `mcpServers` entry into a
   client that supports Streamable HTTP.
4. Keep ShotPaste running while the client is connected.

The Release default endpoint is `http://127.0.0.1:48123/mcp`; Debug defaults to
`http://127.0.0.1:48124/mcp` so both apps can run their servers concurrently.
Each app has its own generated bearer token. The copied configuration contains
the applicable token and uses `shotpaste` or `shotpaste-debug` as its client key;
do not publish or commit the token. The port can be changed in that app's local
TOML configuration (`~/.config/shotpaste/config.toml` for Release and
`~/.config/shotpaste-debug/config.toml` for Debug):

```toml
[general]
mcp_server_enabled = true
mcp_server_port = 48123
```

Authentication tokens are deliberately excluded from TOML exports and backup
documents.

### Tools

| Tool | Purpose |
| --- | --- |
| `shotpaste.get_status` | Read capture, recording, and history UI state. |
| `shotpaste.start_capture` | Start visible One Shot UI with a selected mode. |
| `shotpaste.cancel_capture` | Cancel the active One Shot session. |
| `shotpaste.open_history` | Open history with an optional filter. |
| `shotpaste.open_settings` | Open an optional settings tab. |
| `shotpaste.control_recording` | Pause, resume, or stop an active recording. |

Tool results include both MCP text content and `structuredContent` with this
shape:

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

### Transport security

The embedded server:

- binds only to IPv4 loopback (`127.0.0.1`);
- requires a generated bearer token on every request;
- validates `Host` and, when present, `Origin` headers to prevent DNS rebinding;
- does not enable CORS or a browser-accessible fallback;
- limits request headers and bodies; and
- exposes only the tools listed above.

Disabling the MCP setting immediately closes the listener and active
connections. Capture and recording still require the normal macOS permissions,
and every MCP action remains visible in the ShotPaste UI.
