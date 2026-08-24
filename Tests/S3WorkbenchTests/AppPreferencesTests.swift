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

@Test func downloadDestinationFallsBackToAskingWhenDownloadsIsUnavailable() {
  let downloads = URL(fileURLWithPath: "/tmp/Downloads", isDirectory: true)

  #expect(DownloadDestinationPreference.alwaysAsk.directory(from: [downloads]) == nil)
  #expect(DownloadDestinationPreference.downloads.directory(from: []) == nil)
  #expect(DownloadDestinationPreference.downloads.directory(from: [downloads]) == downloads)
}

@MainActor
@Test func settingsNavigationProtectsUnsavedConnectionDrafts() {
  let connection = ConnectionRow(
    id: UUID(),
    name: "Local",
    endpoint: URL(string: "https://storage.example.com")!,
    accessPath: nil,
    colorHex: "#0A84FF",
    region: "us-east-1",
    addressingMode: .pathStyle,
    tlsPolicy: .system,
    customCAURL: nil
  )
  let navigation = SettingsNavigationModel()

  navigation.activate(.connection(connection.id), connections: [connection])
  navigation.draft?.name = "Edited"
  navigation.request(.general, connections: [connection])

  #expect(navigation.destination == .connection(connection.id))
  #expect(navigation.pendingDestination == .general)
  #expect(navigation.isUnsavedConfirmationPresented)

  navigation.discardAndContinue(connections: [connection])
  #expect(navigation.destination == .general)
  #expect(navigation.draft == nil)

  let newConnectionID = UUID()
  navigation.activate(.newConnection(newConnectionID), connections: [connection])
  #expect(navigation.draft?.id == newConnectionID)
}

@MainActor
@Test func settingsNavigationSupportsTopLevelPages() {
  let navigation = SettingsNavigationModel()

  navigation.activate(.advanced, connections: [])
  #expect(navigation.destination == .advanced)
  navigation.activate(.help, connections: [])
  #expect(navigation.destination == .help)
  navigation.activate(.about, connections: [])
  #expect(navigation.destination == .about)
  #expect(!navigation.hasUnsavedChanges)
}
