# Project structure and build

## Repository layout

```text
.
├── platforms/
│   ├── mac/                    # Swift/AppKit/SwiftUI app and XCTest suite
│   └── windows/                # C#/WPF app and .NET tests
├── resources/localization/     # Shared string catalogs
├── assets/                     # Shared project artwork
├── scripts/                    # Build, test, release, and utility commands
├── docs/                       # Public project documentation
└── .github/                    # CI and repository automation
```

The clients share product behavior and resources, but not UI or capture-engine
code. Platform behavior must be verified on its native operating system.

## macOS

Requirements:

- macOS 13 or later
- Apple Silicon
- Xcode 26.2 or a compatible newer version

### Local signing identity

The macOS build scripts reject ad-hoc signatures so privacy permissions remain
stable across local rebuilds. An existing Apple Development or Developer ID
identity can be used. If none is available, create the development-only
`ShotPaste Local Development` identity in the login keychain:

```bash
./scripts/create-signing-cert.sh
```

Keep this identity in the login keychain for later local builds. The script uses
a temporary PKCS#12 file only for import, deletes it on exit, and never prints or
exports release credentials. Identities created by this script are always for
local development and must never replace the fixed release identity.

Build the canonical Debug app:

```bash
./scripts/build_and_run.sh build
```

Run tests:

```bash
./scripts/run-tests.sh
```

Build and launch:

```bash
./scripts/build_and_run.sh
```

Products:

- Debug: `.build/macos/Debug/ShotPaste Debug.app`
- Release: `.build/macos/Release/ShotPaste.app`

### Debug and Release isolation

The two macOS configurations are independent applications and can run at the
same time. Release keeps its existing identity and paths; Debug uses dedicated
values:

| Surface | Release | Debug |
| --- | --- | --- |
| Bundle ID | `com.ahtcfg24.shotpaste` | `com.ahtcfg24.shotpaste.debug` |
| Executable | `ShotPaste` | `ShotPasteDebug` |
| Application Support | `~/Library/Application Support/ShotPaste` | `~/Library/Application Support/ShotPaste Debug` |
| Diagnostic logs | `~/Library/Logs/ShotPaste` | `~/Library/Logs/ShotPaste Debug` |
| Managed TOML | `~/.config/shotpaste/config.toml` | `~/.config/shotpaste-debug/config.toml` |
| Default export folder | `~/Desktop/ShotPaste` | `~/Desktop/ShotPaste Debug` |
| URL Scheme | `shotpaste://` | `shotpaste-debug://` |
| Default MCP port | `48123` | `48124` |
| Copied MCP client key | `shotpaste` | `shotpaste-debug` |
| Menu bar icon | `MenubarIcon` double-frame mark | `MenubarIconDebug` double-frame mark with centered `D` |

Their UserDefaults, privacy permissions, login items, history database,
thumbnails, clipboard archive, temporary captures, recording metadata, logs,
problem-report archives, and default output folders therefore do not overlap.
Internal pasteboard markers and Quick Access drag types also use variant-scoped
identifiers; Quick Access payloads are exposed only within their originating
process. Each app accepts only its registered URL Scheme.
The application icons and menu bar icons share the same brand geometry; Debug
adds a visible `D`. Debug also adds Option to its default global shortcuts so
those bindings do not contend with Release defaults. No automatic legacy-data
migration runs. A directory explicitly selected in both apps is intentionally
shared by that choice.

Canonical build identity values live in
`platforms/mac/ShotPaste/Config/AppVariant-{Debug,Release}.xcconfig`. Xcode,
local build/signing scripts, and both test configurations consume those files;
artifact validation must agree with `AppVariant` before a signed build is
accepted.

### Release signing identity

Until an Apple Developer ID certificate is available, official release builds use
the fixed self-signed identity `ShotPaste Release Self-Signed`, with SHA-1
fingerprint `8CBB386A17831C9C093C6BA693C4F60BC239A213`. The public certificate is tracked at
`.github/signing/ShotPaste-Release-Self-Signed.crt` so maintainers can audit the
identity without access to private material.

The exportable identity and its password are stored only in the repository Actions
secrets `SELF_SIGNED_CERT_P12` and `SELF_SIGNED_CERT_PASSWORD`. The P12 contains the
private key and must never be committed. These release credentials are
maintainer-only; contributors do not need them for local builds. Do not replace,
recreate, rename, or rotate the release certificate. macOS privacy permissions are
tied to the application signing identity.

### Automated releases

macOS and Windows have independent stable release streams. Tags must point to a
commit contained in `release` and use one of these exact forms:

- `macos-vMAJOR.MINOR.PATCH`, for example `macos-v1.3.0`, triggers
  `.github/workflows/release-macos.yml`.
- `windows-vMAJOR.MINOR.PATCH`, for example `windows-v1.2.4`, triggers
  `.github/workflows/release-windows.yml`.

Each workflow runs the native tests and release build for only its platform,
creates the matching package, verifies `SHA256SUMS.txt`, and publishes a
non-draft platform-specific GitHub Release with the matching startup guide.
Platform releases can therefore advance at different versions and on different
schedules. Pull requests into `release` still run both platform validation jobs
so the stable source branch remains buildable for both clients.

The macOS workflow requires the repository Actions secrets
`SELF_SIGNED_CERT_P12` and `SELF_SIGNED_CERT_PASSWORD`. It verifies the imported
certificate against the fixed release fingerprint before building. Invalid
tags, tags outside `release`, missing credentials, failed tests, failed builds,
or missing artifacts stop the applicable workflow before a GitHub Release is
created. Official platform tags are immutable and may be created only by the
repository owner.

## Windows

Requirements:

- Windows 10 version 2004 or later, x64
- .NET 8 SDK

From PowerShell, restore, build, and run the configured tests:

```powershell
./scripts/build-windows.ps1 -Configuration Debug
```

Create a self-contained release publish:

```powershell
./scripts/build-windows.ps1 -Configuration Release -Publish
```

Selection, hotkeys, DPI, scrolling, recording, media, and window behavior must
be validated at the physical Windows console.

## Main code areas

macOS:

- `App/`: process lifecycle, menu bar, and URL commands
- `Features/`: capture, One Shot, annotation, recording, history, Quick Access,
  and preferences
- `Services/`: capture/media, clipboard, persistence, configuration,
  diagnostics, and shortcuts
- `Shared/`: localization and reusable UI/support code

Windows:

- `Views/`: WPF windows and controls
- `Services/`: capture, recording, OCR, history, clipboard, settings, and app
  coordination
- `Models/`: settings and workflow data
- `Interop/`: Win32 boundaries
- `tests/`: unit and native end-to-end projects

## Configuration files

The macOS client maintains its user-editable preferences at:

```text
~/.config/shotpaste/config.toml
```

Validated direct edits are applied on the next app launch. Changes made in the
app are synchronized back in the background unless the file has an external
edit that requires review. Capture history, clipboard payloads, credentials,
security-scoped bookmarks, caches, and other device-private state are excluded.

Windows stores preferences internally at
`%LOCALAPPDATA%\ShotPaste\settings.json`; it does not expose a TOML import or
export contract.

## Localization

The split catalogs under `resources/localization/Shared` and
`resources/localization/Features` are runtime resources shared by both native
clients. `resources/localization/manifest.json` assigns each key prefix to its
owning catalog. Edit the owning catalog and verify ownership and drift with:

```bash
swift -module-cache-path build/swift-module-cache platforms/mac/Tools/Localization/CatalogTool.swift verify
```

Do not add generated localization artifacts to the repository.

## Contribution rule

When product behavior changes, check both native clients. Build and test the
platform changed, then record any intentional operating-system difference.
