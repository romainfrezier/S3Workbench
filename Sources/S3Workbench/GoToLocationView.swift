import SwiftUI

struct GoToLocationView: View {
  let go: (String) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var key = ""
  @FocusState private var isKeyFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Go to Location").font(.headline)
      Text("Enter the exact object key in the current bucket. Spaces and slashes are preserved.")
        .foregroundStyle(.secondary)
      TextField("Object key", text: $key)
        .textFieldStyle(.roundedBorder)
        .autocorrectionDisabled()
        .focused($isKeyFocused)
        .onSubmit { if !key.isEmpty { go(key) } }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Go") { go(key) }
          .keyboardShortcut(.defaultAction)
          .disabled(key.isEmpty)
      }
    }
    .padding(20)
    .frame(width: 480)
    .task { isKeyFocused = true }
  }
}
