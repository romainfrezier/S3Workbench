import SwiftUI

enum WorkbenchCommand: CaseIterable, Hashable {
  case search
  case download
  case upload
  case refresh
  case back
  case forward
  case quickLook
  case toggleInspector
  case delete

  var title: String {
    switch self {
    case .search: "Search"
    case .download: "Download…"
    case .upload: "Upload…"
    case .refresh: "Refresh"
    case .back: "Back"
    case .forward: "Forward"
    case .quickLook: "Quick Look"
    case .toggleInspector: "Toggle Inspector"
    case .delete: "Delete…"
    }
  }

  var shortcut: (key: KeyEquivalent, modifiers: EventModifiers) {
    switch self {
    case .search: ("f", .command)
    case .download: ("s", .command)
    case .upload: ("u", .command)
    case .refresh: ("r", .command)
    case .back: ("[", .command)
    case .forward: ("]", .command)
    case .quickLook: (.space, [])
    case .toggleInspector: ("i", [.command, .option])
    case .delete: (.delete, .command)
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
      enabled.formUnion([.search, .upload])
      let selection = model.selectedObjects
      if !selection.isEmpty, !selection.contains(where: \.isPrefix) {
        enabled.formUnion([.download, .delete])
        if selection.count == 1 { enabled.insert(.quickLook) }
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
  @FocusedValue(\.workbenchCommandContext) private var context

  var body: some Commands {
    CommandGroup(after: .saveItem) {
      commandButton(.download)
      commandButton(.upload)
    }
    CommandMenu("Navigate") {
      commandButton(.search)
      Divider()
      commandButton(.back)
      commandButton(.forward)
      commandButton(.refresh)
    }
    CommandMenu("Object") {
      commandButton(.quickLook)
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
    .keyboardShortcut(command.shortcut.key, modifiers: command.shortcut.modifiers)
    .disabled(context?.availability.isEnabled(command) != true)
  }
}
