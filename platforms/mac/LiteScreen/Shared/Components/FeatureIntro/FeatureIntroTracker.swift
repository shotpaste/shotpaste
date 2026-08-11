//
//  FeatureIntroTracker.swift
//  LiteScreen
//
//  Centralized tracking for feature introduction campaigns.
//  Uses a single UserDefaults array to prevent surplus keys.
//

import Foundation

public final class FeatureIntroTracker {
  public static let shared = FeatureIntroTracker()

  private let storageKey = "seenFeatureCampaigns"
  private let defaults = UserDefaults.standard

  private init() {}

  /// Checks if a specific feature campaign has been seen by the user.
  public func hasSeen(campaignId: String) -> Bool {
    let seenCampaigns = defaults.stringArray(forKey: storageKey) ?? []
    return seenCampaigns.contains(campaignId)
  }

  /// Marks a specific feature campaign as seen.
  public func markAsSeen(campaignId: String) {
    var seenCampaigns = defaults.stringArray(forKey: storageKey) ?? []
    if !seenCampaigns.contains(campaignId) {
      seenCampaigns.append(campaignId)
      defaults.set(seenCampaigns, forKey: storageKey)
    }
  }

  /// Clears out old campaigns from the array, keeping only the active ones.
  /// This acts as a garbage collection mechanism.
  public func clearOldCampaigns(keeping activeIds: [String]) {
    guard let seenCampaigns = defaults.stringArray(forKey: storageKey) else { return }

    let activeSeenCampaigns = seenCampaigns.filter { activeIds.contains($0) }
    defaults.set(activeSeenCampaigns, forKey: storageKey)
  }
}
