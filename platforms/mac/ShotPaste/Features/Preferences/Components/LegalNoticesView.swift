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
        Text(L10n.PreferencesAdvanced.licensesTitle)
          .font(.headline)

        Spacer()

        Button(L10n.Common.done) {
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
      return L10n.PreferencesAdvanced.noticesUnavailable
    }

    return contents
  }
}

#Preview {
  LegalNoticesView()
}
