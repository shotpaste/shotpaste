//
//  DatabaseManagerTests.swift
//  LiteScreenTests
//
//  Tests for local capture-history database initialization and recovery helpers.
//

import Foundation
import GRDB
@testable import LiteScreen
import XCTest

final class DatabaseManagerTests: XCTestCase {
  private var testDirectory: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    testDirectory = try Self.makeWritableTestDirectory()
  }

  override func tearDownWithError() throws {
    if let testDirectory {
      try? FileManager.default.removeItem(at: testDirectory)
    }
    try super.tearDownWithError()
  }

  func testOpenDatabase_createsDatabaseWithoutThrowing() throws {
    let databaseURL = testDirectory.appendingPathComponent("litescreen.db")

    let manager = try DatabaseManager.openDatabase(at: databaseURL)
    XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))

    let userTables = try manager.dbPool.read { db in
      try String.fetchAll(
        db,
        sql: """
        SELECT name
        FROM sqlite_master
        WHERE type = 'table'
          AND name NOT LIKE 'sqlite_%'
          AND name != 'grdb_migrations'
        ORDER BY name
        """
      )
    }
    XCTAssertEqual(userTables, ["captureHistoryRecord"])
  }

  func testOpenDatabase_corruptFileThrowsInitializationError() throws {
    let databaseURL = testDirectory.appendingPathComponent("litescreen.db")
    try Data("CORRUPT".utf8).write(to: databaseURL)

    XCTAssertThrowsError(try DatabaseManager.openDatabase(at: databaseURL)) { error in
      guard case DatabaseInitializationError.openOrMigrationFailed = error else {
        return XCTFail("Expected openOrMigrationFailed, got \(error)")
      }
    }
  }

  func testArchiveDatabaseFiles_movesDatabaseAndSidecars() throws {
    let fileNames = ["litescreen.db", "litescreen.db-wal", "litescreen.db-shm"]
    for fileName in fileNames {
      let fileURL = testDirectory.appendingPathComponent(fileName)
      try Data(fileName.utf8).write(to: fileURL)
    }

    let archive = try DatabaseManager.archiveDatabaseFilesForTesting(
      in: testDirectory,
      fileNames: fileNames,
      timestamp: "20260605-204500"
    )

    XCTAssertEqual(archive.archivedFileURLs.count, fileNames.count)
    XCTAssertEqual(archive.archiveDirectoryURL?.lastPathComponent, "DatabaseRecovery-20260605-204500")

    for fileName in fileNames {
      XCTAssertFalse(FileManager.default.fileExists(atPath: testDirectory.appendingPathComponent(fileName).path))
      XCTAssertTrue(
        FileManager.default.fileExists(
          atPath: testDirectory
            .appendingPathComponent("DatabaseRecovery-20260605-204500", isDirectory: true)
            .appendingPathComponent(fileName)
            .path
        )
      )
    }
  }

  func testArchiveDatabaseFiles_usesSuffixWhenArchiveDirectoryAlreadyExists() throws {
    let databaseURL = testDirectory.appendingPathComponent("litescreen.db")
    try Data("db".utf8).write(to: databaseURL)

    let existingArchiveURL = testDirectory
      .appendingPathComponent("DatabaseRecovery-20260605-204500", isDirectory: true)
    try FileManager.default.createDirectory(at: existingArchiveURL, withIntermediateDirectories: true)

    let archive = try DatabaseManager.archiveDatabaseFilesForTesting(
      in: testDirectory,
      fileNames: ["litescreen.db"],
      timestamp: "20260605-204500"
    )

    XCTAssertEqual(archive.archiveDirectoryURL?.lastPathComponent, "DatabaseRecovery-20260605-204500-2")
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: testDirectory
          .appendingPathComponent("DatabaseRecovery-20260605-204500-2", isDirectory: true)
          .appendingPathComponent("litescreen.db")
          .path
      )
    )
  }

  private static func makeWritableTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("LiteScreenTests_DatabaseManager", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)

    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let probeURL = directory.appendingPathComponent(".write-probe")
      try Data("ok".utf8).write(to: probeURL, options: [.atomic])
      try FileManager.default.removeItem(at: probeURL)
      return directory
    } catch {
      throw XCTSkip(
        "DatabaseManagerTests require a writable temporary directory: \(error.localizedDescription)"
      )
    }
  }
}
