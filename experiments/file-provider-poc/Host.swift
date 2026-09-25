import FileProvider
import Foundation

@main
enum Host {
    static func main() {
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("readonly-fixture"),
                                          displayName: "S3Workbench POC")
        let complete: (Error?) -> Void = { error in
            if let error = error as NSError? {
                // No connections or real object names are used by this synthetic probe.
                print("File Provider: \(error.domain) (\(error.code)): \(error.localizedDescription)")
                exit(1)
            }
            print("File Provider operation succeeded")
            exit(0)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
            print("File Provider operation timed out after 30 seconds")
            exit(2)
        }
        switch CommandLine.arguments.dropFirst().first {
        case "add": NSFileProviderManager.add(domain, completionHandler: complete)
        case "remove": NSFileProviderManager.remove(domain, completionHandler: complete)
        default: print("Usage: Host add|remove"); exit(2)
        }
        dispatchMain()
    }
}
