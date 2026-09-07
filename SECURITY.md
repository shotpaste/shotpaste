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
| Latest macOS release | Yes |
| Latest Windows release | Yes |
| Current `release` branch | Yes |
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
- Opt-in recording transcription sends only selected audio to Volcengine using
  separately configured credentials. Optional Agent AI processing sends transcript
  text and segment IDs to the configured LLM endpoint. Capture itself does not
  require either network service. On macOS, transcription credentials use local
  UserDefaults profiles, matching the LLM API key. This storage is not Keychain
  encryption; the interface masks saved values and the app excludes them from
  configuration exports, task records and logs. Debug/Release bundle identities
  keep the profiles separate. Windows retains DPAPI-protected credentials.
- The project does not operate an account service, telemetry collector, or upload relay.
- The app does not offer general-purpose remote storage or synchronization.
  Opt-in transcription on both platforms stages audio only in user-owned private TOS storage.
  Signed GET URLs exist in memory for a maximum 24-hour validity and go only to
  the fixed ASR host. Redirects never receive authentication. Scoped 2-day object
  expiration supplements immediate deletion and independent cleanup retries.
  macOS durable task JSON excludes credentials, request bodies and signed URLs.
  Windows private capture and task receipts retain DPAPI-encrypted account snapshots
  so recovery and deletion use the original credentials; exports exclude these
  encrypted snapshots as well as plaintext keys and signed URLs. Raw
  transcripts and pending local audio parts use private variant support storage.
  Account switches retain old local credential profiles for their own cleanup; new keys
  are never used to delete another profile's objects.
- OCR links and QR payloads are treated as text. They are not automatically opened or executed.

The macOS app uses hardened runtime but is not App Sandbox-enabled. It requests Screen Recording for capture, Microphone when voice recording is enabled, and Accessibility/Input Monitoring only for features that need global input observation. User-selected file access and read-only access to macOS shortcut preferences are declared in its entitlements.

Windows uses native capture and global-input APIs and stores application data under the user's local application-data directory. Audio-only capture uses WASAPI without a screen stream. Temporary PCM and source audio remain local and are removed only after safe saving or explicit discard.

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
