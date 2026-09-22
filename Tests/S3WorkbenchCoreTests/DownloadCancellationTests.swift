import Foundation
import Network
import Testing
@testable import S3WorkbenchCore

@Test func cancellingAStalledDownloadPreservesTheDestinationAndRemovesTemporaryFile() async throws {
    try await checkCancelledDownload(cancelAfterLastChunk: false)
}

@Test func cancellingAfterTheFinalChunkDoesNotPublishTheDownload() async throws {
    try await checkCancelledDownload(cancelAfterLastChunk: true)
}

private func checkCancelledDownload(cancelAfterLastChunk: Bool) async throws {
    let server = try StalledDownloadServer()
    let endpoint = try await server.start()
    defer { server.stop() }
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("S3Workbench-Cancel-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("existing.bin")
    let original = Data("existing destination".utf8)
    try original.write(to: destination)
    let service = try AWSS3Service(
        profile: ConnectionProfile(name: "Cancellation fixture", endpoint: endpoint,
                                   region: "us-east-1", addressingStyle: .path),
        credentials: S3Credentials(accessKey: "fixture-access", secretKey: "fixture-secret"))
    let probe = DownloadCancellationProbe()
    let task = Task {
        defer { probe.finish() }
        try await service.downloadFile(bucket: "fixture", key: "stalled.bin", to: destination,
                                       overwrite: true) { update in
            probe.record(update.bytesTransferred)
            if cancelAfterLastChunk, update.bytesTransferred == update.totalBytes {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
    }
    defer { task.cancel() }
    for _ in 0..<200 where probe.bytes == 0 {
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(probe.bytes > 0, "The SDK must have received part of the response before cancellation")
    if cancelAfterLastChunk {
        server.finishResponse()
    } else {
        task.cancel()
    }
    for _ in 0..<80 where !probe.finished {
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(probe.finished, "Cancellation must finish without waiting for additional response bytes")
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["existing.bin"],
            "Cancellation must remove its temporary download")
    #expect(try Data(contentsOf: destination) == original)
    // Always release the network read, including on an assertion failure on old code.
    server.finishResponse()
    await #expect(throws: S3ServiceError.cancelled) { try await task.value }
    #expect(try Data(contentsOf: destination) == original)
}

private final class DownloadCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var received: Int64 = 0
    private var didFinish = false
    var bytes: Int64 { lock.withLock { received } }
    var finished: Bool { lock.withLock { didFinish } }
    func record(_ bytes: Int64) { lock.withLock { received = bytes } }
    func finish() { lock.withLock { didFinish = true } }
}

// Loopback-only HTTP fixture: one partial response, then an explicit release or 10 s watchdog.
private final class StalledDownloadServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "S3Workbench.DownloadCancellationFixture")
    private let listener: NWListener
    private var connection: NWConnection?
    private var released = false

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(listener.port!.rawValue)")!)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [self] connection in
                self.connection = connection
                connection.start(queue: queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { _, _, _, _ in
                    let headers = "HTTP/1.1 200 OK\r\nContent-Length: 2048\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(headers.utf8) + Data(repeating: 65, count: 1024),
                                    completion: .contentProcessed { _ in })
                }
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 10) { [self] in
                finishOnQueue()
                listener.cancel()
                connection?.cancel()
            }
        }
    }

    func finishResponse() { queue.async { [self] in finishOnQueue() } }

    private func finishOnQueue() {
        guard !released, let connection else { return }
        released = true
        connection.send(content: Data(repeating: 66, count: 1024), isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    func stop() {
        queue.sync {
            listener.newConnectionHandler = nil
            listener.cancel()
            connection?.cancel()
        }
    }
}
