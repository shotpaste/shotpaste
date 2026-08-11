# Support

ShotPaste is a community-maintained open-source project.

## Before opening an issue

1. Read the [README](README.md), [feature list](docs/FEATURES.md), and
   [development guide](docs/DEVELOPMENT.md).
2. Search existing issues and try the latest release when practical.
3. Collect the ShotPaste version, operating-system version, installation
   method, exact steps, and sanitized diagnostics.

Use the repository issue forms for reproducible bugs, feature requests, and
usage questions. Before uploading anything, remove captures, clipboard content,
credentials, signing material, personal file paths, and other private data from
screenshots, recordings, and logs.

Report suspected vulnerabilities privately according to
[SECURITY.md](SECURITY.md).

## macOS diagnostics

Collect recent crash reports and sanitized error logs with:

```bash
./scripts/collect-crash-logs.sh
```

If privacy permissions become inconsistent, read the signing guidance in
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) before using the interactive reset
helper:

```bash
./scripts/reset-permissions.sh
```

The uninstall helper can remove the installed app and optionally its local
data. Read its prompts carefully because capture and clipboard history may be
deleted:

```bash
./scripts/uninstall.sh
```
