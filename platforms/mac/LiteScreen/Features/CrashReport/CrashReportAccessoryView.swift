//
//  CrashReportAccessoryView.swift
//  LiteScreen
//
//  Draggable file icon for the problem report alert — users can drag-and-drop
//  the diagnostic log bundle directly onto a browser upload field.
//

import AppKit
import UniformTypeIdentifiers

final class CrashReportAccessoryView: NSView {
  private let fileURL: URL

  // MARK: - Init

  init(fileURL: URL) {
    self.fileURL = fileURL
    super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 72))
    setupUI()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError()
  }

  // MARK: - UI

  private func setupUI() {
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.borderWidth = 1
    layer?.borderColor = NSColor.separatorColor.cgColor
    layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

    // File icon (draggable)
    let icon = DraggableFileView(fileURL: fileURL)
    icon.translatesAutoresizingMaskIntoConstraints = false
    addSubview(icon)

    // File name label
    let nameLabel = NSTextField(labelWithString: fileURL.lastPathComponent)
    nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
    nameLabel.textColor = .labelColor
    nameLabel.lineBreakMode = .byTruncatingMiddle
    nameLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(nameLabel)

    // Hint label
    let hintLabel = NSTextField(labelWithString: L10n.CrashReport.accessoryHint)
    hintLabel.font = .systemFont(ofSize: 11)
    hintLabel.textColor = .secondaryLabelColor
    hintLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(hintLabel)

    NSLayoutConstraint.activate([
      icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      icon.centerYAnchor.constraint(equalTo: centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 40),
      icon.heightAnchor.constraint(equalToConstant: 40),

      nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
      nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
      nameLabel.topAnchor.constraint(equalTo: icon.topAnchor, constant: 2),

      hintLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
      hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
      hintLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
    ])
  }
}

// MARK: - DraggableFileView

/// Displays a file icon and acts as a drag source providing the file URL.
private final class DraggableFileView: NSImageView, NSDraggingSource {
  private let fileURL: URL

  init(fileURL: URL) {
    self.fileURL = fileURL
    super.init(frame: .zero)

    let icon = NSWorkspace.shared.icon(forFile: fileURL.path)
    icon.size = NSSize(width: 40, height: 40)
    image = icon
    isEditable = false
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError()
  }

  // MARK: - Mouse Drag

  override func mouseDown(with event: NSEvent) {
    // Begin dragging session
    let pasteboardItem = NSPasteboardItem()
    pasteboardItem.setString(fileURL.absoluteString, forType: .fileURL)

    let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
    let iconImage = image ?? NSImage()
    draggingItem.setDraggingFrame(bounds, contents: iconImage)

    beginDraggingSession(with: [draggingItem], event: event, source: self)
  }

  // MARK: - NSDraggingSource

  func draggingSession(
    _: NSDraggingSession,
    sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    context == .outsideApplication ? .copy : .copy
  }
}
