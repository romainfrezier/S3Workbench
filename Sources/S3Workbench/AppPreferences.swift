import Foundation
import Observation
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
  case light
  case system
  case dark

  var id: Self { self }

  var label: String { rawValue.capitalized }

  var colorScheme: ColorScheme? {
    switch self {
    case .light: .light
    case .system: nil
    case .dark: .dark
    }
  }
}

enum DownloadDestinationPreference: String, CaseIterable, Identifiable {
  case alwaysAsk
  case downloads

  var id: Self { self }
  var label: String { self == .alwaysAsk ? "Always Ask" : "Downloads" }

  func directory(from downloadsDirectories: [URL]) -> URL? {
    self == .downloads ? downloadsDirectories.first : nil
  }
}

enum SafeCollisionPreference: String, CaseIterable, Identifiable {
  case alwaysAsk
  case keepBoth

  var id: Self { self }
  var label: String { self == .alwaysAsk ? "Always Ask" : "Keep Both" }
}

enum SignedURLLifetime: Int, CaseIterable, Identifiable {
  case fifteenMinutes = 900
  case oneHour = 3_600
  case fourHours = 14_400
  case oneDay = 86_400

  var id: Self { self }

  var label: String {
    switch self {
    case .fifteenMinutes: "15 minutes"
    case .oneHour: "1 hour"
    case .fourHours: "4 hours"
    case .oneDay: "24 hours"
    }
  }

  var duration: Duration { .seconds(rawValue) }
}

@MainActor
@Observable
final class AppPreferences {
  private enum Key {
    static let appearance = "appearance"
    static let downloadDestination = "downloadDestination"
    static let downloadCollision = "downloadCollision"
    static let uploadCollision = "uploadCollision"
    static let signedURLLifetime = "signedURLLifetime"
  }

  @ObservationIgnored private let defaults: UserDefaults

  var appearance: AppAppearance { didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) } }
  var downloadDestination: DownloadDestinationPreference {
    didSet { defaults.set(downloadDestination.rawValue, forKey: Key.downloadDestination) }
  }
  var downloadCollision: SafeCollisionPreference {
    didSet { defaults.set(downloadCollision.rawValue, forKey: Key.downloadCollision) }
  }
  var uploadCollision: SafeCollisionPreference {
    didSet { defaults.set(uploadCollision.rawValue, forKey: Key.uploadCollision) }
  }
  var signedURLLifetime: SignedURLLifetime {
    didSet { defaults.set(signedURLLifetime.rawValue, forKey: Key.signedURLLifetime) }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    appearance = AppAppearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
    downloadDestination = DownloadDestinationPreference(
      rawValue: defaults.string(forKey: Key.downloadDestination) ?? "") ?? .alwaysAsk
    downloadCollision = SafeCollisionPreference(
      rawValue: defaults.string(forKey: Key.downloadCollision) ?? "") ?? .alwaysAsk
    uploadCollision = SafeCollisionPreference(
      rawValue: defaults.string(forKey: Key.uploadCollision) ?? "") ?? .alwaysAsk
    signedURLLifetime = SignedURLLifetime(
      rawValue: defaults.object(forKey: Key.signedURLLifetime) as? Int ?? 3_600) ?? .oneHour
  }
}
