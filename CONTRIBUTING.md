# Contributing to Lite Screen

Thank you for helping improve Lite Screen. Contributions may target either
native client, shared localization, documentation, scripts, or release quality.

## Before you start

- Search existing issues and pull requests.
- Open an issue before a large feature, dependency, data-format, or architecture
  change.
- Keep pull requests focused. Shared product behavior should remain aligned on
  macOS and Windows unless an operating-system difference requires otherwise.
- Never include credentials, signing certificates, captured private content, or
  unsanitized logs and screenshots.

Security vulnerabilities belong in the private process described in
[SECURITY.md](SECURITY.md), not in a public issue.

## Set up the project

Follow [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md). Platform code must be built
and tested on its native operating system:

- macOS: Swift, SwiftUI, and AppKit under `platforms/mac`
- Windows: C#, WPF, and Win32 under `platforms/windows`

The clients use different native stacks but aim to preserve the shared product
behavior in [docs/FEATURES.md](docs/FEATURES.md).

To enable the optional staged-Swift formatting check:

```bash
git config core.hooksPath scripts
```

Remove the local setting with `git config --unset core.hooksPath`.

## Validate a change

macOS baseline:

```bash
./scripts/format.sh
swift -module-cache-path build/swift-module-cache platforms/mac/Tools/Localization/CatalogTool.swift verify
./scripts/run-tests.sh
./scripts/build_and_run.sh build
```

Windows PowerShell baseline:

```powershell
./scripts/build-windows.ps1 -Configuration Debug
```

A successful compile is not sufficient for capture, recording, permission,
shortcut, DPI, or window-management changes. Include the affected OS/hardware
and concise manual acceptance steps in the pull request.

## Pull requests

1. Branch from `master` and make one coherent change.
2. Add or update tests and user-facing documentation where relevant.
3. Validate every changed native platform on that operating system.
4. Complete the pull request template with exact evidence and known limits.

Do not mix generated artifacts, unrelated formatting, or personal IDE files
into the change. By contributing, you agree that your contribution is licensed
under the repository's [BSD 3-Clause License](LICENSE).
