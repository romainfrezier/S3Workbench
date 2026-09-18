import AppKit
import SwiftUI

enum WorkbenchCommand: CaseIterable, Hashable {
  case search
  case goToLocation
  case download
  case upload
  case refresh
  case back
  case forward
  case quickLook
  case copyObjectKey
  case copyS3URI
  case toggleInspector
  case delete

  var title: String {
    switch self {
    case .search: "Search"
    case .goToLocation: "Go to Location…"
    case .download: "Download…"
    case .upload: "Upload…"
    case .refresh: "Refresh"
    case .back: "Back"
    case .forward: "Forward"
    case .quickLook: "Quick Look"
    case .copyObjectKey: "Copy Object Key"
    case .copyS3URI: "Copy S3 URI"
    case .toggleInspector: "Toggle Inspector"
    case .delete: "Delete…"
    }
  }

  var shortcut: KeyboardShortcut? {
    switch self {
    case .copyObjectKey, .copyS3URI: nil
    case .goToLocation: KeyboardShortcut("g", modifiers: [.command, .shift])
    case .search: KeyboardShortcut("f", modifiers: .command)
    case .download: KeyboardShortcut("s", modifiers: .command)
    case .upload: KeyboardShortcut("u", modifiers: .command)
    case .refresh: KeyboardShortcut("r", modifiers: .command)
    case .back: KeyboardShortcut("[", modifiers: .command)
    case .forward: KeyboardShortcut("]", modifiers: .command)
    case .quickLook: KeyboardShortcut(.space, modifiers: [])
    case .toggleInspector: KeyboardShortcut("i", modifiers: [.command, .option])
    case .delete: KeyboardShortcut(.delete, modifiers: .command)
    }
  }

  var role: ButtonRole? { self == .delete ? .destructive : nil }
}

struct WorkbenchCommandAvailability: Equatable {
  private let enabledCommands: Set<WorkbenchCommand>

  @MainActor
  init(model: WorkbenchViewModel, isModalPresented: Bool) {
    guard !isModalPresented else {
      enabledCommands = []
      return
    }

    var enabled: Set<WorkbenchCommand> = [.toggleInspector]
    if model.selectedConnection != nil { enabled.insert(.refresh) }
    if model.location != nil {
      enabled.formUnion([.search, .upload, .goToLocation])
      let selection = model.selectedObjects
      if !selection.isEmpty, !selection.contains(where: \.isPrefix) {
        enabled.formUnion([.download, .delete])
        if selection.count == 1 { enabled.formUnion([.quickLook, .copyObjectKey, .copyS3URI]) }
      }
    }
    if model.canGoBack { enabled.insert(.back) }
    if model.canGoForward { enabled.insert(.forward) }
    enabledCommands = enabled
  }

  func isEnabled(_ command: WorkbenchCommand) -> Bool {
    enabledCommands.contains(command)
  }
}

struct WorkbenchCommandContext {
  let availability: WorkbenchCommandAvailability
  let perform: (WorkbenchCommand) -> Void

  func send(_ command: WorkbenchCommand) {
    guard availability.isEnabled(command) else { return }
    perform(command)
  }
}

private struct WorkbenchCommandContextKey: FocusedValueKey {
  typealias Value = WorkbenchCommandContext
}

extension FocusedValues {
  var workbenchCommandContext: WorkbenchCommandContext? {
    get { self[WorkbenchCommandContextKey.self] }
    set { self[WorkbenchCommandContextKey.self] = newValue }
  }
}

struct WorkbenchCommands: Commands {
  let settingsNavigation: SettingsNavigationModel

  @FocusedValue(\.workbenchCommandContext) private var context

  var body: some Commands {
    CommandGroup(replacing: .appInfo) {
      Button("About S3Workbench") {
        NSApp.orderFrontStandardAboutPanel(nil)
      }
    }
    CommandGroup(replacing: .help) {
      Button("S3Workbench Help") {
        openHelp()
      }
      .keyboardShortcut("/", modifiers: [.command, .shift])
    }
    CommandGroup(after: .saveItem) {
      commandButton(.download)
      commandButton(.upload)
    }
    CommandMenu("Navigate") {
      commandButton(.search)
      commandButton(.goToLocation)
      Divider()
      commandButton(.back)
      commandButton(.forward)
      commandButton(.refresh)
    }
    CommandMenu("Object") {
      commandButton(.quickLook)
      commandButton(.copyObjectKey)
      commandButton(.copyS3URI)
      Divider()
      commandButton(.delete)
    }
    CommandGroup(after: .toolbar) {
      commandButton(.toggleInspector)
    }
  }

  private func commandButton(_ command: WorkbenchCommand) -> some View {
    Button(role: command.role) {
      context?.send(command)
    } label: {
      Text(command.title)
    }
    .keyboardShortcut(command.shortcut)
    .disabled(context?.availability.isEnabled(command) != true)
  }

  private func openHelp() {
    settingsNavigation.request(.help, connections: [])
    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
  }
}
