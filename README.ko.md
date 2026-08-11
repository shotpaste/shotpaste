# Lite Screen

macOS와 Windows를 위한 네이티브 로컬 우선 화면 캡처 도구입니다.

[English](README.md) · [Tiếng Việt](README.vi.md) ·
[简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) ·
[Español](README.es.md) · [日本語](README.ja.md) · **한국어** ·
[Русский](README.ru.md) · [Français](README.fr.md) ·
[Deutsch](README.de.md)

Lite Screen은 macOS와 Windows에 서로 독립적인 네이티브 클라이언트를 제공합니다.
캡처, OCR, 녹화, 기록, 클립보드 처리와 설정은 기기에만 저장됩니다. 계정, 원격
측정, 클라우드 업로드, 원격 저장소 또는 동기화 서비스는 제공하지 않습니다.

## 기능

- **One Shot:** 영역을 한 번 선택한 뒤 스크린샷, 스크롤 캡처, 녹화 또는
  클립보드 기록을 선택합니다.
- **스크린샷:** 고정된 선택 화면, 창 인식, 형식, 파일 이름, 배율, 커서 및
  데스크톱 표시 설정.
- **인라인 주석:** 선택, 도형, 화살표, 텍스트, 형광펜, 모자이크, 스포트라이트,
  번호, 펜, 실행 취소/다시 실행, OCR, QR, 복사 및 고정.
- **스크롤 캡처:** 수동/자동 스크롤, 실시간 미리보기, 방향 및 중복 프레임 보호,
  긴 이미지 결합.
- **녹화:** 영역 비디오 또는 GIF, 시스템 오디오, 마이크, 마우스 효과, 키 표시,
  일시 중지, 다시 녹화, 폐기, 스냅샷 및 실시간 잉크.
- **Quick Access 및 고정:** 구성 가능한 캡처 후 카드, 복사/저장/열기, 드래그,
  스와이프, 카운트다운 및 항상 위 이미지.
- **클립보드 기록:** 캡처, 녹화, 텍스트, 이미지와 복사된 파일을 로컬 SQLite에
  저장하고 검색, 필터, 보존 및 정리를 지원합니다.
- **사용자 설정:** 전역 단축키, 캡처 후 동작, 출력 폴더, 모양, 진단, URL 명령과
  10개 인터페이스 언어.

자세한 내용은 [전체 기능 목록](docs/FEATURES.md)을 참조하세요.

## 플랫폼

| | macOS | Windows |
| --- | --- | --- |
| 요구 사항 | macOS 13+, Apple Silicon | Windows 10 2004+, x64 |
| 네이티브 기술 | SwiftUI, AppKit, ScreenCaptureKit, Vision | WPF, Win32, Windows 캡처/OCR/미디어 API |
| 소스 | `platforms/mac` | `platforms/windows` |

두 클라이언트는 제품 동작과 지역화 리소스를 공유하지만 애플리케이션 코드나
크로스 플랫폼 UI 프레임워크는 공유하지 않습니다.

## 빌드

macOS:

```bash
./scripts/build_and_run.sh build
./scripts/run-tests.sh
```

Windows PowerShell:

```powershell
./scripts/build-windows.ps1 -Configuration Debug
```

[프로젝트 구조 및 빌드 안내](docs/DEVELOPMENT.md)를 참조하세요.

## 다운로드 및 라이선스

최신 macOS 및 Windows 패키지는
[GitHub Releases](https://github.com/ahtcfg24/LiteScreen/releases)에서 받을 수
있습니다. Lite Screen은 [BSD 3-Clause License](LICENSE)로 공개됩니다. 감사와 코드
이력은 [NOTICE.md](NOTICE.md), 의존성 라이선스는
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)를 참조하세요.

기여, 지원 및 책임 있는 신고 안내는 [CONTRIBUTING.md](CONTRIBUTING.md),
[SUPPORT.md](SUPPORT.md), [SECURITY.md](SECURITY.md)를 참조하세요.
