//
//  LazyView.swift
//  ShotPaste
//
//  Defers SwiftUI view initialization until the view is rendered.
//  Used in TabView to avoid eagerly instantiating all tabs at once.
//

import SwiftUI

/// A wrapper that delays the creation of its content until `body` is evaluated.
/// This prevents expensive initialization (onAppear, @ObservedObject subscriptions)
/// from running for views that aren't yet visible.
struct LazyView<Content: View>: View {
  let build: () -> Content

  init(_ build: @autoclosure @escaping () -> Content) {
    self.build = build
  }

  var body: some View {
    build()
  }
}
