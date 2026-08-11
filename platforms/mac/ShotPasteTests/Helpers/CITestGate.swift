//
//  CITestGate.swift
//  ShotPasteTests
//
//  Shared gate for interaction / nondeterministic tests. Tests that exercise
//  real UI surfaces (NSSavePanel, NSPasteboard, drag-to-app), async ML/OCR
//  pipelines, GPU rendering, or window lifecycle call `try skipIfRunningInCI()`
//  as their FIRST line so CI runs stay deterministic while the tests remain
//  runnable locally.
//
//  NOTE ON CI SKIPPING: `xcodebuild test` does NOT forward the shell's `CI` /
//  `GITHUB_ACTIONS` env vars to the separate XCTest host process, so this
//  runtime gate does NOT trip during `xcodebuild test` in GitHub Actions.
//  Guaranteed CI skipping is done by the `SHOTPASTE_CI_SKIP_TESTS` allowlist in
//  .github/workflows/ci.yml (passed as `-skip-testing:` identifiers). Any test
//  calling `skipIfRunningInCI()` MUST also be listed there. This gate remains
//  as defense-in-depth: it trips when env IS forwarded (Xcode scheme env, or a
//  `TEST_RUNNER_CI=1` / `CI=1` value the runner actually sees), and documents
//  intent at the call site.
//

import XCTest

extension XCTestCase {
  /// Skip the calling test when running under CI. Interaction / nondeterministic
  /// tests must call this as their first statement.
  func skipIfRunningInCI(
    _ message: String = "interaction/nondeterministic test skipped in CI",
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let environment = ProcessInfo.processInfo.environment
    let isRunningInCI = environment["CI"] != nil || environment["GITHUB_ACTIONS"] != nil
    try XCTSkipIf(isRunningInCI, message, file: file, line: line)
  }
}
