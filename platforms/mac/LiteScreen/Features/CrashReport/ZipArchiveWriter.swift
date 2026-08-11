//
//  ZipArchiveWriter.swift
//  LiteScreen
//
//  Minimal ZIP writer for bundling diagnostic text logs without external tools.
//

import Compression
import Foundation

enum ZipArchiveWriter {
  struct Entry {
    let name: String
    let data: Data
    let modificationDate: Date
  }

  static func write(entries: [Entry], to url: URL) throws {
    var archive = Data()
    var centralDirectory = Data()

    for entry in entries {
      let nameData = Data(entry.name.utf8)
      let payload = compressedPayload(for: entry.data)
      let crc = CRC32.checksum(entry.data)
      let sizes = try zipSizes(compressedData: payload.data, uncompressedData: entry.data, nameData: nameData)
      let offset = UInt32(archive.count)
      let timestamp = ZipTimestamp(date: entry.modificationDate)

      archive.appendUInt32LE(0x04034b50)
      archive.appendUInt16LE(20)
      archive.appendUInt16LE(0x0800)
      archive.appendUInt16LE(payload.compressionMethod)
      archive.appendUInt16LE(timestamp.time)
      archive.appendUInt16LE(timestamp.date)
      archive.appendUInt32LE(crc)
      archive.appendUInt32LE(sizes.compressed)
      archive.appendUInt32LE(sizes.uncompressed)
      archive.appendUInt16LE(sizes.name)
      archive.appendUInt16LE(0)
      archive.append(nameData)
      archive.append(payload.data)

      centralDirectory.appendUInt32LE(0x02014b50)
      centralDirectory.appendUInt16LE(20)
      centralDirectory.appendUInt16LE(20)
      centralDirectory.appendUInt16LE(0x0800)
      centralDirectory.appendUInt16LE(payload.compressionMethod)
      centralDirectory.appendUInt16LE(timestamp.time)
      centralDirectory.appendUInt16LE(timestamp.date)
      centralDirectory.appendUInt32LE(crc)
      centralDirectory.appendUInt32LE(sizes.compressed)
      centralDirectory.appendUInt32LE(sizes.uncompressed)
      centralDirectory.appendUInt16LE(sizes.name)
      centralDirectory.appendUInt16LE(0)
      centralDirectory.appendUInt16LE(0)
      centralDirectory.appendUInt16LE(0)
      centralDirectory.appendUInt16LE(0)
      centralDirectory.appendUInt32LE(0)
      centralDirectory.appendUInt32LE(offset)
      centralDirectory.append(nameData)
    }

    let centralDirectoryOffset = UInt32(archive.count)
    let centralDirectorySize = UInt32(centralDirectory.count)
    archive.append(centralDirectory)
    archive.appendUInt32LE(0x06054b50)
    archive.appendUInt16LE(0)
    archive.appendUInt16LE(0)
    archive.appendUInt16LE(UInt16(entries.count))
    archive.appendUInt16LE(UInt16(entries.count))
    archive.appendUInt32LE(centralDirectorySize)
    archive.appendUInt32LE(centralDirectoryOffset)
    archive.appendUInt16LE(0)

    try archive.write(to: url, options: .atomic)
  }

  private static func zipSizes(
    compressedData: Data,
    uncompressedData: Data,
    nameData: Data
  ) throws -> (compressed: UInt32, uncompressed: UInt32, name: UInt16) {
    guard
      compressedData.count <= Int(UInt32.max),
      uncompressedData.count <= Int(UInt32.max),
      nameData.count <= Int(UInt16.max)
    else {
      throw CocoaError(.fileWriteOutOfSpace)
    }
    return (UInt32(compressedData.count), UInt32(uncompressedData.count), UInt16(nameData.count))
  }

  private static func compressedPayload(for data: Data) -> (data: Data, compressionMethod: UInt16) {
    guard let deflated = deflatedData(for: data), deflated.count < data.count else {
      return (data, 0)
    }
    return (deflated, 8)
  }

  private static func deflatedData(for data: Data) -> Data? {
    guard !data.isEmpty else { return nil }
    var destination = [UInt8](repeating: 0, count: max(64, data.count * 2 + 64))

    let encodedCount = data.withUnsafeBytes { sourceBuffer -> Int in
      guard let source = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
      return compression_encode_buffer(
        &destination,
        destination.count,
        source,
        data.count,
        nil,
        COMPRESSION_ZLIB
      )
    }

    guard encodedCount > 0 else { return nil }
    return Data(destination[0 ..< encodedCount])
  }
}

private struct ZipTimestamp {
  let time: UInt16
  let date: UInt16

  init(date sourceDate: Date) {
    let calendar = Calendar.current
    let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: sourceDate)
    let year = min(max(components.year ?? 1980, 1980), 2107)
    let month = min(max(components.month ?? 1, 1), 12)
    let day = min(max(components.day ?? 1, 1), 31)
    let hour = min(max(components.hour ?? 0, 0), 23)
    let minute = min(max(components.minute ?? 0, 0), 59)
    let second = min(max(components.second ?? 0, 0), 59)

    time = UInt16((hour << 11) | (minute << 5) | (second / 2))
    date = UInt16(((year - 1980) << 9) | (month << 5) | day)
  }
}

private enum CRC32 {
  private static let table: [UInt32] = (0 ..< 256).map { value in
    var crc = UInt32(value)
    for _ in 0 ..< 8 {
      crc = (crc & 1) == 1 ? (0xedb88320 ^ (crc >> 1)) : (crc >> 1)
    }
    return crc
  }

  static func checksum(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xffffffff
    for byte in data {
      let index = Int((crc ^ UInt32(byte)) & 0xff)
      crc = table[index] ^ (crc >> 8)
    }
    return crc ^ 0xffffffff
  }
}

private extension Data {
  mutating func appendUInt16LE(_ value: UInt16) {
    var littleEndian = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
  }

  mutating func appendUInt32LE(_ value: UInt32) {
    var littleEndian = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
  }
}
