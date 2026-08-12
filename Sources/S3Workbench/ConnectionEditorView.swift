import SwiftUI
import UniformTypeIdentifiers

struct ConnectionEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @State var draft: ConnectionDraft
  let save: (ConnectionDraft) async -> Bool
  let test: (ConnectionDraft) async throws -> Void

  @State private var isTesting = false
  @State private var testResult: Result<Void, Error>?
  @State private var isChoosingCA = false

  var body: some View {
    NavigationStack {
      Form {
        Section("Connection") {
          TextField("Name", text: $draft.name, prompt: Text("Local MinIO"))
          TextField("Endpoint URL", text: $draft.endpoint, prompt: Text("http://localhost:9000"))
            .textContentType(.URL)
          TextField("Region", text: $draft.region)
          Picker("Addressing", selection: $draft.addressingMode) {
            ForEach(AddressingMode.allCases) { Text($0.rawValue).tag($0) }
          }
        }

        Section("Credentials") {
          TextField("Access Key", text: $draft.accessKey)
            .textContentType(.username)
          SecureField("Secret Access Key", text: $draft.secretKey)
            .textContentType(.password)
          Text("Secrets are stored in macOS Keychain, never in the connection file.")
            .font(.caption)
            .foregroundStyle(.secondary)
          if !draft.name.isEmpty {
            Text("When editing, leave both credential fields blank to keep the saved Keychain values.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        Section("TLS") {
          if URL(string: draft.endpoint)?.scheme?.lowercased() == "http" {
            Label(
              "HTTP sends credentials and object data without transport encryption. Use it only on a trusted local network.",
              systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
          }
          Picker("Verification", selection: $draft.tlsPolicy) {
            ForEach(TLSPolicy.allCases) { Text($0.rawValue).tag($0) }
          }
          if draft.tlsPolicy == .customCA {
            LabeledContent("Certificate") {
              Button(draft.customCAURL?.lastPathComponent ?? "Choose…") { isChoosingCA = true }
            }
          } else if draft.tlsPolicy == .insecure {
            Label(
              "This option is unavailable in this build. Use HTTP for trusted local development or choose a custom CA.",
              systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
          }
        }

        if let validationMessage = draft.validationMessage {
          Section {
            Label(validationMessage, systemImage: "exclamationmark.circle")
              .foregroundStyle(.secondary)
          }
        }

        if let testResult {
          Section {
            switch testResult {
            case .success:
              Label("Connection succeeded", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            case .failure(let error):
              Label(error.localizedDescription, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
            }
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle(draft.name.isEmpty ? "New Connection" : "Edit Connection")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .keyboardShortcut(.cancelAction)
        }
        ToolbarItemGroup(placement: .confirmationAction) {
          Button("Test") {
            Task { await testDraft() }
          }
          .disabled(draft.validationMessage != nil || isTesting)

          Button("Save") {
            Task {
              if await save(draft) { dismiss() }
            }
          }
          .keyboardShortcut(.defaultAction)
          .disabled(draft.validationMessage != nil)
        }
      }
    }
    .frame(width: 540, height: 590)
    .fileImporter(isPresented: $isChoosingCA, allowedContentTypes: [.x509Certificate]) { result in
      if case .success(let url) = result { draft.customCAURL = url }
    }
  }

  private func testDraft() async {
    isTesting = true
    defer { isTesting = false }
    do {
      try await test(draft)
      testResult = .success(())
    } catch {
      testResult = .failure(error)
    }
  }
}
