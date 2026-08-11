# Security policy

## Reporting a vulnerability

Do not disclose a suspected vulnerability in a public issue, discussion, or pull request. Use GitHub's private vulnerability reporting flow:

[Report a vulnerability privately](https://github.com/shotpaste/shotpaste/security/advisories/new)

Include the affected platform and version, impact, reproduction steps or proof of concept, and any suggested mitigation. Maintainers will acknowledge a complete report when it has been reviewed; no fixed response-time promise is made while the project is volunteer-maintained.

## Supported versions

Security fixes target the latest released version and the current `main` branch. Older versions may be asked to upgrade before receiving a fix.

## Security model

ShotPaste is local-first:

- Capture, recording, OCR, QR recognition, history, and clipboard processing happen locally.
- The project does not operate an account service, telemetry collector, or upload relay.
- The app does not provide remote storage, file upload, or synchronization features.
- OCR links and QR payloads are treated as text. They are not automatically opened or executed.

The macOS app uses hardened runtime but is not App Sandbox-enabled. It requests Screen Recording for capture, Microphone when voice recording is enabled, and Accessibility/Input Monitoring only for features that need global input observation. User-selected file access and read-only access to macOS shortcut preferences are declared in its entitlements.

Windows uses native capture and global-input APIs and stores application data under the user's local application-data directory.

## Release trust

- macOS packages use the project's persistent self-signed certificate and are not Apple-notarized.
- Windows portable packages are currently not Authenticode-signed.
- Every release includes `SHA256SUMS.txt`; users should verify checksums before opening packages.
- Release signing material must never be committed to the repository or attached to issues.

## Dependencies

macOS uses GRDB.swift and Swift-WebP in addition to Apple frameworks. Windows uses ScreenRecorderLib, Microsoft.Data.Sqlite, SQLitePCLRaw, SkiaSharp, and ZXing.Net. Dependency notices are maintained in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), and automated dependency updates are reviewed through pull requests.
