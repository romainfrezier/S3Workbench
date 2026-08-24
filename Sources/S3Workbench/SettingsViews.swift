import Foundation
import Observation
import SwiftUI

enum SettingsDestination: Hashable {
  case general
  case advanced
  case help
  case about
  case connection(UUID)
  case newConnection(UUID)
}

@MainActor
@Observable
final class SettingsNavigationModel {
  var destination: SettingsDestination? = .general
  var draft: ConnectionDraft?
  var originalDraft: ConnectionDraft?
  var pendingDestination: SettingsDestination?
  var isUnsavedConfirmationPresented = false

  var hasUnsavedChanges: Bool {
    guard let draft, let originalDraft else { return false }
    return draft != originalDraft
  }

  func request(_ next: SettingsDestination, connections: [ConnectionRow]) {
    guard next != destination else { return }
    if hasUnsavedChanges {
      pendingDestination = next
      isUnsavedConfirmationPresented = true
    } else {
      activate(next, connections: connections)
    }
  }

  func activate(_ next: SettingsDestination, connections: [ConnectionRow]) {
    destination = next
    pendingDestination = nil
    isUnsavedConfirmationPresented = false
    switch next {
    case .general, .advanced, .help, .about:
      draft = nil
      originalDraft = nil
    case .connection(let id):
      guard let connection = connections.first(where: { $0.id == id }) else {
        activate(.general, connections: connections)
        return
      }
      let value = ConnectionDraft(connection: connection)
      draft = value
      originalDraft = value
    case .newConnection(let id):
      var value = ConnectionDraft()
      value.id = id
      draft = value
      originalDraft = value
    }
  }

  func markSaved(_ connection: ConnectionRow, connections: [ConnectionRow]) {
    activate(.connection(connection.id), connections: connections)
  }

  func discardAndContinue(connections: [ConnectionRow]) {
    guard let pendingDestination else {
      isUnsavedConfirmationPresented = false
      return
    }
    activate(pendingDestination, connections: connections)
  }
}

struct WorkbenchSettingsView: View {
  @Bindable var preferences: AppPreferences
  @Bindable var navigation: SettingsNavigationModel
  @Bindable var model: WorkbenchViewModel

  @State private var connectionToDelete: ConnectionRow?

  var body: some View {
    NavigationSplitView {
      List(selection: selection) {
        Section {
          Label("General", systemImage: "gearshape")
            .tag(SettingsDestination.general)
          Label("Advanced", systemImage: "slider.horizontal.3")
            .tag(SettingsDestination.advanced)
        }

        Section("Connections") {
          ForEach(model.connections) { connection in
            Label {
              Text(connection.name)
            } icon: {
              Image(systemName: "circle.fill")
                .font(.caption)
                .foregroundStyle(connection.color)
            }
            .tag(SettingsDestination.connection(connection.id))
            .contextMenu {
              Button("Duplicate") { duplicate(connection) }
                .disabled(navigation.hasUnsavedChanges)
              Button("Delete", role: .destructive) { connectionToDelete = connection }
                .disabled(navigation.hasUnsavedChanges)
            }
          }
          if case .newConnection(let id) = navigation.destination {
            Label("New Connection", systemImage: "externaldrive.badge.plus")
              .tag(SettingsDestination.newConnection(id))
          }
        }

        Section {
          Label("Help", systemImage: "questionmark.circle")
            .tag(SettingsDestination.help)
          Label("About", systemImage: "info.circle")
            .tag(SettingsDestination.about)
        }
      }
      .listStyle(.sidebar)
      .navigationTitle("Settings")
      .safeAreaInset(edge: .bottom) {
        HStack {
          Button {
            navigation.request(.newConnection(UUID()), connections: model.connections)
          } label: {
            Label("Add Connection", systemImage: "plus")
          }
          .buttonStyle(.borderless)
          Spacer()
        }
        .padding(10)
      }
      .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
    } detail: {
      detail
    }
    .navigationSplitViewStyle(.balanced)
    .frame(width: 860, height: 660)
    .task { await model.loadSearchIndexSummaries() }
    .safeAreaInset(edge: .top) {
      if let errorMessage = model.errorMessage {
        HStack(spacing: 10) {
          Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
          Spacer()
          Button("Dismiss") { model.errorMessage = nil }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
      }
    }
    .confirmationDialog(
      "Unsaved connection changes",
      isPresented: $navigation.isUnsavedConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("Save Changes") { saveAndContinue() }
        .disabled(navigation.draft?.validationMessage != nil)
      Button("Discard Changes", role: .destructive) {
        navigation.discardAndContinue(connections: model.connections)
      }
      Button("Cancel", role: .cancel) { navigation.pendingDestination = nil }
    } message: {
      Text("Save or discard the connection draft before opening another settings page.")
    }
    .confirmationDialog(
      "Delete this connection?",
      isPresented: Binding(
        get: { connectionToDelete != nil },
        set: { if !$0 { connectionToDelete = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete Connection", role: .destructive) { deleteConnection() }
    } message: {
      Text("Its saved settings, Keychain credentials, certificate, and local search index will be removed.")
    }
  }

  private var selection: Binding<SettingsDestination?> {
    Binding(
      get: { navigation.destination },
      set: { if let value = $0 { navigation.request(value, connections: model.connections) } }
    )
  }

  @ViewBuilder
  private var detail: some View {
    switch navigation.destination ?? .general {
    case .general:
      AppSettingsView(preferences: preferences)
    case .advanced:
      AdvancedSettingsView(model: model)
    case .help:
      SettingsHelpView()
    case .about:
      SettingsAboutView()
    case .connection, .newConnection:
      if navigation.draft != nil {
        ConnectionSettingsDetail(
          model: model,
          navigation: navigation,
          requestDelete: { connectionToDelete = $0 }
        )
      } else {
        ContentUnavailableView("Select a Connection", systemImage: "externaldrive")
      }
    }
  }

  private func saveAndContinue() {
    guard let draft = navigation.draft, let pending = navigation.pendingDestination else { return }
    Task {
      if await model.saveConnection(draft) {
        navigation.activate(pending, connections: model.connections)
      }
    }
  }

  private func duplicate(_ connection: ConnectionRow) {
    Task {
      let previousIDs = Set(model.connections.map(\.id))
      await model.duplicateConnection(connection)
      if let copy = model.connections.first(where: { !previousIDs.contains($0.id) }) {
        navigation.activate(.connection(copy.id), connections: model.connections)
      }
    }
  }

  private func deleteConnection() {
    guard let connection = connectionToDelete else { return }
    connectionToDelete = nil
    Task {
      if await model.removeConnection(connection) {
        navigation.activate(.general, connections: model.connections)
      }
    }
  }
}

private struct AppSettingsView: View {
  @Bindable var preferences: AppPreferences

  var body: some View {
    Form {
      Section("Appearance") {
        Picker("Theme", selection: $preferences.appearance) {
          ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        Text("System follows the appearance selected in macOS.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Transfers") {
        Picker("Download destination", selection: $preferences.downloadDestination) {
          ForEach(DownloadDestinationPreference.allCases) { Text($0.label).tag($0) }
        }
        Picker("Existing downloaded file", selection: $preferences.downloadCollision) {
          ForEach(SafeCollisionPreference.allCases) { Text($0.label).tag($0) }
        }
        Picker("Existing uploaded object", selection: $preferences.uploadCollision) {
          ForEach(SafeCollisionPreference.allCases) { Text($0.label).tag($0) }
        }
        Text("Replace is always an explicit choice and is never saved as a default.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Links") {
        Picker("Signed URL lifetime", selection: $preferences.signedURLLifetime) {
          ForEach(SignedURLLifetime.allCases) { Text($0.label).tag($0) }
        }
        Text("Unsigned URLs work only when the object is publicly accessible.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .navigationTitle("General")
  }
}

private struct AdvancedSettingsView: View {
  @Bindable var model: WorkbenchViewModel
  @State private var connectionToClear: UUID?

  var body: some View {
    Form {
      Section("Local Search Index") {
        Text("S3Workbench keeps searchable metadata on this Mac so later searches can avoid another remote scan.")
          .foregroundStyle(.secondary)

        if model.connectionIndexSummaries.isEmpty {
          Text("No local search index is stored for any connection.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(sortedSummaries) { summary in
            if let connection = model.connections.first(where: { $0.id == summary.connectionID }) {
              VStack(alignment: .leading, spacing: 8) {
                LabeledContent(connection.name) {
                  Text(summary.objectCount.formatted() + " objects")
                }
                LabeledContent("Locations", value: summary.scopeCount.formatted())
                if let indexedAt = summary.indexedAt {
                  LabeledContent("Last updated", value: indexedAt.formatted(date: .abbreviated, time: .shortened))
                }
                if summary.isStale {
                  Label("The index will be refreshed by the next search.", systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                }
                HStack {
                  Button("Clear Index…", role: .destructive) {
                    connectionToClear = summary.connectionID
                  }
                  .disabled(model.clearingConnectionIndexIDs.contains(summary.connectionID))
                  if model.clearingConnectionIndexIDs.contains(summary.connectionID) {
                    ProgressView().controlSize(.small)
                    Text("Clearing…").foregroundStyle(.secondary)
                  }
                }
              }
              .padding(.vertical, 4)
            }
          }
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Advanced")
    .confirmationDialog(
      "Clear this connection’s search index?",
      isPresented: Binding(
        get: { connectionToClear != nil },
        set: { if !$0 { connectionToClear = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Clear Index", role: .destructive) {
        guard let connectionID = connectionToClear else { return }
        connectionToClear = nil
        Task { await model.clearSearchIndex(connectionID: connectionID) }
      }
    } message: {
      Text("Only local searchable metadata is removed. The connection and remote objects are unchanged.")
    }
  }

  private var sortedSummaries: [ConnectionIndexSummary] {
    model.connectionIndexSummaries.sorted { lhs, rhs in
      let left = model.connections.first { $0.id == lhs.connectionID }?.name ?? ""
      let right = model.connections.first { $0.id == rhs.connectionID }?.name ?? ""
      return left.localizedStandardCompare(right) == .orderedAscending
    }
  }
}

private struct SettingsHelpView: View {
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        settingsHelpSection("Connections", systemImage: "externaldrive.connected.to.line.below") {
          Text("Add an S3-compatible endpoint, then choose its region, addressing style and optional access path. Credentials are stored in the macOS Keychain.")
        }
        settingsHelpSection("Browse and search", systemImage: "magnifyingglass") {
          Text("Open buckets and prefixes from the main window. Search below the current prefix, or use recursive search to scan deeper objects while keeping the current access root.")
        }
        settingsHelpSection("Transfers", systemImage: "arrow.up.arrow.down") {
          Text("Uploads, downloads and Finder exports stay visible in Transfers. Existing files and objects are never replaced without an explicit choice.")
        }
        settingsHelpSection("Shortcuts", systemImage: "command") {
          VStack(alignment: .leading, spacing: 6) {
            settingsShortcut("Space", "Open Quick Look for the selected object")
            settingsShortcut("⌘,", "Open Settings")
            settingsShortcut("⌘⌥I", "Show or hide the inspector")
          }
        }
        settingsHelpSection("Need more help?", systemImage: "link") {
          VStack(alignment: .leading, spacing: 8) {
            Link("Open the S3Workbench website", destination: SettingsLinks.website)
            Link("Open GitHub", destination: SettingsLinks.github)
            Link("Report a problem", destination: SettingsLinks.issues)
          }
        }
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .navigationTitle("Help")
  }

  private func settingsHelpSection<Content: View>(
    _ title: String,
    systemImage: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(title, systemImage: systemImage).font(.headline)
      content().foregroundStyle(.secondary)
    }
  }

  private func settingsShortcut(_ keys: String, _ description: String) -> some View {
    HStack {
      Text(keys)
        .font(.system(.body, design: .monospaced).weight(.semibold))
        .frame(width: 58, alignment: .leading)
      Text(description)
    }
  }
}

private struct SettingsAboutView: View {
  private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "externaldrive.connected.to.line.below")
        .font(.system(size: 44))
        .foregroundStyle(.tint)
      Text("S3Workbench").font(.title2.bold())
      Text("A native macOS browser for S3-compatible object storage")
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Text("Version \(version)").font(.caption)
      Link(destination: SettingsLinks.buyMeACoffee) {
        Label("Buy Me a Coffee", systemImage: "cup.and.saucer.fill")
      }
      .buttonStyle(.borderedProminent)
      Link("View S3Workbench on GitHub", destination: SettingsLinks.github)
      Text("MIT License").font(.caption).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
    .navigationTitle("About")
  }
}

private enum SettingsLinks {
  static let website = URL(string: "https://s3workbench.com")!
  static let github = URL(string: "https://github.com/romainfrezier/S3Workbench")!
  static let issues = URL(string: "https://github.com/romainfrezier/S3Workbench/issues")!
  static let buyMeACoffee = URL(string: "https://buymeacoffee.com/romainfrezier")!
}

private struct ConnectionSettingsDetail: View {
  @Bindable var model: WorkbenchViewModel
  @Bindable var navigation: SettingsNavigationModel
  let requestDelete: (ConnectionRow) -> Void

  @State private var isTesting = false
  @State private var isSaving = false
  @State private var testResult: Result<Void, Error>?

  var body: some View {
    VStack(spacing: 0) {
      ConnectionSettingsForm(
        draft: draft,
        testResult: testResult
      )

      Divider()
      HStack(spacing: 12) {
        if let connection {
          Button("Delete Connection", role: .destructive) { requestDelete(connection) }
          Button("Duplicate") { duplicate(connection) }
            .disabled(navigation.hasUnsavedChanges)
        }
        Spacer()
        Button("Test Connection") { Task { await testDraft() } }
          .disabled(currentDraft.validationMessage != nil || isTesting || isSaving)
        Button(currentDraft.isExisting ? "Save Changes" : "Add Connection") {
          Task { await saveDraft() }
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(currentDraft.validationMessage != nil || isTesting || isSaving)
        if isTesting || isSaving {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel(isSaving ? "Saving connection" : "Testing connection")
        }
      }
      .padding()
    }
    .navigationTitle(currentDraft.isExisting ? currentDraft.name : "New Connection")
    .onChange(of: navigation.draft) { _, _ in testResult = nil }
  }

  private var draft: Binding<ConnectionDraft> {
    Binding(
      get: { navigation.draft ?? ConnectionDraft() },
      set: { navigation.draft = $0 }
    )
  }

  private var currentDraft: ConnectionDraft { navigation.draft ?? ConnectionDraft() }
  private var connection: ConnectionRow? {
    guard currentDraft.isExisting else { return nil }
    return model.connections.first { $0.id == currentDraft.id }
  }
  private func testDraft() async {
    isTesting = true
    defer { isTesting = false }
    do {
      try await model.testConnection(currentDraft)
      testResult = .success(())
    } catch {
      testResult = .failure(error)
    }
  }

  private func saveDraft() async {
    let value = currentDraft
    isSaving = true
    defer { isSaving = false }
    guard await model.saveConnection(value),
      let saved = model.connections.first(where: { $0.id == value.id })
    else { return }
    navigation.markSaved(saved, connections: model.connections)
  }

  private func duplicate(_ connection: ConnectionRow) {
    Task {
      let previousIDs = Set(model.connections.map(\.id))
      await model.duplicateConnection(connection)
      if let copy = model.connections.first(where: { !previousIDs.contains($0.id) }) {
        navigation.activate(.connection(copy.id), connections: model.connections)
      }
    }
  }
}
