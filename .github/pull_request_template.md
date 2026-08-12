## Summary

Describe the user-visible outcome and why the change is needed.

## Scope

- Platforms changed: <!-- macOS / Windows / website / shared / docs -->
- Target branch: <!-- main, or release for an approved promotion/hotfix -->
- Release promotion: <!-- None / macos-vX.Y.Z / windows-vX.Y.Z -->
- Related issue: <!-- Fixes #123, if applicable -->
- Intentional platform differences: <!-- None, or explain the OS constraint -->

## Validation

List exact commands and manual scenarios you ran, including the operating
system, architecture, and produced app/package path when platform code changed.

## Checklist

- [ ] The change is focused and contains no unrelated generated artifacts.
- [ ] Tests cover the behavior where practical and all relevant checks pass.
- [ ] Changed native code was built on its native operating system.
- [ ] macOS and Windows behavior remains aligned, or the OS-specific difference is documented.
- [ ] User-facing text is localized in every supported locale and checked with long labels.
- [ ] Accessibility names, keyboard use, and narrow-window layouts were considered.
- [ ] Documentation and release notes were updated when user behavior changed.
- [ ] A `release` promotion contains only completed, selected changes already reviewed on `main`.
- [ ] Logs, screenshots, fixtures, and commits contain no private data or credentials.
- [ ] I reviewed and tested any content produced with automated tools.

## Evidence and known limits

Add screenshots or recordings only when they are sanitized. State anything you
could not verify so reviewers can reproduce the remaining checks.
