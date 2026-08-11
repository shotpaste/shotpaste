//
//  LegalNoticesView.swift
//  ShotPaste
//
//  Displays the third-party notices bundled with ShotPaste.
//

import SwiftUI

struct LegalNoticesView: View {
  @Environment(\.dismiss) private var dismiss

  private let notices = Self.loadNotices()

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Open Source Licenses")
          .font(.headline)

        Spacer()

        Button("Done") {
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }
      .padding()

      Divider()

      ScrollView {
        Text(notices)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding()
      }
    }
    .frame(minWidth: 620, minHeight: 500)
  }

  private static func loadNotices() -> String {
    guard
      let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "md"),
      let contents = try? String(contentsOf: url, encoding: .utf8)
    else {
      return "The bundled third-party notices could not be loaded."
    }

    return contents
  }
}

#Preview {
  LegalNoticesView()
}
