import Foundation
import SwiftUI

public struct FeatureIntroScreen: Identifiable {
  public let id: String
  public let title: String
  public let description: String
  public let systemImage: String?
  public let customImageName: String?
  public let shortcutKeys: [String]?
  public let actionTitle: String?
  public let action: (() -> Void)?
  public let nextActionTitle: String?

  public init(
    id: String = UUID().uuidString,
    title: String,
    description: String,
    systemImage: String? = nil,
    customImageName: String? = nil,
    shortcutKeys: [String]? = nil,
    actionTitle: String? = nil,
    action: (() -> Void)? = nil,
    nextActionTitle: String? = nil
  ) {
    self.id = id
    self.title = title
    self.description = description
    self.systemImage = systemImage
    self.customImageName = customImageName
    self.shortcutKeys = shortcutKeys
    self.actionTitle = actionTitle
    self.action = action
    self.nextActionTitle = nextActionTitle
  }
}
