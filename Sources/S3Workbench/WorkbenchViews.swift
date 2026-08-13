import AppKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct WorkbenchRootView: View {
  @Bindable var model: WorkbenchViewModel

  @State private var connectionDraft: ConnectionDraft?
  @State private var isInspectorPresented = true
  @State private var isTransferPopoverPresented = false
  @State private var isUploadPresented = false
  @State private var isDownloadDestinationPresented = false
  @State private var isDeleteConfirmationPresented = false
  @State private var connectionToDelete: ConnectionRow?
  @State private var renameKey: String?
  @State private var pendingUploadURLs: [URL] = []
  @State private var pendingDownloadDirectory: URL?
  @State private var isUploadCollisionPresented = false
  @State private var isDownloadCollisionPresented = false

  var body: some View {
    NavigationSplitView {
      connectionSidebar
        .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 320)
    } detail: {
      browser
        .inspector(isPresented: $isInspectorPresented) {
          ObjectInspectorView(model: model)
            .inspectorColumnWidth(min: 240, ideal: 300, max: 440)
        }
    }
    .navigationSplitViewStyle(.balanced)
    .toolbar { toolbarContent }
    .searchable(text: $model.searchQuery, placement: .toolbar, prompt: "Filter by key prefix")
    .sheet(item: $connectionDraft) { draft in
      ConnectionEditorView(
        draft: draft,
        save: { await model.saveConnection($0) },
        test: { try await model.testConnection($0) }
      )
    }
    .sheet(
      isPresented: Binding(
        get: { renameKey != nil },
        set: { if !$0 { renameKey = nil } }
      )
    ) {
      RenameObjectView(key: renameKey ?? "") { newKey, collisionPolicy in
        let saved = await model.renameSelected(to: newKey, collisionPolicy: collisionPolicy)
        if saved { renameKey = nil }
      }
    }
    .fileImporter(
      isPresented: $isUploadPresented, allowedContentTypes: [.item], allowsMultipleSelection: true
    ) { result in
      if case .success(let urls) = result { requestUpload(urls) }
    }
    .fileImporter(isPresented: $isDownloadDestinationPresented, allowedContentTypes: [.folder]) {
      result in
      if case .success(let url) = result {
        pendingDownloadDirectory = url
        isDownloadCollisionPresented = true
      }
    }
    .confirmationDialog(
      "If an object already exists",
      isPresented: $isUploadCollisionPresented,
      titleVisibility: .visible
    ) {
      Button("Keep Both") { performUpload(.keepBoth) }
      Button("Replace", role: .destructive) { performUpload(.replace) }
      Button("Cancel", role: .cancel) { pendingUploadURLs = [] }
    } message: {
      Text("Choose how uploads with the same key should be handled.")
    }
    .confirmationDialog(
      "If a file already exists",
      isPresented: $isDownloadCollisionPresented,
      titleVisibility: .visible
    ) {
      Button("Keep Both") { performDownload(.keepBoth) }
      Button("Replace", role: .destructive) { performDownload(.replace) }
      Button("Cancel", role: .cancel) { pendingDownloadDirectory = nil }
    } message: {
      Text("Choose how downloads with the same filename should be handled.")
    }
    .confirmationDialog(
      "Delete selected objects?",
      isPresented: $isDeleteConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) { Task { await model.deleteSelected() } }
    } message: {
      Text("This operation can’t be undone.")
    }
    .confirmationDialog(
      "Delete this connection?",
      isPresented: Binding(
        get: { connectionToDelete != nil },
        set: { if !$0 { connectionToDelete = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete Connection", role: .destructive) {
        guard let connection = connectionToDelete else { return }
        connectionToDelete = nil
        Task { await model.removeConnection(connection) }
      }
    } message: {
      Text("Its saved settings and Keychain credentials will be removed.")
    }
    .alert(
      "Operation Failed",
      isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { if !$0 { model.errorMessage = nil } }
      )
    ) {
      Button("OK") { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "Unknown error")
    }
    .quickLookPreview($model.previewURL)
    .task { await model.start() }
    .task(id: model.selectedConnectionID) {
      guard model.selectedConnectionID != nil else { return }
      await model.reloadConnection()
    }
    .task(id: model.selectedObjectIDs) { await model.loadSelectionDetails() }
    .task(id: model.searchQuery) {
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled, model.location != nil else { return }
      await model.reloadSearchIfNeeded()
    }
  }

  private var connectionSidebar: some View {
    List(selection: $model.selectedConnectionID) {
      Section("Connections") {
        ForEach(model.connections) { connection in
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text(connection.name)
              Text(
                connection.endpoint.host(percentEncoded: false)
                  ?? connection.endpoint.absoluteString
              )
              .font(.caption)
              .foregroundStyle(.secondary)
            }
          } icon: {
            Image(systemName: "externaldrive.connected.to.line.below")
              .foregroundStyle(connection.color)
          }
          .tag(connection.id)
          .contextMenu {
            Button("Edit…") { connectionDraft = ConnectionDraft(connection: connection) }
            Button("Duplicate") { Task { await model.duplicateConnection(connection) } }
            Divider()
            Button("Delete", role: .destructive) {
              connectionToDelete = connection
            }
          }
        }
      }
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .bottom) {
      HStack {
        Button {
          connectionDraft = ConnectionDraft()
        } label: {
          Label("Add Connection", systemImage: "plus")
        }
        .buttonStyle(.borderless)
        Spacer()
      }
      .padding(10)
    }
    .navigationTitle("S3 Workbench")
    .overlay {
      if model.connections.isEmpty, !model.isLoadingConnections {
        ContentUnavailableView {
          Label("No Connections", systemImage: "externaldrive.badge.plus")
        } description: {
          Text("Add an S3-compatible endpoint to begin.")
        } actions: {
          Button("Add Connection") { connectionDraft = ConnectionDraft() }
        }
      }
    }
  }

  @ViewBuilder
  private var browser: some View {
    if model.selectedConnection == nil {
      ContentUnavailableView(
        "Select a Connection", systemImage: "sidebar.left",
        description: Text("Choose a saved connection in the sidebar."))
    } else if model.selectedBucket == nil {
      BucketBrowserView(model: model)
    } else {
      ObjectBrowserView(
        model: model,
        requestUpload: { isUploadPresented = true },
        queueUpload: requestUpload,
        requestDelete: { isDeleteConfirmationPresented = true },
        requestRename: { renameKey = $0 }
      )
    }
  }

  @ToolbarContentBuilder
  private var toolbarContent: some ToolbarContent {
    ToolbarItemGroup(placement: .navigation) {
      Button {
        Task { await model.goBack() }
      } label: {
        Label("Back", systemImage: "chevron.left")
      }
      .disabled(!model.canGoBack)
      Button {
        Task { await model.goForward() }
      } label: {
        Label("Forward", systemImage: "chevron.right")
      }
      .disabled(!model.canGoForward)
    }

    ToolbarItem(placement: .principal) {
      BreadcrumbView(model: model)
    }

    ToolbarItemGroup(placement: .primaryAction) {
      Button {
        isUploadPresented = true
      } label: {
        Label("Upload", systemImage: "square.and.arrow.up")
      }
      .keyboardShortcut("u", modifiers: .command)
      .disabled(model.location == nil)
      Button {
        Task {
          if model.selectedBucket == nil {
            await model.reloadConnection()
          } else {
            await model.reloadObjects()
          }
        }
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .keyboardShortcut("r", modifiers: .command)
      .disabled(model.selectedConnection == nil)

      Button {
        isTransferPopoverPresented.toggle()
        Task { await model.refreshTransfers() }
      } label: {
        Label("Transfers", systemImage: "arrow.up.arrow.down.circle")
      }
      .popover(isPresented: $isTransferPopoverPresented, arrowEdge: .bottom) {
        TransferListView(model: model)
      }

      Button {
        isInspectorPresented.toggle()
      } label: {
        Label("Inspector", systemImage: "sidebar.right")
      }
      .keyboardShortcut("i", modifiers: [.command, .option])

      Menu {
        Button("Quick Look") { Task { await model.previewSelected() } }
          .keyboardShortcut(.space, modifiers: [])
          .disabled(model.selectedObject == nil || model.selectedObject?.isPrefix == true)
        Button("Download…") { isDownloadDestinationPresented = true }
          .disabled(
            model.selectedObjects.isEmpty || model.selectedObjects.contains(where: \.isPrefix))
        Button("Copy Presigned URL") { copyPresignedURL() }
          .disabled(model.selectedObject == nil || model.selectedObject?.isPrefix == true)
        Button("Rename…") { renameKey = model.selectedObject?.key }
          .disabled(model.selectedObject == nil || model.selectedObject?.isPrefix == true)
        Divider()
        Button("Delete…", role: .destructive) { isDeleteConfirmationPresented = true }
          .disabled(
            model.selectedObjects.isEmpty || model.selectedObjects.contains(where: \.isPrefix))
      } label: {
        Label("More", systemImage: "ellipsis.circle")
      }
    }
  }

  private func copyPresignedURL() {
    Task {
      guard let url = await model.presignedURL() else { return }
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
  }

  private func requestUpload(_ urls: [URL]) {
    guard !urls.isEmpty else { return }
    pendingUploadURLs = urls
    isUploadCollisionPresented = true
  }

  private func performUpload(_ collisionPolicy: CollisionPolicy) {
    let urls = pendingUploadURLs
    pendingUploadURLs = []
    Task { await model.upload(urls, collisionPolicy: collisionPolicy) }
  }

  private func performDownload(_ collisionPolicy: CollisionPolicy) {
    guard let directory = pendingDownloadDirectory else { return }
    pendingDownloadDirectory = nil
    Task { await model.downloadSelected(to: directory, collisionPolicy: collisionPolicy) }
  }
}

private struct BucketBrowserView: View {
  @Bindable var model: WorkbenchViewModel
  @State private var selection = Set<BucketRow.ID>()

  var body: some View {
    List(model.buckets, selection: $selection) { bucket in
      HStack(spacing: 12) {
        Image(systemName: "shippingbox.fill")
          .font(.title2)
          .foregroundStyle(.tint)
          .frame(width: 30)
        VStack(alignment: .leading, spacing: 3) {
          Text(bucket.name).font(.body.weight(.medium))
          Text("Bucket").font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 24)
        if let date = bucket.creationDate {
          VStack(alignment: .trailing, spacing: 3) {
            Text("Created").font(.caption).foregroundStyle(.secondary)
            Text(date, format: .dateTime.year().month().day().hour().minute())
              .foregroundStyle(.secondary)
          }
        }
      }
      .padding(.vertical, 8)
      .contentShape(.rect)
      .tag(bucket.id)
      .onTapGesture(count: 2) { Task { await model.openBucket(bucket.name) } }
      .contextMenu {
        Button("Open") { Task { await model.openBucket(bucket.name) } }
      }
    }
    .onKeyPress(.return) {
      if selection.count == 1, let name = selection.first {
        Task { await model.openBucket(name) }
        return .handled
      }
      return .ignored
    }
    .navigationTitle(model.selectedConnection?.name ?? "Buckets")
    .overlay {
      if model.isLoadingBuckets, model.buckets.isEmpty {
        ProgressView("Loading buckets…")
      } else if let error = model.bucketErrorMessage, model.buckets.isEmpty {
        ContentUnavailableView {
          Label("Can’t Load Buckets", systemImage: "exclamationmark.triangle")
        } description: {
          Text(error)
        } actions: {
          Button("Retry") { Task { await model.reloadConnection() } }
        }
      } else if model.buckets.isEmpty {
        ContentUnavailableView(
          "No Buckets", systemImage: "shippingbox",
          description: Text("This connection contains no visible buckets."))
      }
    }
    .safeAreaInset(edge: .top) {
      if let error = model.bucketErrorMessage, !model.buckets.isEmpty {
        RefreshErrorBanner(message: error) { Task { await model.reloadConnection() } }
      } else if model.isLoadingBuckets, !model.buckets.isEmpty {
        RefreshProgressBanner(title: "Refreshing buckets…")
      }
    }
  }
}

private struct ObjectBrowserView: View {
  @Bindable var model: WorkbenchViewModel
  let requestUpload: () -> Void
  let queueUpload: ([URL]) -> Void
  let requestDelete: () -> Void
  let requestRename: (String) -> Void
  @State private var sortOrder: [ObjectSortComparator] = []

  private var displayedObjects: [ObjectRow] {
    guard !sortOrder.isEmpty else { return model.objects }
    return model.objects.sorted(
      using: sortOrder + [ObjectSortComparator(column: .name)])
  }

  var body: some View {
    Table(displayedObjects, selection: $model.selectedObjectIDs, sortOrder: $sortOrder) {
      TableColumn("Name", sortUsing: ObjectSortComparator(column: .name)) { object in
        Label(
          object.displayName,
          systemImage: object.isPrefix ? "folder.fill" : symbol(for: object.displayName)
        )
      }
      .width(min: 220, ideal: 420)
      TableColumn("Size", sortUsing: ObjectSortComparator(column: .size)) { object in
        Text(
          object.isPrefix
            ? "—" : ByteCountFormatter.string(fromByteCount: object.size, countStyle: .file)
        )
        .foregroundStyle(object.isPrefix ? .tertiary : .secondary)
      }
      .width(min: 75, ideal: 100)
      TableColumn("Modified", sortUsing: ObjectSortComparator(column: .modified)) { object in
        if let date = object.modifiedAt {
          Text(date, format: .dateTime.year().month().day().hour().minute())
        } else {
          Text("—").foregroundStyle(.tertiary)
        }
      }
      .width(min: 130, ideal: 170)
      TableColumn("Storage class", sortUsing: ObjectSortComparator(column: .storageClass)) {
        object in
        Text(object.storageClass ?? "—").foregroundStyle(.secondary)
      }
      .width(min: 100, ideal: 130)
    }
    .contextMenu(forSelectionType: ObjectRow.ID.self) { selection in
      if selection.count == 1,
        let object = model.objects.first(where: { selection.contains($0.id) })
      {
        Button(object.isPrefix ? "Open" : "Quick Look") {
          model.select(object)
          if object.isPrefix {
            Task { await model.openPrefix(object) }
          } else {
            Task { await model.previewSelected() }
          }
        }
        if !object.isPrefix {
          Button("Copy Presigned URL") {
            Task {
              model.select(object)
              guard let url = await model.presignedURL() else { return }
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
          }
          Button("Rename…") {
            model.select(object)
            requestRename(object.key)
          }
        }
      }
      if !selection.isEmpty,
        !model.objects.contains(where: { selection.contains($0.id) && $0.isPrefix })
      {
        Divider()
        Button("Delete", role: .destructive) {
          model.selectedObjectIDs = selection
          requestDelete()
        }
      }
    } primaryAction: { selection in
      guard selection.count == 1,
        let object = model.objects.first(where: { selection.contains($0.id) })
      else { return }
      if object.isPrefix {
        Task { await model.openPrefix(object) }
      } else {
        Task { await model.previewSelected() }
      }
    }
    .overlay {
      if model.isLoadingObjects, model.objects.isEmpty {
        ProgressView("Loading objects…")
      } else if let error = model.objectErrorMessage, model.objects.isEmpty {
        ContentUnavailableView {
          Label("Can’t Load Objects", systemImage: "exclamationmark.triangle")
        } description: {
          Text(error)
        } actions: {
          Button("Retry") { Task { await model.reloadObjects() } }
        }
      } else if model.objects.isEmpty {
        ContentUnavailableView {
          Label(model.searchQuery.isEmpty ? "Empty Prefix" : "No Matches", systemImage: "tray")
        } description: {
          Text(
            model.searchQuery.isEmpty
              ? "Drop files here or use Upload." : "Try a different object search.")
        } actions: {
          if model.searchQuery.isEmpty { Button("Upload Files") { requestUpload() } }
        }
      }
    }
    .safeAreaInset(edge: .top) {
      if let error = model.objectErrorMessage, !model.objects.isEmpty {
        RefreshErrorBanner(message: error) { Task { await model.reloadObjects() } }
      } else if model.isLoadingObjects, !model.objects.isEmpty {
        RefreshProgressBanner(title: "Refreshing objects…")
      }
    }
    .overlay {
      if model.isDropTargeted {
        RoundedRectangle(cornerRadius: 12)
          .stroke(.tint, style: StrokeStyle(lineWidth: 3, dash: [8]))
          .padding(12)
          .allowsHitTesting(false)
      }
    }
    .dropDestination(for: URL.self) { urls, _ in
      queueUpload(urls)
      return !urls.isEmpty
    } isTargeted: {
      model.isDropTargeted = $0
    }
    .safeAreaInset(edge: .bottom) {
      if model.continuationToken != nil {
        Button(model.isLoadingMore ? "Loading…" : "Load More") { Task { await model.loadMore() } }
          .disabled(model.isLoadingMore)
          .padding(8)
          .frame(maxWidth: .infinity)
          .background(.bar)
      }
    }
    .navigationTitle(model.selectedBucket ?? "Objects")
  }

  private func symbol(for name: String) -> String {
    let ext = (name as NSString).pathExtension.lowercased()
    if ["png", "jpg", "jpeg", "gif", "heic", "webp"].contains(ext) { return "photo" }
    if ["mov", "mp4", "m4v"].contains(ext) { return "film" }
    if ["zip", "gz", "tar", "7z"].contains(ext) { return "archivebox" }
    if ["json", "xml", "yaml", "yml", "txt", "md"].contains(ext) { return "doc.text" }
    return "doc"
  }

}

private struct RefreshProgressBanner: View {
  let title: String

  var body: some View {
    HStack(spacing: 8) {
      ProgressView().controlSize(.small)
      Text(title).font(.callout)
      Spacer()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 7)
    .background(.bar)
  }
}

private struct RefreshErrorBanner: View {
  let message: String
  let retry: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
      Text(message).font(.callout).lineLimit(2)
      Spacer()
      Button("Retry", action: retry)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 7)
    .background(.bar)
  }
}

private struct BreadcrumbView: View {
  @Bindable var model: WorkbenchViewModel

  var body: some View {
    HStack(spacing: 4) {
      if let bucket = model.selectedBucket {
        Button(bucket) {
          Task {
            model.navigate(to: model.accessRootPrefix)
            await model.reloadObjects()
          }
        }
        .buttonStyle(.plain)
        ForEach(prefixComponents.indices, id: \.self) { index in
          Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
          Button(prefixComponents[index]) {
            let destination = model.accessRootPrefix
              + prefixComponents.prefix(index + 1).joined(separator: "/") + "/"
            Task {
              model.navigate(to: destination)
              await model.reloadObjects()
            }
          }
          .buttonStyle(.plain)
        }
      } else {
        Text(model.selectedConnection?.name ?? "S3 Workbench")
      }
    }
    .lineLimit(1)
    .truncationMode(.head)
  }

  private var prefixComponents: [String] {
    String(model.prefix.dropFirst(model.accessRootPrefix.count))
      .split(separator: "/").map(String.init)
  }
}

private struct ObjectInspectorView: View {
  @Bindable var model: WorkbenchViewModel

  var body: some View {
    Group {
      if model.selectedObjectIDs.count > 1 {
        ContentUnavailableView(
          "Multiple Objects", systemImage: "doc.on.doc",
          description: Text("\(model.selectedObjectIDs.count) objects selected"))
      } else if let object = model.selectedObject {
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            VStack(spacing: 12) {
              Image(systemName: object.isPrefix ? "folder.fill" : "doc")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
              Text(object.displayName).font(.headline).multilineTextAlignment(.center)
                .textSelection(.enabled)
              if !object.isPrefix {
                Button("Quick Look") { Task { await model.previewSelected() } }
                  .keyboardShortcut(.space, modifiers: [])
              }
            }
            .frame(maxWidth: .infinity)

            if let details = model.objectDetails {
              InspectorSection("Metadata") {
                InspectorRow(
                  "Size", ByteCountFormatter.string(fromByteCount: details.size, countStyle: .file))
                InspectorRow("Content type", details.contentType ?? "—")
                InspectorRow("ETag", details.eTag ?? "—")
                InspectorRow("Storage class", details.storageClass ?? "—")
                if let date = details.lastModified {
                  InspectorRow("Modified", date.formatted(date: .abbreviated, time: .shortened))
                }
              }
              if !details.metadata.isEmpty {
                InspectorSection("Custom Metadata") {
                  ForEach(details.metadata.sorted(by: { $0.key < $1.key }), id: \.key) {
                    key, value in
                    InspectorRow(key, value)
                  }
                }
              }
              if !details.headers.isEmpty {
                InspectorSection("Headers") {
                  ForEach(details.headers.sorted(by: { $0.key < $1.key }), id: \.key) {
                    key, value in
                    InspectorRow(key, value)
                  }
                }
              }
            } else if !object.isPrefix {
              ProgressView().frame(maxWidth: .infinity)
            }
          }
          .padding()
        }
      } else {
        ContentUnavailableView(
          "No Selection", systemImage: "info.circle",
          description: Text("Select an object to inspect its metadata."))
      }
    }
    .navigationTitle("Inspector")
  }
}

private struct InspectorSection<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.headline)
      content
    }
  }
}

private struct InspectorRow: View {
  let label: String
  let value: String

  init(_ label: String, _ value: String) {
    self.label = label
    self.value = value
  }

  var body: some View {
    LabeledContent(label) {
      Text(value).textSelection(.enabled).multilineTextAlignment(.trailing)
    }
    .font(.caption)
  }
}

private struct TransferListView: View {
  @Bindable var model: WorkbenchViewModel

  var body: some View {
    Group {
      if model.transfers.isEmpty {
        ContentUnavailableView(
          "No Transfers", systemImage: "arrow.up.arrow.down",
          description: Text("Uploads and downloads appear here."))
      } else {
        List(model.transfers) { transfer in
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              VStack(alignment: .leading) {
                Text(transfer.title).lineLimit(1)
                Text(transfer.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
              }
              Spacer()
              Text(transfer.state.rawValue).font(.caption).foregroundStyle(.secondary)
            }
            ProgressView(value: transfer.progress)
            if let error = transfer.errorMessage {
              Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
              Spacer()
              if transfer.state == .running || transfer.state == .queued {
                Button("Cancel") { Task { await model.cancelTransfer(transfer) } }
              } else if transfer.state == .failed || transfer.state == .cancelled {
                Button("Retry") { Task { await model.retryTransfer(transfer) } }
              }
            }
          }
          .padding(.vertical, 4)
        }
      }
    }
    .frame(width: 410, height: 300)
    .task {
      while !Task.isCancelled {
        await model.refreshTransfers()
        try? await Task.sleep(for: .milliseconds(500))
      }
    }
  }
}

private struct RenameObjectView: View {
  @Environment(\.dismiss) private var dismiss
  @State var key: String
  @State private var collisionPolicy = CollisionPolicy.cancel
  let save: (String, CollisionPolicy) async -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Rename Object").font(.title2.bold())
      TextField("Object key", text: $key)
      Picker("If destination exists", selection: $collisionPolicy) {
        ForEach(CollisionPolicy.allCases) { policy in
          Text(policy.label).tag(policy)
        }
      }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Rename") { Task { await save(key, collisionPolicy) } }
          .keyboardShortcut(.defaultAction)
          .disabled(key.isEmpty)
      }
    }
    .padding(24)
    .frame(width: 480)
  }
}
