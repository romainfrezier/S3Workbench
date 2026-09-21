import FileProvider

final class Observer: NSObject, NSFileProviderEnumerationObserver {
    var items: [NSFileProviderItem] = []
    var finished = false
    var error: Error?
    func didEnumerate(_ updatedItems: [NSFileProviderItem]) { items += updatedItems }
    func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
        precondition(nextPage == nil)
        finished = true
    }
    func finishEnumeratingWithError(_ error: Error) { self.error = error }
}

@main
enum Checks {
    static func main() {
        let root = FixtureItem(.rootContainer)
        let file = FixtureItem(FixtureItem.fileID)
        precondition(root.capabilities == .allowsContentEnumerating)
        precondition(file.capabilities == .allowsReading)
        precondition(file.parentItemIdentifier == root.itemIdentifier)
        precondition(file.documentSize?.intValue == FixtureItem.contents.count)
        let enumerator = FixtureEnumerator()
        let first = Observer()
        let initialPage = NSFileProviderPage(NSFileProviderPage.initialPageSortedByName as Data)
        enumerator.enumerateItems(for: first, startingAt: initialPage)
        precondition(first.finished && first.error == nil && first.items.count == 1)
        precondition(first.items[0].itemIdentifier == FixtureItem.fileID)
        let badPage = Observer()
        enumerator.enumerateItems(for: badPage, startingAt: NSFileProviderPage(Data("invalid".utf8)))
        precondition(badPage.items.isEmpty && (badPage.error as NSError?)?.code == NSFileProviderError.pageExpired.rawValue)
        enumerator.invalidate()
        let cancelled = Observer()
        enumerator.enumerateItems(for: cancelled, startingAt: initialPage)
        precondition(cancelled.items.isEmpty && (cancelled.error as NSError?)?.code == CocoaError.userCancelled.rawValue)
        print("PASS: read-only capabilities, fixture metadata, enumeration, invalid page, invalidation")
    }
}
