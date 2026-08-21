import Foundation
import Observation
import SwiftUI

enum SettingsDestination: Hashable {
  case app
  case connection(UUID)
  case newConnection(UUID)
}

@MainActor
@Observable
final class SettingsNavigationModel {
  var destination: SettingsDestination? = .app
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
    case .app:
      draft = nil
      originalDraft = nil
    case .connection(let id):
      guard let connection = connections.first(where: { $0.id == id }) else {
        activate(.app, connections: connections)
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
        Label("App", systemImage: "gearshape")
          .tag(SettingsDestination.app)

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
    switch navigation.destination ?? .app {
    case .app:
      AppSettingsView(preferences: preferences)
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
        navigation.activate(.app, connections: model.connections)
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
    .navigationTitle("App")
  }
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
        testResult: testResult,
        indexSummary: indexSummary,
        indexErrorMessage: model.indexSettingsErrorMessage,
        isClearingIndex: isClearingIndex,
        clearIndex: clearIndex
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
  private var indexSummary: ConnectionIndexSummary? {
    model.connectionIndexSummaries.first { $0.connectionID == currentDraft.id }
  }
  private var isClearingIndex: Bool {
    model.clearingConnectionIndexIDs.contains(currentDraft.id)
  }
  private var clearIndex: (() -> Void)? {
    guard currentDraft.isExisting else { return nil }
    return { Task { await model.clearSearchIndex(connectionID: currentDraft.id) } }
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
