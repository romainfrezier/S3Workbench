import Foundation
import Testing
@testable import S3WorkbenchCore

@Test func searchIndexBenchmark() async throws {
    guard let rawCount = ProcessInfo.processInfo.environment["S3_SEARCH_BENCHMARK_OBJECTS"],
          let objectCount = Int(rawCount), objectCount > 0 else { return }

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("S3Workbench-SearchBenchmark-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appendingPathComponent("search-index.sqlite3")
    let scope = ObjectIndexScope(connectionID: UUID(), bucket: "benchmark", prefix: "bench/")
    let index = try ObjectSearchIndex(fileURL: databaseURL)
    let clock = ContinuousClock()
    let pageSize = 1_000
    let benchmarkObjects = objects(in: 0..<objectCount)

    let buildStart = clock.now
    let build = try await index.beginRebuild(for: scope)
    for start in stride(from: 0, to: objectCount, by: pageSize) {
        let end = min(start + pageSize, objectCount)
        try await index.append(Array(benchmarkObjects[start..<end]), to: build)
    }
    let snapshot = try await index.finishRebuild(build)
    let buildSeconds = seconds(buildStart.duration(to: clock.now))

    var queryDurations: [Double] = []
    var indexedMatchCount = 0
    for _ in 0..<30 {
        let start = clock.now
        let page = try #require(
            try await index.search(scope: scope, matching: "needle", below: "bench/")
        )
        queryDurations.append(seconds(start.duration(to: clock.now)))
        indexedMatchCount = page.objects.count
    }

    var scanDurations: [Double] = []
    var scannedMatchCount = 0
    for _ in 0..<10 {
        let start = clock.now
        let matches = benchmarkObjects.count {
            $0.key.range(of: "needle", options: .caseInsensitive) != nil
        }
        scanDurations.append(seconds(start.duration(to: clock.now)))
        scannedMatchCount = matches
    }

    #expect(snapshot.objectCount == objectCount)
    #expect(indexedMatchCount == scannedMatchCount)

    let attributes = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
    let databaseBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    let result: [String: Any] = [
        "build_ms": milliseconds(buildSeconds),
        "database_bytes": databaseBytes,
        "estimated_list_requests_cold": Int(ceil(Double(objectCount) / Double(pageSize))),
        "estimated_list_requests_warm": 0,
        "matches": indexedMatchCount,
        "object_count": objectCount,
        "scan_p50_ms": milliseconds(percentile(scanDurations, 0.50)),
        "warm_query_p50_ms": milliseconds(percentile(queryDurations, 0.50)),
        "warm_query_p95_ms": milliseconds(percentile(queryDurations, 0.95)),
    ]
    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    print("SEARCH_BENCHMARK \(String(decoding: data, as: UTF8.self))")
}

private func objects(in range: Range<Int>) -> [S3Object] {
    range.map { index in
        let name = index.isMultiple(of: 997)
            ? "bench/nested/needle-report-\(index).json"
            : "bench/nested/object-\(index).json"
        return S3Object(
            key: name,
            size: Int64(index),
            lastModified: Date(timeIntervalSince1970: 1_700_000_000),
            eTag: nil,
            storageClass: "STANDARD"
        )
    }
}

private func seconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
}

private func milliseconds(_ seconds: Double) -> Double {
    (seconds * 1_000_000).rounded() / 1_000
}

private func percentile(_ values: [Double], _ percentile: Double) -> Double {
    let sorted = values.sorted()
    let index = min(Int((Double(sorted.count) * percentile).rounded(.up)) - 1, sorted.count - 1)
    return sorted[max(index, 0)]
}
