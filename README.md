# ShotPaste

Native, local-first screen capture for macOS and Windows.

**English** · [Tiếng Việt](README.vi.md) · [简体中文](README.zh-CN.md) ·
[繁體中文](README.zh-TW.md) · [Español](README.es.md) ·
[日本語](README.ja.md) · [한국어](README.ko.md) ·
[Русский](README.ru.md) · [Français](README.fr.md) ·
[Deutsch](README.de.md)

**Official website:** [shotpaste.com](https://www.shotpaste.com/)

ShotPaste provides independent native clients for macOS and Windows. Capture,
OCR, recording, history, clipboard processing, and configuration stay on the
device. The project does not provide accounts, telemetry, cloud upload, remote
storage, or synchronization.

## Features

- **One Shot:** select an area once, then choose Screenshot, Scrolling,
  Recording, or Clipboard History.
- **Screenshots:** frozen region selection, window targeting, configurable
  output format, naming, scale, cursor, desktop, and notification behavior.
- **Inline annotation:** selection, shapes, arrows, text, highlighter, mosaic,
  spotlight, counter, pencil, undo/redo, OCR, QR detection, copy, and pin.
- **Scrolling capture:** manual and automatic scrolling, live preview,
  duplicate/direction protection, and long-image stitching.
- **Recording:** region video or GIF, system audio, microphone, cursor and click
  effects, keystroke overlay, pause/restart/discard, snapshots, and live ink.
- **Quick Access and pins:** configurable post-capture cards, copy/save/open,
  drag and swipe actions, countdown, and always-on-top image pins.
- **Clipboard History:** local SQLite history for captures, recordings, text,
  images, and copied files, with search, filters, retention, and cleanup.
- **Customization:** global shortcuts, after-capture actions, output folders,
  appearance, diagnostics, URL commands, and ten interface languages.

See [the complete feature list](docs/FEATURES.md).

## Feature gallery

| **One Shot** | **Screenshots** |
|:---:|:---:|
| [![One Shot mode picker](assets/readme/one-shot.png)](assets/readme/one-shot.png) | [![Screenshot selection and toolbar](assets/readme/screenshots.png)](assets/readme/screenshots.png) |
| **Inline annotation** | **Scrolling capture** |
| [![Inline annotation tools](assets/readme/inline-annotation.png)](assets/readme/inline-annotation.png) | [![Scrolling capture selection](assets/readme/scrolling-capture.png)](assets/readme/scrolling-capture.png) |
| **Recording** | **Quick Access and pins** |
| [![Recording area and options](assets/readme/recording.png)](assets/readme/recording.png) | [![Quick Access card and pinned image](assets/readme/quick-access-pins.png)](assets/readme/quick-access-pins.png) |
| **Clipboard History** | **Customization** |
| [![Searchable capture and clipboard history](assets/readme/clipboard-history.png)](assets/readme/clipboard-history.png) | [![Capture customization settings](assets/readme/customization.png)](assets/readme/customization.png) |

## Platforms

| | macOS | Windows |
| --- | --- | --- |
| Requirements | macOS 13+, Apple Silicon | Windows 10 2004+, x64 |
| Native stack | SwiftUI, AppKit, ScreenCaptureKit, Vision | WPF, Win32, Windows capture/OCR/media APIs |
| Source | `platforms/mac` | `platforms/windows` |

The clients share product behavior and localization resources, not application
code or a cross-platform UI framework.

## Build

macOS:

```bash
./scripts/build_and_run.sh build
./scripts/run-tests.sh
```

Windows PowerShell:

```powershell
./scripts/build-windows.ps1 -Configuration Debug
```

See [project structure and build instructions](docs/DEVELOPMENT.md).

## Downloads

Download the latest macOS DMG or Windows portable ZIP from
[GitHub Releases](https://github.com/shotpaste/shotpaste/releases). Verify the
included checksums and read the [release trust notes](SECURITY.md#release-trust)
before opening a package.

## License and acknowledgements

ShotPaste is released under the [BSD 3-Clause License](LICENSE).

### Acknowledgements and source history

ShotPaste is grateful to [Snapzy](https://github.com/duongductrong/Snapzy)
and [ShareX](https://github.com/ShareX/ShareX). Their open-source work provided
substantial help and inspiration while this project was developed.

The macOS client started from Snapzy commit
[`a6f8edf01a48e9dd9bdc4212b0e3472725219274`](https://github.com/duongductrong/Snapzy/commit/a6f8edf01a48e9dd9bdc4212b0e3472725219274)
under the BSD 3-Clause License and has since diverged substantially. The Windows
client is an independent native implementation of the same ShotPaste product
workflow, informed in part by studying ShareX.

Required third-party copyright and license text is preserved in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Contributions are welcome; read [CONTRIBUTING.md](CONTRIBUTING.md) before
opening a pull request. For help or responsible reporting, see
[SUPPORT.md](SUPPORT.md) and [SECURITY.md](SECURITY.md).
