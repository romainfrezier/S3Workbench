import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ObjectFilePromise: Sendable {
  let location: ObjectLocation
  let object: ObjectRow
  let selectionIDs: Set<ObjectRow.ID>
  let filename: String

  init(location: ObjectLocation, object: ObjectRow, selectionIDs: Set<ObjectRow.ID>) throws {
    let filename = object.displayName
    guard !object.isPrefix, !filename.isEmpty, filename != ".", filename != "..",
      !filename.contains("/"), !filename.contains("\0")
    else {
      throw WorkbenchUIError.invalidExportFilename
    }
    self.location = location
    self.object = object
    self.selectionIDs = selectionIDs
    self.filename = filename
  }
}

enum ObjectFilePromiseProvider {
  typealias Fulfill = @MainActor @Sendable (ObjectFilePromise, URL) async throws -> Void

  @MainActor
  static func make(
    for promise: ObjectFilePromise,
    fulfill: @escaping Fulfill
  ) -> NSFilePromiseProvider {
    let delegate = ObjectFilePromiseDelegate(promise: promise, fulfill: fulfill)
    let provider = NSFilePromiseProvider(fileType: UTType.data.identifier, delegate: delegate)
    provider.userInfo = delegate
    return provider
  }
}

private final class ObjectFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate,
  @unchecked Sendable
{
  let promise: ObjectFilePromise
  let fulfill: ObjectFilePromiseProvider.Fulfill

  init(promise: ObjectFilePromise, fulfill: @escaping ObjectFilePromiseProvider.Fulfill) {
    self.promise = promise
    self.fulfill = fulfill
  }

  @MainActor
  func filePromiseProvider(
    _ filePromiseProvider: NSFilePromiseProvider,
    fileNameForType fileType: String
  ) -> String {
    promise.filename
  }

  nonisolated func filePromiseProvider(
    _ filePromiseProvider: NSFilePromiseProvider,
    writePromiseTo url: URL,
    completionHandler: @escaping @Sendable ((any Error)?) -> Void
  ) {
    let promise = promise
    let fulfill = fulfill
    Task { @MainActor in
      do {
        try await fulfill(promise, url)
        completionHandler(nil)
      } catch {
        completionHandler(error)
      }
    }
  }
}

struct ObjectFilePromiseDragSource: NSViewRepresentable {
  let symbolName: String
  let prepareSelection: @MainActor () -> Void
  let makeProviders: @MainActor () -> [NSFilePromiseProvider]

  func makeNSView(context: Context) -> ObjectFilePromiseDragImageView {
    ObjectFilePromiseDragImageView()
  }

  func updateNSView(_ view: ObjectFilePromiseDragImageView, context: Context) {
    let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    image?.isTemplate = true
    view.image = image
    view.prepareSelection = prepareSelection
    view.makeProviders = makeProviders
  }
}

@MainActor
final class ObjectFilePromiseDragImageView: NSImageView, NSDraggingSource {
  var prepareSelection: () -> Void = {}
  var makeProviders: () -> [NSFilePromiseProvider] = { [] }
  private var isDragging = false

  override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 16) }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    imageScaling = .scaleProportionallyDown
    contentTintColor = .secondaryLabelColor
    setAccessibilityRole(.image)
    setAccessibilityLabel("Drag to Finder")
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func mouseDown(with event: NSEvent) {
    prepareSelection()
  }

  override func mouseDragged(with event: NSEvent) {
    guard !isDragging else { return }
    let providers = makeProviders()
    guard !providers.isEmpty else { return }
    let items = providers.map { provider in
      let item = NSDraggingItem(pasteboardWriter: provider)
      item.setDraggingFrame(bounds, contents: image)
      return item
    }
    isDragging = true
    beginDraggingSession(with: items, event: event, source: self)
  }

  func draggingSession(
    _ session: NSDraggingSession,
    sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    context == .outsideApplication ? .copy : []
  }

  func draggingSession(
    _ session: NSDraggingSession,
    endedAt screenPoint: NSPoint,
    operation: NSDragOperation
  ) {
    isDragging = false
  }
}
