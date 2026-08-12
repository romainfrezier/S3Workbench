import Foundation

public actor ConnectionStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    public init(fileURL: URL) {
        self.fileURL = fileURL
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public static func applicationSupport(appName: String = "S3Workbench") throws -> ConnectionStore {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent(appName, isDirectory: true)
        return ConnectionStore(fileURL: directory.appendingPathComponent("connections.json"))
    }

    public func load() throws -> [ConnectionProfile] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try decoder.decode([ConnectionProfile].self, from: Data(contentsOf: fileURL))
    }

    public func save(_ profiles: [ConnectionProfile]) throws {
        let validated = try profiles.map { try $0.validated() }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(validated).write(to: fileURL, options: [.atomic])
    }

    @discardableResult
    public func upsert(_ profile: ConnectionProfile) throws -> [ConnectionProfile] {
        let profile = try profile.validated()
        var profiles = try load()
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        try save(profiles)
        return profiles
    }

    @discardableResult
    public func remove(id: UUID) throws -> [ConnectionProfile] {
        var profiles = try load()
        profiles.removeAll { $0.id == id }
        try save(profiles)
        return profiles
    }
}
