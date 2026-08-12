# Security policy

## Reporting a vulnerability

Do not disclose a suspected vulnerability in a public issue, discussion, or pull request. Use GitHub's private vulnerability reporting flow:

[Report a vulnerability privately](https://github.com/shotpaste/shotpaste/security/advisories/new)

Include the affected platform and version, impact, reproduction steps or proof
of concept, and any suggested mitigation. Do not include real clipboard data,
captures, credentials, or other personal information; use synthetic examples.

We aim to acknowledge complete reports within three business days, provide an
initial severity assessment within seven business days, and share progress at
least every fourteen days until resolution. These are response targets for a
volunteer-maintained project, not guaranteed service levels.

Please allow a reasonable remediation window before public disclosure. We will
credit reporters who request it, unless attribution would reveal sensitive
information.

## Supported versions

| Version | Supported |
| --- | --- |
| Latest release | Yes |
| Current `main` branch | Yes |
| Older releases | No; upgrade to the latest release |

## Scope

Reports are especially useful when they involve arbitrary code execution,
unsafe URL or file handling, permission-boundary bypasses, unintended capture or
clipboard disclosure, release artifact tampering, or dependency compromise.

Reports about social engineering, unsupported operating systems, or attacks
that require the reporter to publish another person's private data are normally
out of scope. Test only accounts, devices, and data you own or are authorized to
use. Good-faith research that follows this policy will not be pursued by the
project merely for bypassing a control to demonstrate the issue.

## Security model

ShotPaste is local-first:

- Capture, recording, OCR, QR recognition, history, and clipboard processing happen locally.
- The project does not operate an account service, telemetry collector, or upload relay.
- The app does not provide remote storage, file upload, or synchronization features.
- OCR links and QR payloads are treated as text. They are not automatically opened or executed.

The macOS app uses hardened runtime but is not App Sandbox-enabled. It requests Screen Recording for capture, Microphone when voice recording is enabled, and Accessibility/Input Monitoring only for features that need global input observation. User-selected file access and read-only access to macOS shortcut preferences are declared in its entitlements.

Windows uses native capture and global-input APIs and stores application data under the user's local application-data directory.

## Release trust

- macOS packages use the project's persistent self-signed certificate.
- Windows portable packages are currently not Authenticode-signed.
- Every release includes `SHA256SUMS.txt`; users should verify checksums before opening packages.
- Release signing material must never be committed to the repository or attached to issues.

## Dependencies

macOS uses GRDB.swift and Swift-WebP in addition to Apple frameworks. Windows uses ScreenRecorderLib, Microsoft.Data.Sqlite, SQLitePCLRaw, SkiaSharp, and ZXing.Net. Dependency notices are maintained in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), and automated dependency updates are reviewed through pull requests.

## Disclosure and release handling

Security fixes are developed privately when practical, tested on the affected
native platform, and released with concise impact and upgrade guidance. Release
artifacts and checksums are published only by the repository release workflow.
