import SwiftUI
import UniformTypeIdentifiers

struct ConnectionEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @State var draft: ConnectionDraft
  let save: (ConnectionDraft) async -> Bool
  let test: (ConnectionDraft) async throws -> Void

  @State private var isTesting = false
  @State private var isSaving = false
  @State private var testResult: Result<Void, Error>?
  @State private var isChoosingCA = false

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        Form {
        Section("Connection") {
          TextField("Name", text: $draft.name, prompt: Text("Local MinIO"))
          ColorPicker("Color", selection: colorBinding, supportsOpacity: false)
          TextField("Server", text: $draft.server, prompt: Text("storage.example.com"))
          TextField("Port", text: $draft.port, prompt: Text("443"))
          Toggle("Use HTTPS", isOn: $draft.usesHTTPS)
          TextField("Access path", text: $draft.accessPath, prompt: Text("/bucket/prefix"))
          Text("Enter only the server name. The optional access path opens a bucket or prefix directly, without listing every bucket first.")
            .font(.caption)
            .foregroundStyle(.secondary)
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
          if !draft.usesHTTPS {
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

        Divider()
        HStack(spacing: 12) {
          Button("Cancel") { dismiss() }
            .keyboardShortcut(.cancelAction)
          Spacer()
          Button("Test") {
            Task { await testDraft() }
          }
          .disabled(draft.validationMessage != nil || isTesting || isSaving)

          Button(draft.isExisting ? "Save Changes" : "Add Connection") {
            Task { await saveDraft() }
          }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(draft.validationMessage != nil || isTesting || isSaving)

          if isSaving {
            ProgressView()
              .controlSize(.small)
              .accessibilityLabel("Saving connection")
          }
        }
        .padding()
      }
      .navigationTitle(draft.isExisting ? "Edit Connection" : "New Connection")
    }
    .frame(width: 560, height: 660)
    .onChange(of: draft.usesHTTPS) { wasHTTPS, usesHTTPS in
      if wasHTTPS, !usesHTTPS, draft.port == "443" { draft.port = "80" }
      if !wasHTTPS, usesHTTPS, draft.port == "80" { draft.port = "443" }
      testResult = nil
    }
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

  private func saveDraft() async {
    isSaving = true
    defer { isSaving = false }
    if await save(draft) { dismiss() }
  }

  private var colorBinding: Binding<Color> {
    Binding(
      get: { Color(connectionHex: draft.colorHex) },
      set: { draft.colorHex = $0.connectionHex }
    )
  }
}
