import Foundation
import S3WorkbenchCore

actor TransferManager<Operation: Sendable> {
  typealias Progress = @Sendable (Double) -> Void
  typealias Executor = @Sendable (Operation, @escaping Progress) async throws -> Void

  private struct Entry {
    var row: TransferRow
    let operation: Operation
    let executor: Executor
    var error: (any Error)?
  }

  private let maximumConcurrentTransfers: Int
  private var entries: [UUID: Entry] = [:]
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private var activeCount = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(maximumConcurrentTransfers: Int) {
    self.maximumConcurrentTransfers = maximumConcurrentTransfers
  }

  @discardableResult
  func enqueue(
    _ operation: Operation,
    title: String,
    subtitle: String,
    executor: @escaping Executor
  ) -> UUID {
    let id = UUID()
    entries[id] = Entry(
      row: TransferRow(
        id: id, title: title, subtitle: subtitle, progress: 0, state: .queued,
        errorMessage: nil),
      operation: operation,
      executor: executor,
      error: nil
    )
    tasks[id] = Task { [weak self] in
      await self?.run(id: id, operation: operation, executor: executor)
    }
    return id
  }

  func waitForCompletion(of ids: [UUID]) async throws {
    try await withTaskCancellationHandler {
      for id in ids {
        try Task.checkCancellation()
        await tasks[id]?.value
      }
      try Task.checkCancellation()
      for id in ids {
        guard let entry = entries[id] else { continue }
        if entry.row.state == .cancelled { throw S3ServiceError.cancelled }
        if let error = entry.error { throw error }
      }
    } onCancel: {
      Task {
        for id in ids { await self.cancel(id: id) }
      }
    }
  }

  func rows() -> [TransferRow] {
    entries.values.map(\.row).sorted { lhs, rhs in
      if lhs.state == rhs.state {
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
      }
      return priority(lhs.state) < priority(rhs.state)
    }
  }

  func cancel(id: UUID) {
    guard let state = entries[id]?.row.state, state == .queued || state == .running else {
      return
    }
    tasks[id]?.cancel()
    update(id: id, state: .cancelled)
  }

  func retry(id: UUID) async {
    guard let entry = entries[id] else { return }
    if let task = tasks[id] {
      task.cancel()
      await task.value
    }
    entries.removeValue(forKey: id)
    tasks.removeValue(forKey: id)
    enqueue(
      entry.operation,
      title: entry.row.title,
      subtitle: entry.row.subtitle,
      executor: entry.executor
    )
  }

  private func run(id: UUID, operation: Operation, executor: @escaping Executor) async {
    await acquireSlot()
    defer { releaseSlot() }
    guard !Task.isCancelled else {
      update(id: id, state: .cancelled)
      tasks.removeValue(forKey: id)
      return
    }
    update(id: id, state: .running)
    do {
      try await executor(operation) { [weak self] progress in
        Task { await self?.update(id: id, progress: progress) }
      }
      try Task.checkCancellation()
      update(id: id, progress: 1, state: .completed)
    } catch is CancellationError {
      update(id: id, state: .cancelled)
    } catch let error as S3ServiceError where error == .cancelled {
      update(id: id, state: .cancelled)
    } catch {
      update(id: id, state: .failed, error: error)
    }
    tasks.removeValue(forKey: id)
  }

  private func acquireSlot() async {
    if activeCount < maximumConcurrentTransfers {
      activeCount += 1
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }

  private func releaseSlot() {
    if !waiters.isEmpty {
      waiters.removeFirst().resume()
    } else {
      activeCount -= 1
    }
  }

  private func update(
    id: UUID,
    progress: Double? = nil,
    state: TransferState? = nil,
    error: (any Error)? = nil
  ) {
    guard var entry = entries[id] else { return }
    entry.row = TransferRow(
      id: entry.row.id,
      title: entry.row.title,
      subtitle: entry.row.subtitle,
      progress: progress ?? entry.row.progress,
      state: state ?? entry.row.state,
      errorMessage: error?.localizedDescription
    )
    entry.error = error
    entries[id] = entry
  }

  private func priority(_ state: TransferState) -> Int {
    switch state {
    case .running: 0
    case .queued: 1
    case .failed: 2
    case .cancelled: 3
    case .completed: 4
    }
  }
}
