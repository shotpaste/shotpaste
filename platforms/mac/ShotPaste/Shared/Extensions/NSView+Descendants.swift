//
//  NSView+Descendants.swift
//  ShotPaste
//
//  View-hierarchy lookup helpers.
//

import AppKit

extension NSView {
  /// Depth-first search for the first descendant (excluding self) of the given type.
  func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
    for subview in subviews {
      if let match = subview as? T {
        return match
      }
      if let match = subview.firstDescendant(ofType: type) {
        return match
      }
    }
    return nil
  }
}
