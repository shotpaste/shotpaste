//
//  NSCursor+OneShot.swift
//  LiteScreen
//

import AppKit

extension NSCursor {
  static let vectorScreenshotCrosshairLight: NSCursor = {
    let size = NSSize(width: 32, height: 32)
    let image = NSImage(size: size)
    image.isTemplate = false
    image.lockFocus()
    defer { image.unlockFocus() }

    NSColor.clear.setFill()
    NSRect(origin: .zero, size: size).fill()

    let verticalPath = NSBezierPath()
    verticalPath.move(to: NSPoint(x: 15.5, y: 5))
    verticalPath.line(to: NSPoint(x: 15.5, y: 16))
    verticalPath.move(to: NSPoint(x: 15.5, y: 17))
    verticalPath.line(to: NSPoint(x: 15.5, y: 28))

    let horizontalPath = NSBezierPath()
    horizontalPath.move(to: NSPoint(x: 4, y: 16.5))
    horizontalPath.line(to: NSPoint(x: 15, y: 16.5))
    horizontalPath.move(to: NSPoint(x: 16, y: 16.5))
    horizontalPath.line(to: NSPoint(x: 27, y: 16.5))

    let circlePath = NSBezierPath(ovalIn: NSRect(x: 9.5, y: 10.5, width: 12, height: 12))
    NSColor.white.withAlphaComponent(0.15).setFill()
    circlePath.fill()

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -1)
    shadow.shadowBlurRadius = 1

    NSGraphicsContext.current?.saveGraphicsState()
    shadow.set()
    NSColor.white.withAlphaComponent(0.85).setStroke()
    verticalPath.lineWidth = 1
    verticalPath.stroke()
    horizontalPath.lineWidth = 1
    horizontalPath.stroke()
    NSColor.white.withAlphaComponent(0.30).setStroke()
    circlePath.lineWidth = 1
    circlePath.stroke()
    NSGraphicsContext.current?.restoreGraphicsState()

    return NSCursor(image: image, hotSpot: NSPoint(x: 15, y: 15))
  }()
}
