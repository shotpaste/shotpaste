//
//  SimpleTOMLParser.swift
//  ShotPaste
//
//  Small TOML parser for ShotPaste config import. It supports comments, nested
//  tables, dotted keys, strings, booleans, numbers, and arrays.
//

import Foundation

enum SimpleTOMLParser {
  static func parse(_ source: String) throws -> SimpleTOMLDocument {
    var document = SimpleTOMLDocument()
    var currentPath: [String] = []

    for (index, rawLine) in source.components(separatedBy: .newlines).enumerated() {
      let lineNumber = index + 1
      let line = stripComment(from: rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty else { continue }

      if line.hasPrefix("[") {
        guard line.hasSuffix("]"), !line.hasPrefix("[[") else {
          throw SimpleTOMLError.invalidLine(lineNumber, rawLine)
        }
        let inner = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        currentPath = try parseKeyPath(inner)
        try document.ensureTable(at: currentPath)
        continue
      }

      let parts = splitAssignment(line)
      guard let keyText = parts.key, let valueText = parts.value else {
        throw SimpleTOMLError.invalidLine(lineNumber, rawLine)
      }

      let keyPath = try currentPath + parseKeyPath(keyText)
      let value = try parseValue(valueText.trimmingCharacters(in: .whitespacesAndNewlines), line: lineNumber)
      try document.set(value, at: keyPath)
    }

    return document
  }

  private static func splitAssignment(_ line: String) -> (key: String?, value: String?) {
    var isInString = false
    var isEscaped = false

    for index in line.indices {
      let character = line[index]
      if isEscaped {
        isEscaped = false
        continue
      }
      if character == "\\" {
        isEscaped = isInString
        continue
      }
      if character == "\"" {
        isInString.toggle()
        continue
      }
      if character == "=", !isInString {
        let key = String(line[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
        let value = String(line[line.index(after: index)...])
        return (key, value)
      }
    }

    return (nil, nil)
  }

  private static func stripComment(from line: String) -> String {
    var result = ""
    var isInString = false
    var isEscaped = false

    for character in line {
      if isEscaped {
        result.append(character)
        isEscaped = false
        continue
      }
      if character == "\\" {
        result.append(character)
        isEscaped = isInString
        continue
      }
      if character == "\"" {
        result.append(character)
        isInString.toggle()
        continue
      }
      if character == "#", !isInString {
        break
      }
      result.append(character)
    }

    return result
  }

  private static func parseKeyPath(_ key: String) throws -> [String] {
    let parts = key.split(separator: ".").map {
      String($0).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty }) else {
      throw SimpleTOMLError.invalidKey(key)
    }
    return parts.map { part in
      if part.hasPrefix("\""), part.hasSuffix("\"") {
        return String(part.dropFirst().dropLast())
      }
      return part
    }
  }

  private static func parseValue(_ value: String, line: Int) throws -> SimpleTOMLValue {
    if value.hasPrefix("\"") {
      guard value.hasSuffix("\"") else { throw SimpleTOMLError.invalidValue(line, value) }
      return .string(unescape(String(value.dropFirst().dropLast())))
    }
    if value == "true" {
      return .bool(true)
    }
    if value == "false" {
      return .bool(false)
    }
    if value.hasPrefix("[") {
      guard value.hasSuffix("]") else { throw SimpleTOMLError.invalidValue(line, value) }
      let inner = String(value.dropFirst().dropLast())
      let values = try splitArray(inner).map { try parseValue($0, line: line) }
      return .array(values)
    }
    if let intValue = Int(value) {
      return .integer(intValue)
    }
    if let doubleValue = Double(value) {
      return .double(doubleValue)
    }
    throw SimpleTOMLError.invalidValue(line, value)
  }

  private static func splitArray(_ value: String) throws -> [String] {
    var result: [String] = []
    var current = ""
    var isInString = false
    var isEscaped = false
    var depth = 0

    for character in value {
      if isEscaped {
        current.append(character)
        isEscaped = false
        continue
      }
      if character == "\\" {
        current.append(character)
        isEscaped = isInString
        continue
      }
      if character == "\"" {
        current.append(character)
        isInString.toggle()
        continue
      }
      if character == "[", !isInString {
        depth += 1
      }
      if character == "]", !isInString {
        depth -= 1
      }
      if character == ",", !isInString, depth == 0 {
        let item = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !item.isEmpty {
          result.append(item)
        }
        current = ""
        continue
      }
      current.append(character)
    }

    let item = current.trimmingCharacters(in: .whitespacesAndNewlines)
    if !item.isEmpty {
      result.append(item)
    }
    return result
  }

  private static func unescape(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\\"", with: "\"")
      .replacingOccurrences(of: "\\\\", with: "\\")
      .replacingOccurrences(of: "\\n", with: "\n")
      .replacingOccurrences(of: "\\t", with: "\t")
  }
}
