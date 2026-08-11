//
//  FeatureIntroConfig.swift
//  LiteScreen
//
//  Data models for Feature Introduction campaigns driven by JSON.
//

import Foundation

public struct FeatureIntroRootConfig: Codable {
  public let campaigns: [FeatureIntroCampaign]
}

public struct FeatureIntroCampaign: Codable, Equatable {
  public let id: String
  public let isEnabled: Bool
  public let menuTitle: String?
  public let screens: [FeatureIntroScreenConfig]
}

public struct FeatureIntroScreenConfig: Codable, Equatable {
  public let id: String
  public let title: String
  public let description: String
  public let systemImage: String?
  public let customImageName: String?
  public let shortcutKeys: [String]?
  public let actionTitle: String?
  public let actionId: String?
  public let nextActionTitle: String?
}
