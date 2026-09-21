import FileProvider
import UniformTypeIdentifiers

// This immutable fixture tests the macOS extension boundary before connecting S3.
final class FixtureItem: NSObject, NSFileProviderItem {
    static let fileID = NSFileProviderItemIdentifier("fixture-readme")
    static let contents = Data("S3Workbench File Provider POC — read-only fixture.\n".utf8)
    let itemIdentifier: NSFileProviderItemIdentifier
    init(_ identifier: NSFileProviderItemIdentifier) { itemIdentifier = identifier }
    var parentItemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var filename: String { itemIdentifier == .rootContainer ? "S3Workbench POC" : "README.txt" }
    var contentType: UTType { itemIdentifier == .rootContainer ? .folder : .plainText }
    var capabilities: NSFileProviderItemCapabilities {
        itemIdentifier == .rootContainer ? .allowsContentEnumerating : .allowsReading
    }
    var documentSize: NSNumber? { itemIdentifier == .rootContainer ? nil : NSNumber(value: Self.contents.count) }
    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: Data("1".utf8), metadataVersion: Data("1".utf8))
    }
}

final class FixtureEnumerator: NSObject, NSFileProviderEnumerator {
    static let anchor = NSFileProviderSyncAnchor(Data("immutable-fixture-v1".utf8))
    private var invalidated = false
    private let lock = NSLock()
    func invalidate() { lock.lock(); defer { lock.unlock() }; invalidated = true }
    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        lock.lock(); defer { lock.unlock() }
        guard !invalidated else { observer.finishEnumeratingWithError(CocoaError(.userCancelled)); return }
        guard page.rawValue == NSFileProviderPage.initialPageSortedByName as Data ||
                page.rawValue == NSFileProviderPage.initialPageSortedByDate as Data else {
            observer.finishEnumeratingWithError(NSFileProviderError(.pageExpired)); return
        }
        observer.didEnumerate([FixtureItem(FixtureItem.fileID)])
        observer.finishEnumerating(upTo: nil)
    }
    // ponytail: immutable fixture only; real S3 needs durable change tracking before this is reused.
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        lock.lock(); defer { lock.unlock() }
        guard !invalidated else { observer.finishEnumeratingWithError(CocoaError(.userCancelled)); return }
        guard anchor == Self.anchor else {
            observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired)); return
        }
        observer.finishEnumeratingChanges(upTo: Self.anchor, moreComing: false)
    }
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(Self.anchor)
    }
}

@objc(POCProvider)
final class POCProvider: NSObject, NSFileProviderReplicatedExtension {
    private let domain: NSFileProviderDomain
    required init(domain: NSFileProviderDomain) { self.domain = domain; super.init() }
    func invalidate() {}
    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        guard containerItemIdentifier == .rootContainer || containerItemIdentifier == .workingSet ||
                containerItemIdentifier == FixtureItem.fileID else {
            throw NSFileProviderError(.noSuchItem)
        }
        return FixtureEnumerator()
    }
    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        if identifier == .rootContainer || identifier == FixtureItem.fileID {
            completionHandler(FixtureItem(identifier), nil)
        } else {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
        }
        return Progress(totalUnitCount: 0)
    }
    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: Int64(FixtureItem.contents.count))
        guard itemIdentifier == FixtureItem.fileID else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem)); return progress
        }
        do {
            guard let manager = NSFileProviderManager(for: domain) else {
                throw NSFileProviderError(.providerNotFound)
            }
            let url = try manager.temporaryDirectoryURL().appendingPathComponent(UUID().uuidString)
            try FixtureItem.contents.write(to: url, options: .atomic)
            progress.completedUnitCount = progress.totalUnitCount
            completionHandler(url, FixtureItem(itemIdentifier), nil)
        } catch { completionHandler(nil, nil, error) }
        return progress
    }
    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields,
                    contents: URL?, options: NSFileProviderCreateItemOptions, request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        completionHandler(nil, [], false, CocoaError(.fileWriteNoPermission))
        return Progress(totalUnitCount: 0)
    }
    func modifyItem(_ item: NSFileProviderItem, baseVersion: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields, contents: URL?, options: NSFileProviderModifyItemOptions,
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        completionHandler(nil, [], false, CocoaError(.fileWriteNoPermission))
        return Progress(totalUnitCount: 0)
    }
    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions, request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        completionHandler(CocoaError(.fileWriteNoPermission))
        return Progress(totalUnitCount: 0)
    }
}
