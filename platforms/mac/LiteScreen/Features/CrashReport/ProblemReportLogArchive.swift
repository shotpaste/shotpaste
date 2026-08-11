//
//  ProblemReportLogArchive.swift
//  LiteScreen
//
//  Builds a single draggable zip archive from retained diagnostic log files.
//

import Foundation

enum ProblemReportLogArchive {
  private static let filePrefix = "lite-screen-problem-report-"
  private static let fileExtension = "zip"

  static func makeArchive(from logDirectoryURL: URL, reportURL: URL) throws -> URL {
    DiagnosticLogger.shared.closeHandles()

    let entries = try archiveEntries(from: logDirectoryURL, reportURL: reportURL)
    let archiveURL = try nextArchiveURL()
    try ZipArchiveWriter.write(entries: entries, to: archiveURL)
    return archiveURL
  }

  private static func archiveEntries(from logDirectoryURL: URL, reportURL: URL) throws -> [ZipArchiveWriter.Entry] {
    let fm = FileManager.default
    let logFiles = (try? fm.contentsOfDirectory(
      at: logDirectoryURL,
      includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
      options: [.skipsHiddenFiles]
    )) ?? []

    let diagnosticLogs = logFiles.filter { url in
      guard
        url.lastPathComponent.hasPrefix("litescreen_"),
        url.pathExtension == "txt",
        let resourceValues = try? url.resourceValues(forKeys: [.isRegularFileKey]),
        resourceValues.isRegularFile == true
      else {
        return false
      }
      return true
    }.sorted { $0.lastPathComponent < $1.lastPathComponent }

    let now = Date()
    var entries = [
      ZipArchiveWriter.Entry(
        name: "README.txt",
        data: readmeData(
          logCount: diagnosticLogs.count,
          logDirectoryURL: logDirectoryURL,
          reportURL: reportURL,
          date: now
        ),
        modificationDate: now
      ),
    ]

    for logFile in diagnosticLogs {
      let data = try Data(contentsOf: logFile)
      let modificationDate = (try? logFile.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate) ?? now
      entries.append(
        ZipArchiveWriter.Entry(
          name: "diagnostic-logs/\(logFile.lastPathComponent)",
          data: data,
          modificationDate: modificationDate
        )
      )
    }

    return entries
  }

  private static func nextArchiveURL() throws -> URL {
    let fm = FileManager.default
    let directory = fm.temporaryDirectory.appendingPathComponent("Lite ScreenProblemReports", isDirectory: true)
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    cleanupOldArchives(in: directory)

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    let fileName = "\(filePrefix)\(formatter.string(from: Date())).\(fileExtension)"
    return directory.appendingPathComponent(fileName)
  }

  private static func cleanupOldArchives(in directory: URL) {
    let fm = FileManager.default
    guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
    for file in files where file.lastPathComponent.hasPrefix(filePrefix) && file.pathExtension == fileExtension {
      try? fm.removeItem(at: file)
    }
  }

  private static func readmeData(logCount: Int, logDirectoryURL: URL, reportURL: URL, date: Date) -> Data {
    let formatter = ISO8601DateFormatter()
    let text = """
    LiteScreen problem report log bundle
    Generated: \(formatter.string(from: date))
    Included diagnostic log files: \(logCount)
    Source log folder: \(logDirectoryURL.path)
    Report page: \(reportURL.absoluteString)

    Drag this zip file to the report page when requested.
    """
    return Data(text.utf8)
  }
}
