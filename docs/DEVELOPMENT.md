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

### Release signing identity

Official release builds use the existing self-signed certificate with SHA-1
fingerprint `35517841F1D32EC1ED7D1F411565845C4AA4B70A`. Its certificate subject is
preserved from releases made before the product rename. Maintainer CI reads it from
`SELF_SIGNED_CERT_P12` and `SELF_SIGNED_CERT_PASSWORD`. These release credentials
are maintainer-only; contributors do not need them for local builds. Do not
replace, recreate, rename, or rotate the release certificate, and never populate those
secrets with output from a local certificate. macOS privacy permissions are tied
to the application signing identity.

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
