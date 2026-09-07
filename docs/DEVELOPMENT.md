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

Development-only ASR 2.0 account probe (not bundled with either native app):

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts -p test_volcengine_transcription_probe.py -v
python3 scripts/volcengine_transcription_probe.py
# Query the persisted task after interruption; this never submits again:
python3 scripts/volcengine_transcription_probe.py --resume
```

The live command prompts for a speech API Key without echoing or saving it and
submits the official public short MP3 once. Obtain account-owner authorization for
service activation and usage charges first. The report lives under ignored
`build/volcengine-account-verification/`; use a new report path only for an
intentional new billable submission. Never pass credentials in command arguments.
This probe verifies ASR HTTP behavior only, not TOS permissions, native recording,
cleanup, actual billing, or cross-platform acceptance. See
[the refactor plan](VOLCENGINE_TRANSCRIPTION_REFACTOR_PLAN.md) for remaining gates.

The optional private-TOS probe uses the official Python `tos==2.9.2` SDK
(Apache-2.0), installed only in an ignored development virtual environment. It is
not a native application dependency. Use a trusted Python 3.12+ runtime:

```bash
python3 -m venv build/volcengine-account-verification/tos-venv
build/volcengine-account-verification/tos-venv/bin/python -m pip install 'tos==2.9.2'
PYTHONDONTWRITEBYTECODE=1 build/volcengine-account-verification/tos-venv/bin/python -m unittest discover -s scripts -p 'test_volcengine*probe.py' -v
build/volcengine-account-verification/tos-venv/bin/python scripts/volcengine_tos_probe.py --resources build/volcengine-account-verification/tos-poc-resources.json --report build/volcengine-account-verification/tos-poc-result.json
```

Prepare a resource JSON with a random 12-character lowercase hex `installation`,
`region` equal to `cn-beijing`, `bucket` equal to
`shotpaste-tmp-poc-<installation>-debug`, and `prefix` equal to
`transcription/v1/<installation>/`. Authorize the corresponding resource-limited
IAM policy before running. The command prompts securely for keys, creates the
private test bucket and lifecycle, uploads only the official public sample,
checks unsigned/signed access, runs ASR and verifies deletion. It retains the
bucket; it never deletes a bucket or changes other object prefixes. Inspect a
failed report before retrying: `--resume-setup` applies only before any upload;
`--cleanup-only` retries recorded-object deletion without a new ASR submission.

macOS uses the native ASR/TOS components from AI Features → AI Transcription and
both recording entry points. Configure speech Key and dedicated IAM AK/SK.
Save persists credentials locally; Save and test also initializes private storage
and runs the paid public sample verification, retaining completed setup stages
for retries. Advanced options contain existing private storage. One Shot's
pre-recording panel owns the screen-recording transcription and AI toggles and
spoken language. These choices are remembered on Start and passed with that
recording so later default changes cannot alter its post-processing. Cancelling
preparation discards draft changes. GIF and recordings without audio cannot
enable transcription; automatic upload remains independently opt-in.

Transcription credentials use variant-isolated UserDefaults profiles, like
`AgentCredentialStore`; no Keychain API is used. Previously Keychain-only values
must be entered again. Profile IDs keep old jobs bound to their original keys
until cleanup finishes. Plaintext secrets are not written to TOML or task exports.

Private cloud receipts and pending M4A parts live in the build variant's application
support `CloudTranscription` directory. Parent media references and complete
timelines and derived AI artifacts live in `RecordingTranscriptionSessions`; these
files also stay private. Audio results remain in their existing AudioAdapter
session directories. The results browser reads both stores and persists only
history UUID associations in `AudioAdapter/transcription-history-links.json`.
All three paths use `AppDataLocations` for Debug/Release isolation.
Startup/periodic recovery queries existing
request IDs and cleans completed/failed/cancelled objects. The menu groups Start
Audio Recording with Transcription Results; Preferences no longer lists cloud
jobs or transcripts. Transcription Results owns task progress and transcript exports.
Native tests use injected HTTP fixtures; the public sample button exercises the
actual Swift signing, AVFoundation export, local credential store and HTTP path.

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

### Audio transcription diagnostics

With diagnostics enabled, macOS audio processing writes task/session identifiers,
source role, chunk index and timing, export/recognition stage, and error domains/codes to the variant's
Diagnostic logs directory listed above. Underlying error domains/codes are retained;
error descriptions, arbitrary error payloads, audio paths, and transcript text are
excluded. Cancellation is logged separately from failure. Chunk start/completion
entries and task failure entries allow a failed run to be correlated without
reading recording content. These logs help diagnose a subsequent run; they cannot
recover framework error details discarded by older builds.
Extraction also logs container/audio durations, track start, difference, and
allowed tolerance for each session/segment/source, with explicit rejection
entries. The default recognition engine now calls Volcengine; the legacy Speech
adapter remains injectable for existing tests but is not selected at runtime.
Cloud transcription requires AI Transcription settings speech API Key, TOS AK/SK, initialized
private storage and successful sample verification. Use public non-private audio
for live validation; protocol fixtures do not establish real service acceptance. AI processing uses Agent's configured
endpoint, model, protocol and credentials, with text-only payloads.

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
schedules. After the required changes are pushed to `main`, the repository owner
merges `main` directly into `release` through the release pull request. Do not
create an intermediate promotion branch. Pull requests into `release` still run
both platform validation jobs so the stable source branch remains buildable for
both clients.

The macOS workflow requires the repository Actions secrets
`SELF_SIGNED_CERT_P12` and `SELF_SIGNED_CERT_PASSWORD`. It verifies the imported
certificate against the fixed release fingerprint before building. Invalid
tags, tags outside `release`, missing credentials, failed tests, failed builds,
or missing artifacts stop the applicable workflow before a GitHub Release is
created. Official platform tags are immutable and may be created only by the
repository owner.

## Windows

Recording transcription now uses the native file-ASR/TOS implementation, with
DPAPI-protected credentials and capture-time snapshots. No Python runtime or
cloud SDK is bundled. Native WASAPI audio capture writes private recovery PCM
under `AudioRecordingSessions`; validated M4A is saved using recording output
preferences. Role-specific M4As remain available for transcription. Durable jobs
and generated transcript/AI artifacts live in `TranscriptionResults`, independently
of clipboard-history retention. Screen capture-to-transcription handoff receipts
retain the original consent until a durable job exists. All paths derive from
`AppPaths.Root` and therefore follow Debug/Release identity isolation.

In Recording settings, save speech and restricted TOS credentials, then explicitly
confirm the paid public-sample test. Choose transcription, language and AI at
recording preparation time. Tests use protocol/signature fixtures and synthetic
local data; they do not establish real cloud entitlement or native recording
quality. Run the canonical Windows validation below once that host is available.


Requirements:

- Windows 10 version 2004 or later, x64
- PowerShell 5.1 or PowerShell 7
- .NET 8 SDK (`dotnet --info` should report an installed SDK)
- Run the commands below from the repository root

Verify the SDK before starting the build:

```powershell
dotnet --info
```

`scripts/build-windows.ps1` is the canonical Windows validation entry point. It
restores `platforms/windows/ShotPaste.Windows.sln` for x64, runs the broad test
pass and the isolated native-memory/database regressions, verifies the
selected configuration's application identity, builds the Windows E2E projects,
and runs the headless parity contract. The headless run does not require a signed-in
desktop; interactive capture, clipboard, OCR, localization, and recording
checks are run separately on a signed-in Windows session.

Run the full Debug validation from PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-windows.ps1 -Configuration Debug
```

Run the Release validation without publishing:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-windows.ps1 -Configuration Release
```

Create a self-contained, single-file win-x64 release publish:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-windows.ps1 -Configuration Release -Publish
```

The primary artifacts are:

- Debug: `platforms/windows/src/ShotPaste.Windows/bin/x64/Debug/net8.0-windows10.0.19041.0/win-x64/ShotPasteDebug.exe`
- Release: `platforms/windows/src/ShotPaste.Windows/bin/x64/Release/net8.0-windows10.0.19041.0/win-x64/ShotPaste.exe`
- Release publish: `platforms/windows/src/ShotPaste.Windows/bin/x64/Release/net8.0-windows10.0.19041.0/win-x64/publish/ShotPaste.exe`

The headless parity summary is written to
`build/e2e/windows-parity/summary.json`. A successful build script run is not
evidence that interactive capture, recording, permission, shortcut, DPI, or
window-management behavior passed. Run those checks at the physical Windows
console and include the affected OS/hardware and concise manual acceptance
steps in the change description.

For a Debug interactive parity run after the Debug build, pass the Debug
executable explicitly:

```powershell
$product = (Resolve-Path '.\platforms\windows\src\ShotPaste.Windows\bin\x64\Debug\net8.0-windows10.0.19041.0\win-x64\ShotPasteDebug.exe').Path
.\scripts\test-windows-parity.ps1 -Configuration Debug -Tier Interactive -SkipBuild -ProductExecutable $product -RequireDpiScale 1.5
```

The Recording E2E also checks standalone audio with a quiet generated test tone
played through the real Windows render endpoint. It verifies WASAPI loopback,
pause/resume, repeated stop, discard/restart, native AAC encoding, source roles,
and recovery-file cleanup. Production preparation and result windows are rendered
with local fixtures to check source gating, search/filtering and saved artifacts.
With the product executable supplied, an isolated real product process also
checks the visible recording preparation/start/stop flow, Quick Access, history
opt-in/opt-out, and saving before quitting. Its existing `--ui-test-surface`
entry opens preparation only; it adds no production URL/MCP start operation.
These checks do not record the microphone or send cloud requests, and do not
substitute for physical tray/shortcut or microphone acceptance.
To rerun only these audio checks after the canonical build:

```powershell
dotnet run --project .\platforms\windows\tests\ShotPaste.Windows.RecordingE2E\ShotPaste.Windows.RecordingE2E.csproj -c Debug -p:Platform=x64 --no-build -- build/e2e/windows-parity/recording $product --audio-only
```

`build-windows.ps1` explicitly builds the complete solution before testing;
`dotnet test` alone does not generate the standalone E2E executables on a fresh
checkout. Run interactive validation in a signed-in desktop session, not SSH
Session 0, and retain the session, OS, display and audio endpoint evidence.
Localization E2E retains native window screenshots and checks window/control
bounds and overlap. Its text-width checks use only fonts and single-line ranges
reported by UI Automation; unavailable font data is not replaced by a guessed
size. Reports distinguish `MeasuredSingleLineTexts` from all visible text.

If `dotnet` is not recognized, install the .NET 8 SDK and reopen PowerShell, or
prepend the directory containing an existing `dotnet.exe` for the current
PowerShell session only. Replace the placeholder with the actual SDK directory:

```powershell
$dotnetRoot = 'C:\path\to\directory-containing-dotnet.exe'
if (-not (Test-Path (Join-Path $dotnetRoot 'dotnet.exe'))) {
    throw "dotnet.exe was not found under $dotnetRoot"
}
$env:PATH = "$dotnetRoot;$env:PATH"
dotnet --info
```

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

### Resource-limited transcription IAM policy template

Replace `ACCOUNT_ID`, `BUCKET` and `INSTALLATION` with the account ID and the
exact resource names displayed by the app. Do not give the client IAM management,
public-ACL or bucket-deletion rights. Existing-resource mode must be explicitly
selected and still passes the same private-storage checks. The real PoC used
this action set with a dedicated sub-user and verified out-of-prefix denial.

```json
{
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["tos:CreateBucket", "tos:HeadBucket", "tos:GetBucketLocation", "tos:GetBucketACL", "tos:GetBucketVersioning", "tos:GetLifecycleConfiguration", "tos:PutLifecycleConfiguration"],
      "Resource": ["trn:tos:cn-beijing:ACCOUNT_ID:BUCKET"]
    },
    {
      "Effect": "Allow",
      "Action": ["tos:PutObject", "tos:GetObject", "tos:DeleteObject"],
      "Resource": ["trn:tos:cn-beijing:ACCOUNT_ID:BUCKET/transcription/v1/INSTALLATION/*"]
    }
  ]
}
```

Initialization rights can be removed after successful initialization; retain
read-only bucket/ACL/versioning checks and the object-prefix rights for normal
verification and operation. Lifecycle is a fallback, not proof of immediate deletion.
