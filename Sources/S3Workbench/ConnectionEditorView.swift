import SwiftUI
import UniformTypeIdentifiers

struct ConnectionSettingsForm: View {
  @Binding var draft: ConnectionDraft
  let testResult: Result<Void, Error>?
  var indexSummary: ConnectionIndexSummary? = nil
  var indexErrorMessage: String? = nil
  var isClearingIndex = false
  var clearIndex: (() -> Void)?

  @State private var isChoosingCA = false
  @State private var isClearIndexConfirmationPresented = false

  var body: some View {
    Form {
      Section("General") {
        TextField("Name", text: $draft.name, prompt: Text("Local MinIO"))
        ColorPicker("Color", selection: colorBinding, supportsOpacity: false)
      }

      Section("Endpoint") {
        TextField("Server", text: $draft.server, prompt: Text("storage.example.com"))
        TextField("Port", text: $draft.port, prompt: Text("443"))
        Toggle("Use HTTPS", isOn: $draft.usesHTTPS)
        TextField("Access path", text: $draft.accessPath, prompt: Text("/bucket/prefix"))
        Text(
          "Enter only the server name. The optional access path opens a bucket or prefix directly."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section("S3") {
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
        if draft.isExisting {
          Text("Leave both credential fields blank to keep the saved Keychain values.")
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

      if draft.isExisting {
        Section("Local Search Index") {
          if let indexErrorMessage {
            Label(indexErrorMessage, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.orange)
          }
          if let indexSummary {
            LabeledContent("Objects", value: indexSummary.objectCount.formatted())
            LabeledContent("Locations", value: indexSummary.scopeCount.formatted())
            if let indexedAt = indexSummary.indexedAt {
              LabeledContent("Last updated") {
                Text(indexedAt, format: .dateTime.year().month().day().hour().minute())
              }
            }
            if indexSummary.isStale {
              Label("The index will be refreshed by the next search.", systemImage: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
            }
            Button("Clear Index…", role: .destructive) {
              isClearIndexConfirmationPresented = true
            }
            .disabled(isClearingIndex)
          } else {
            Text("No local search index is stored for this connection.")
              .foregroundStyle(.secondary)
          }
          if isClearingIndex {
            HStack {
              ProgressView().controlSize(.small)
              Text("Clearing local index…").foregroundStyle(.secondary)
            }
          }
        }
      }
    }
    .formStyle(.grouped)
    .onChange(of: draft.usesHTTPS) { wasHTTPS, usesHTTPS in
      if wasHTTPS, !usesHTTPS, draft.port == "443" { draft.port = "80" }
      if !wasHTTPS, usesHTTPS, draft.port == "80" { draft.port = "443" }
    }
    .fileImporter(isPresented: $isChoosingCA, allowedContentTypes: [.x509Certificate]) { result in
      if case .success(let url) = result { draft.customCAURL = url }
    }
    .confirmationDialog(
      "Clear this connection’s search index?",
      isPresented: $isClearIndexConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("Clear Index", role: .destructive) { clearIndex?() }
    } message: {
      Text("Only local searchable metadata is removed. The connection and remote objects are unchanged.")
    }
  }

  private var colorBinding: Binding<Color> {
    Binding(
      get: { Color(connectionHex: draft.colorHex) },
      set: { draft.colorHex = $0.connectionHex }
    )
  }
}
