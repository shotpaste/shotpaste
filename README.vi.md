# Lite Screen

Công cụ chụp và ghi màn hình gốc, ưu tiên dữ liệu cục bộ cho macOS và Windows.

[English](README.md) · **Tiếng Việt** · [简体中文](README.zh-CN.md) ·
[繁體中文](README.zh-TW.md) · [Español](README.es.md) ·
[日本語](README.ja.md) · [한국어](README.ko.md) ·
[Русский](README.ru.md) · [Français](README.fr.md) ·
[Deutsch](README.de.md)

Lite Screen cung cấp hai ứng dụng gốc độc lập cho macOS và Windows. Ảnh chụp,
OCR, bản ghi, lịch sử, dữ liệu bảng tạm và cấu hình đều nằm trên thiết bị. Dự án
không cung cấp tài khoản, đo lường từ xa, tải lên đám mây, lưu trữ từ xa hay
đồng bộ.

## Tính năng

- **One Shot:** chọn vùng một lần rồi dùng Ảnh chụp, Chụp cuộn, Ghi màn hình
  hoặc Lịch sử bảng tạm.
- **Ảnh chụp:** vùng chọn đóng băng, nhận diện cửa sổ, định dạng, tên tệp, tỉ lệ,
  con trỏ và tùy chọn màn hình nền.
- **Chú thích trực tiếp:** vùng chọn, hình, mũi tên, chữ, tô sáng, mosaic, đèn rọi,
  số thứ tự, bút, hoàn tác/làm lại, OCR, QR, sao chép và ghim.
- **Chụp cuộn:** cuộn thủ công/tự động, xem trước trực tiếp, bảo vệ hướng và khung
  trùng, ghép ảnh dài.
- **Ghi màn hình:** video vùng hoặc GIF, âm thanh hệ thống, micrô, hiệu ứng chuột,
  hiển thị phím, tạm dừng, ghi lại, hủy, ảnh nhanh và vẽ trực tiếp.
- **Quick Access và ghim:** thẻ sau khi chụp có thể cấu hình, sao chép/lưu/mở,
  kéo thả, vuốt, đếm ngược và ảnh luôn nổi.
- **Lịch sử bảng tạm:** SQLite cục bộ cho ảnh, video, văn bản, hình và tệp đã sao
  chép, kèm tìm kiếm, bộ lọc, thời hạn lưu và dọn dẹp.
- **Tùy chỉnh:** phím tắt toàn cục, hành động sau khi chụp, thư mục đầu ra, giao
  diện, chẩn đoán, lệnh URL và 10 ngôn ngữ.

Xem [danh sách tính năng đầy đủ](docs/FEATURES.md).

## Nền tảng

| | macOS | Windows |
| --- | --- | --- |
| Yêu cầu | macOS 13+, Apple Silicon | Windows 10 2004+, x64 |
| Công nghệ gốc | SwiftUI, AppKit, ScreenCaptureKit, Vision | WPF, Win32, API chụp/OCR/đa phương tiện Windows |
| Mã nguồn | `platforms/mac` | `platforms/windows` |

Hai ứng dụng chia sẻ hành vi sản phẩm và tài nguyên bản địa hóa, không chia sẻ
mã ứng dụng hay khung UI đa nền tảng.

## Biên dịch

macOS:

```bash
./scripts/build_and_run.sh build
./scripts/run-tests.sh
```

Windows PowerShell:

```powershell
./scripts/build-windows.ps1 -Configuration Debug
```

Xem [cấu trúc dự án và hướng dẫn biên dịch](docs/DEVELOPMENT.md).

## Tải xuống và giấy phép

Các gói macOS và Windows mới nhất có tại
[GitHub Releases](https://github.com/ahtcfg24/LiteScreen/releases). Lite Screen
dùng [Giấy phép BSD 3-Clause](LICENSE). Lời cảm ơn và lịch sử mã nguồn nằm trong
[NOTICE.md](NOTICE.md), còn giấy phép của các phụ thuộc nằm trong
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Xem [CONTRIBUTING.md](CONTRIBUTING.md), [SUPPORT.md](SUPPORT.md) và
[SECURITY.md](SECURITY.md) để đóng góp, nhận trợ giúp hoặc báo cáo có trách nhiệm.
