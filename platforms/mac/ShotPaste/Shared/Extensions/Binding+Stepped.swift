//
//  Binding+Stepped.swift
//  ShotPaste
//
//  Binding extension to enable step snapping and clamping on sliders
//  without showing native macOS tick marks.
//

import SwiftUI

extension Binding where Value == CGFloat {
  func stepped(by step: CGFloat, in range: ClosedRange<CGFloat>) -> Binding<CGFloat> {
    Binding(
      get: { self.wrappedValue },
      set: { newValue in
        let snapped = (newValue / step).rounded() * step
        self.wrappedValue = Swift.min(Swift.max(snapped, range.lowerBound), range.upperBound)
      }
    )
  }
}

extension Binding where Value == Double {
  func stepped(by step: Double, in range: ClosedRange<Double>) -> Binding<Double> {
    Binding(
      get: { self.wrappedValue },
      set: { newValue in
        let snapped = (newValue / step).rounded() * step
        self.wrappedValue = Swift.min(Swift.max(snapped, range.lowerBound), range.upperBound)
      }
    )
  }
}

extension Binding where Value == Float {
  func stepped(by step: Float, in range: ClosedRange<Float>) -> Binding<Float> {
    Binding(
      get: { self.wrappedValue },
      set: { newValue in
        let snapped = (newValue / step).rounded() * step
        self.wrappedValue = Swift.min(Swift.max(snapped, range.lowerBound), range.upperBound)
      }
    )
  }
}
