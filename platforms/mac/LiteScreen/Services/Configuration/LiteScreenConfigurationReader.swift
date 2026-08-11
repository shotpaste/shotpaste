//
//  LiteScreenConfigurationReader.swift
//  LiteScreen
//
//  Typed reads with validation issue collection for imported TOML.
//

import Foundation

struct LiteScreenConfigurationReader {
  let document: SimpleTOMLDocument
  var issues: [LiteScreenConfigurationIssue] = []

  mutating func string(_ path: String...) -> String? {
    string(path)
  }

  mutating func string(_ path: [String]) -> String? {
    guard let value = document.value(at: path) else { return nil }
    guard let string = value.stringValue else {
      error("\(path.joined(separator: ".")) must be a string")
      return nil
    }
    return string
  }

  mutating func bool(_ path: String...) -> Bool? {
    bool(path)
  }

  mutating func bool(_ path: [String]) -> Bool? {
    guard let value = document.value(at: path) else { return nil }
    guard let bool = value.boolValue else {
      error("\(path.joined(separator: ".")) must be a boolean")
      return nil
    }
    return bool
  }

  mutating func int(_ path: String...) -> Int? {
    int(path)
  }

  mutating func int(_ path: [String]) -> Int? {
    guard let value = document.value(at: path) else { return nil }
    guard let int = value.intValue else {
      error("\(path.joined(separator: ".")) must be an integer")
      return nil
    }
    return int
  }

  mutating func double(_ path: String...) -> Double? {
    double(path)
  }

  mutating func double(_ path: [String]) -> Double? {
    guard let value = document.value(at: path) else { return nil }
    guard let double = value.doubleValue else {
      error("\(path.joined(separator: ".")) must be a number")
      return nil
    }
    return double
  }

  mutating func stringArray(_ path: String...) -> [String]? {
    stringArray(path)
  }

  mutating func stringArray(_ path: [String]) -> [String]? {
    guard let value = document.value(at: path) else { return nil }
    guard let array = value.stringArrayValue else {
      error("\(path.joined(separator: ".")) must be an array of strings")
      return nil
    }
    return array
  }

  mutating func error(_ message: String) {
    issues.append(LiteScreenConfigurationIssue(severity: .error, message: message))
  }

  mutating func warning(_ message: String) {
    issues.append(LiteScreenConfigurationIssue(severity: .warning, message: message))
  }
}
