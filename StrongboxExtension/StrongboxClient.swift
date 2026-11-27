import Foundation

final class StrongboxClient: @unchecked Sendable {
  /// How long a copied value stays on the clipboard. When vaults lock is Strongbox's decision.
  static let pasteWindow: TimeInterval = 30
  /// The most entries one search returns. A full list may have been cut off.
  static let searchLimit = 20
  /// The shortest entry name searched. The actions aren't offered for less, and nothing shorter is sent.
  static let minimumQueryLength = 2

  /// The trimmed entry name, or nil when it's too short to search.
  static func entryName(_ text: String?) -> String? {
    let name = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return name.count >= minimumQueryLength ? name : nil
  }

  private let queue = DispatchQueue(label: "com.brnbw.tuna.plugins.strongbox.transport", qos: .userInitiated)
  private let worker: StrongboxWorker

  convenience init(installation: StrongboxInstallation = StrongboxInstallation()) {
    self.init { try MCPConnection(installation: installation) }
  }

  init(connect: @escaping () throws -> MCPConnection) {
    worker = StrongboxWorker(connect: connect)
  }

  func databases() async throws -> [StrongboxDatabase] {
    try await perform { try $0.databases() }
  }

  func search(_ query: String, databaseID: String) async throws -> [StrongboxEntry] {
    try await perform { try $0.search(query, databaseID: databaseID) }
  }

  func value(of field: StrongboxField, in entry: StrongboxEntry) async throws -> String {
    try await perform { try $0.value(of: field, in: entry) }
  }

  /// A request already sent can't be withdrawn, so a result that arrives after cancellation is dropped.
  private func perform<Value>(_ operation: @escaping @Sendable (StrongboxWorker) throws -> Value) async throws -> Value {
    try Task.checkCancellation()
    let cancellation = RequestCancellation()
    let value = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        queue.async {
          do {
            try cancellation.check()
            continuation.resume(returning: try operation(self.worker))
          } catch { continuation.resume(throwing: error) }
        }
      }
    } onCancel: { cancellation.cancel() }
    try Task.checkCancellation()
    return value
  }
}

private final class RequestCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  func cancel() {
    lock.lock()
    defer { lock.unlock() }
    cancelled = true
  }

  func check() throws {
    lock.lock()
    defer { lock.unlock() }
    if cancelled { throw CancellationError() }
  }
}

private final class StrongboxWorker {
  private let connect: () throws -> MCPConnection
  private var connection: MCPConnection?

  init(connect: @escaping () throws -> MCPConnection) { self.connect = connect }

  private func tool(_ tool: StrongboxTool, arguments: [String: JSONValue] = [:]) throws -> JSONValue {
    if connection == nil { connection = try connect() }
    do { return try connection!.tool(tool, arguments: arguments) }
    catch {
      if let failure = error as? StrongboxError,
       failure == .timedOut || failure == .unavailable || failure == .invalidResponse || failure == .disconnected {
        connection = nil
      }
      throw error
    }
  }

  /// Asks Strongbox for access only when it says this request needs it, then retries once.
  private func withAccess<Value>(databaseID: String, _ operation: () throws -> Value) throws -> Value {
    do { return try operation() }
    catch StrongboxError.locked {
      _ = try tool(.unlock, arguments: ["database_id": .string(databaseID)])
      return try operation()
    }
  }

  func databases() throws -> [StrongboxDatabase] {
    try tool(.list).decoded(as: DatabaseList.self).databases
  }

  func search(_ query: String, databaseID: String) throws -> [StrongboxEntry] {
    guard let query = StrongboxClient.entryName(query) else { return [] }
    let result = try withAccess(databaseID: databaseID) {
      try tool(.search, arguments: [
        "database_id": .string(databaseID), "query": .string(String(query.prefix(256))), "limit": .number(Double(StrongboxClient.searchLimit)),
      ]).decoded(as: EntryList.self)
    }
    guard result.matches.allSatisfy({ sameID($0.databaseID, databaseID) && UUID(uuidString: $0.id) != nil }) else {
      throw StrongboxError.invalidResponse
    }
    return result.matches
  }

  func value(of field: StrongboxField, in entry: StrongboxEntry) throws -> String {
    guard field == .username else { return try reveal(field.rawValue, in: entry) }
    // Search already returned the username, so copying it needs no reveal approval.
    if !entry.username.isEmpty, !entry.username.hasPrefix("{REF:") { return entry.username }
    guard let email = entry.emailField else { throw StrongboxError.unavailableEntry }
    return try reveal(email, in: entry)
  }

  private func reveal(_ name: String, in entry: StrongboxEntry) throws -> String {
    // Strongbox would prompt, then refuse with a generic error, for a field the entry doesn't have.
    guard entry.mayHave(name) else { throw StrongboxError.unavailableEntry }
    let response = try withAccess(databaseID: entry.databaseID) {
      try tool(.reveal, arguments: [
        "database_id": .string(entry.databaseID), "credential_id": .string(entry.id), "fields": .array([.string(name)]),
      ])
    }
    guard !response.listsUnavailable(name) else { throw StrongboxError.unavailableEntry }
    guard let value = response.revealedValue(name) else { throw StrongboxError.unexpectedReveal(shape: response.shape) }
    guard !value.isEmpty, !value.hasPrefix("{REF:") else { throw StrongboxError.unavailableEntry }
    return value
  }

  private func sameID(_ first: String, _ second: String) -> Bool {
    guard let first = UUID(uuidString: first), let second = UUID(uuidString: second) else { return false }
    return first == second
  }
}
