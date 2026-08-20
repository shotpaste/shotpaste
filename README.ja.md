# ShotPaste

macOS と Windows 向けのネイティブかつローカル優先の画面キャプチャツールです。

[English](README.md) · [Tiếng Việt](README.vi.md) ·
[简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) ·
[Español](README.es.md) · **日本語** · [한국어](README.ko.md) ·
[Русский](README.ru.md) · [Français](README.fr.md) ·
[Deutsch](README.de.md)

**公式サイト:** [shotpaste.com](https://www.shotpaste.com/)

ShotPaste は macOS と Windows に独立したネイティブクライアントを提供します。
キャプチャ、OCR、録画、履歴、クリップボード処理、設定は端末内に保持されます。
アカウント、テレメトリ、クラウドアップロード、リモート保存、同期機能はありません。

## 機能

- **One Shot：** 一度範囲を選び、スクリーンショット、スクロールキャプチャ、
  録画、クリップボード履歴を切り替えます。

  [![One Shot モード選択](assets/readme/oneshot.gif)](assets/readme/oneshot.gif)

- **スクリーンショットと OCR：** 固定された選択画面、ウィンドウ認識、
  ローカル文字認識、形式、命名、スケール、カーソル、デスクトップ表示の設定。

  [![スクリーンショットのローカル OCR](assets/readme/OCR.gif)](assets/readme/OCR.gif)

- **インライン注釈：** 選択、図形、矢印、テキスト、蛍光ペン、モザイク、
  スポットライト、番号、ペン、元に戻す/やり直し、QR、コピー、ピン留め。

  [![インライン注釈ツール](assets/readme/inline.gif)](assets/readme/inline.gif)

- **スクロールキャプチャ：** 手動/自動スクロール、ライブプレビュー、方向・重複
  保護、長い画像の結合。

  [![スクロールキャプチャ](assets/readme/scroll.gif)](assets/readme/scroll.gif)

- **録画：** 範囲動画または GIF、システム音声、マイク、マウス効果、キー表示、
  一時停止、再録画、破棄、スナップショット、ライブ描画。

  [![ライブ注釈付き録画](assets/readme/recording.gif)](assets/readme/recording.gif)

- **Quick Access とピン：** 設定可能なカード、コピー/保存/開く、ドラッグ、
  スワイプ、常に手前に表示する画像。

  [![Quick Access からの画像ピン留め](assets/readme/quickaccess-pin.gif)](assets/readme/quickaccess-pin.gif)

  [![複数の常時手前表示画像](assets/readme/pin.gif)](assets/readme/pin.gif)

- **クリップボード履歴：** キャプチャ、録画、テキスト、画像、コピーしたファイルを
  ローカル SQLite に保存し、検索、絞り込み、保持期間、削除を提供します。

  [![検索可能なキャプチャとクリップボード履歴](assets/readme/clipboard-history.gif)](assets/readme/clipboard-history.gif)

- **カスタマイズ：** グローバルショートカット、キャプチャ後の処理、保存先、外観、
  診断、URL コマンド、10 言語。

  [![ShotPaste の設定](assets/readme/settings.gif)](assets/readme/settings.gif)

詳細は[機能一覧](docs/FEATURES.md)を参照してください。

## プラットフォーム

| | macOS | Windows |
| --- | --- | --- |
| 要件 | macOS 13+、Apple Silicon | Windows 10 2004+、x64 |
| ネイティブ技術 | SwiftUI、AppKit、ScreenCaptureKit、Vision | WPF、Win32、Windows キャプチャ/OCR/メディア API |
| ソース | `platforms/mac` | `platforms/windows` |

両クライアントは製品動作とローカライズ資源を共有しますが、アプリコードや
クロスプラットフォーム UI フレームワークは共有しません。

## ビルド

macOS:

```bash
./scripts/build_and_run.sh build
./scripts/run-tests.sh
```

Windows PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-windows.ps1 -Configuration Debug
```

[プロジェクト構成とビルド手順](docs/DEVELOPMENT.md)も参照してください。

## ダウンロードとライセンス

最新の macOS・Windows パッケージは
[GitHub Releases](https://github.com/shotpaste/shotpaste/releases) から入手できます。
ShotPaste は [BSD 3-Clause License](LICENSE) で公開されています。

### 謝辞とソースの来歴

ShotPaste は [Snapzy](https://github.com/duongductrong/Snapzy) と
[ShareX](https://github.com/ShareX/ShareX) に感謝します。両プロジェクトの
オープンソース成果は、ShotPaste の開発に多大な助力と着想をもたらしました。

macOS クライアントは BSD 3-Clause License の下で公開された Snapzy のコミット
[`a6f8edf01a48e9dd9bdc4212b0e3472725219274`](https://github.com/duongductrong/Snapzy/commit/a6f8edf01a48e9dd9bdc4212b0e3472725219274)
を出発点とし、その後大きく異なるコードへ発展しました。Windows クライアントは、
ShareX の調査からも一部知見を得つつ、同じ ShotPaste 製品ワークフローを独立して
ネイティブ実装したものです。

保持が必要な第三者の著作権表示とライセンス本文は
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) に収録しています。

貢献、サポート、責任ある報告については [CONTRIBUTING.md](CONTRIBUTING.md)、
[SUPPORT.md](SUPPORT.md)、[SECURITY.md](SECURITY.md) を参照してください。
