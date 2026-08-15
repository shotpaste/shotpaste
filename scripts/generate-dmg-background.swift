#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
  FileHandle.standardError.write(
    Data("Usage: generate-dmg-background.swift OUTPUT_PNG VERSION\n".utf8)
  )
  exit(2)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
_ = CommandLine.arguments[2]
let canvasSize = NSSize(width: 660, height: 420)
let image = NSImage(size: canvasSize)

image.lockFocus()

let canvasRect = NSRect(origin: .zero, size: canvasSize)
let backgroundGradient = NSGradient(colors: [
  NSColor(calibratedRed: 0.055, green: 0.071, blue: 0.110, alpha: 1),
  NSColor(calibratedRed: 0.105, green: 0.129, blue: 0.190, alpha: 1),
])!
backgroundGradient.draw(in: canvasRect, angle: 90)

let accentGradient = NSGradient(colors: [
  NSColor(calibratedRed: 0.455, green: 0.675, blue: 1, alpha: 0.24),
  NSColor(calibratedRed: 0.500, green: 0.360, blue: 1, alpha: 0.06),
])!
accentGradient.draw(
  in: NSBezierPath(roundedRect: NSRect(x: 42, y: 82, width: 576, height: 238), xRadius: 28, yRadius: 28),
  angle: 0
)

NSColor.white.withAlphaComponent(0.68).setFill()
NSBezierPath(roundedRect: NSRect(x: 113, y: 105, width: 124, height: 30), xRadius: 15, yRadius: 15).fill()
NSBezierPath(roundedRect: NSRect(x: 423, y: 105, width: 124, height: 30), xRadius: 15, yRadius: 15).fill()

func drawCenteredText(
  _ value: String,
  y: CGFloat,
  font: NSFont,
  color: NSColor,
  width: CGFloat = canvasSize.width
) {
  let style = NSMutableParagraphStyle()
  style.alignment = .center
  let attributes: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: color,
    .paragraphStyle: style,
  ]
  let rect = NSRect(x: (canvasSize.width - width) / 2, y: y, width: width, height: 40)
  value.draw(in: rect, withAttributes: attributes)
}

drawCenteredText(
  "Drag ShotPaste to Applications",
  y: 357,
  font: .systemFont(ofSize: 24, weight: .semibold),
  color: .white
)
drawCenteredText(
  "将 ShotPaste 拖到“应用程序”文件夹",
  y: 326,
  font: .systemFont(ofSize: 15, weight: .medium),
  color: NSColor.white.withAlphaComponent(0.72)
)

let context = NSGraphicsContext.current!.cgContext
context.saveGState()
context.setStrokeColor(NSColor(calibratedRed: 0.470, green: 0.720, blue: 1, alpha: 0.95).cgColor)
context.setFillColor(NSColor(calibratedRed: 0.470, green: 0.720, blue: 1, alpha: 0.95).cgColor)
context.setLineWidth(7)
context.setLineCap(.round)
context.move(to: CGPoint(x: 270, y: 211))
context.addLine(to: CGPoint(x: 390, y: 211))
context.strokePath()
context.move(to: CGPoint(x: 390, y: 211))
context.addLine(to: CGPoint(x: 368, y: 226))
context.addLine(to: CGPoint(x: 368, y: 196))
context.closePath()
context.fillPath()
context.restoreGState()

image.unlockFocus()

guard
  let tiffData = image.tiffRepresentation,
  let bitmap = NSBitmapImageRep(data: tiffData),
  let pngData = bitmap.representation(using: .png, properties: [:])
else {
  FileHandle.standardError.write(Data("Unable to render DMG background.\n".utf8))
  exit(1)
}

do {
  try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try pngData.write(to: outputURL, options: .atomic)
} catch {
  FileHandle.standardError.write(Data("Unable to write DMG background: \(error)\n".utf8))
  exit(1)
}
