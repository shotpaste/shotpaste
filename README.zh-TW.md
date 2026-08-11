# ShotPaste

適用於 macOS 與 Windows 的原生、本機優先螢幕擷取與錄影工具。

[English](README.md) · [Tiếng Việt](README.vi.md) ·
[简体中文](README.zh-CN.md) · **繁體中文** · [Español](README.es.md) ·
[日本語](README.ja.md) · [한국어](README.ko.md) ·
[Русский](README.ru.md) · [Français](README.fr.md) ·
[Deutsch](README.de.md)

ShotPaste 為 macOS 與 Windows 提供彼此獨立的原生客戶端。擷取、OCR、錄影、
歷史記錄、剪貼簿處理與設定皆保留在本機。專案不提供帳號、遙測、雲端上傳、
遠端儲存或同步服務。

## 功能

- **One Shot：**只選取一次區域，即可切換截圖、捲動擷取、錄影或剪貼簿歷史。
- **截圖：**凍結選區、視窗辨識、輸出格式、命名、縮放、游標與桌面顯示設定。
- **內嵌標註：**選取、形狀、箭頭、文字、螢光筆、馬賽克、聚光燈、編號、畫筆、
  復原/重做、OCR、QR Code、複製與釘選。
- **捲動擷取：**手動/自動捲動、即時預覽、方向與重複畫面保護、長圖拼接。
- **錄影：**區域影片或 GIF、系統聲音、麥克風、滑鼠效果、按鍵顯示、暫停、
  重新錄製、捨棄、快照與即時畫筆。
- **Quick Access 與釘選：**可設定的擷取後卡片、複製/儲存/開啟、拖放、滑動、
  倒數計時與置頂圖片。
- **剪貼簿歷史：**以本機 SQLite 保存截圖、錄影、文字、圖片與複製的檔案，
  支援搜尋、篩選、保留規則與清理。
- **自訂：**全域快速鍵、擷取後動作、輸出資料夾、外觀、診斷、URL 指令與
  10 種介面語言。

完整內容請參閱[功能列表](docs/FEATURES.md)。

## 平台

| | macOS | Windows |
| --- | --- | --- |
| 系統需求 | macOS 13+，Apple Silicon | Windows 10 2004+，x64 |
| 原生技術 | SwiftUI、AppKit、ScreenCaptureKit、Vision | WPF、Win32、Windows 擷取/OCR/媒體 API |
| 原始碼 | `platforms/mac` | `platforms/windows` |

兩個客戶端共享產品行為與本地化資源，但不共享應用程式碼或跨平台 UI 框架。

## 建置

macOS：

```bash
./scripts/build_and_run.sh build
./scripts/run-tests.sh
```

Windows PowerShell：

```powershell
./scripts/build-windows.ps1 -Configuration Debug
```

請參閱[專案結構與建置說明](docs/DEVELOPMENT.md)。

## 下載

請從 [GitHub Releases](https://github.com/shotpaste/shotpaste/releases) 下載
最新的 macOS DMG 或 Windows 可攜式 ZIP。開啟套件前，請核對隨附的校驗碼並閱讀
[發布信任說明](SECURITY.md#release-trust)。

## 授權與致謝

ShotPaste 採用 [BSD 3-Clause License](LICENSE)。

### 致謝與來源歷史

ShotPaste 感謝 [Snapzy](https://github.com/duongductrong/Snapzy) 與
[ShareX](https://github.com/ShareX/ShareX)。在本專案的開發過程中，它們的開源成果
提供了重要協助與靈感。

macOS 用戶端最初源自 Snapzy 的提交
[`a6f8edf01a48e9dd9bdc4212b0e3472725219274`](https://github.com/duongductrong/Snapzy/commit/a6f8edf01a48e9dd9bdc4212b0e3472725219274)，
並採用 BSD 3-Clause License；此後，其程式碼已有大幅演進與差異。Windows 用戶端
則是同一 ShotPaste 產品工作流程的獨立原生實作，其開發也部分參考了 ShareX。

必須保留的第三方著作權與授權文字收錄於
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

歡迎參與貢獻；建立拉取請求前請閱讀 [CONTRIBUTING.md](CONTRIBUTING.md)。使用協助
與安全問題回報方式請參閱 [SUPPORT.md](SUPPORT.md) 和 [SECURITY.md](SECURITY.md)。
