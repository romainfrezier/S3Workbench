import Foundation
import Testing
@testable import S3Workbench

@MainActor
@Test func appPreferencesUseSafeDefaultsAndPersistSelections() throws {
  let suiteName = "S3WorkbenchTests.AppPreferences.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defer { defaults.removePersistentDomain(forName: suiteName) }

  let initial = AppPreferences(defaults: defaults)
  #expect(initial.appearance == .system)
  #expect(initial.downloadDestination == .alwaysAsk)
  #expect(initial.downloadCollision == .alwaysAsk)
  #expect(initial.uploadCollision == .alwaysAsk)
  #expect(initial.signedURLLifetime == .oneHour)

  initial.appearance = .dark
  initial.downloadDestination = .downloads
  initial.downloadCollision = .keepBoth
  initial.uploadCollision = .keepBoth
  initial.signedURLLifetime = .oneDay

  let reloaded = AppPreferences(defaults: defaults)
  #expect(reloaded.appearance == .dark)
  #expect(reloaded.downloadDestination == .downloads)
  #expect(reloaded.downloadCollision == .keepBoth)
  #expect(reloaded.uploadCollision == .keepBoth)
  #expect(reloaded.signedURLLifetime == .oneDay)
}

@MainActor
@Test func appPreferencesIgnoreUnsupportedStoredValues() throws {
  let suiteName = "S3WorkbenchTests.AppPreferences.Invalid.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defer { defaults.removePersistentDomain(forName: suiteName) }
  defaults.set("sepia", forKey: "appearance")
  defaults.set("replace", forKey: "downloadCollision")
  defaults.set(42, forKey: "signedURLLifetime")

  let preferences = AppPreferences(defaults: defaults)

  #expect(preferences.appearance == .system)
  #expect(preferences.downloadCollision == .alwaysAsk)
  #expect(preferences.signedURLLifetime == .oneHour)
}
