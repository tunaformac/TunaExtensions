import AppKit
import Foundation
import OSLog

enum FantasticalMCPError: LocalizedError, Equatable {
  case helperNotFound
  case notRunning(detail: String?)
  case timeout
  case invalidResponse
  case tool(String)

  var title: String {
    switch self {
    case .helperNotFound: return "Fantastical 4.1.17 or later required"
    case .notRunning: return "Fantastical is not responding"
    case .timeout: return "Fantastical took too long"
    case .invalidResponse: return "Unexpected reply from Fantastical"
    case .tool: return "Fantastical could not complete that"
    }
  }

  var errorDescription: String? {
    switch self {
    case .helperNotFound:
      return "Install Fantastical in /Applications. Its built-in MCP helper provides the agenda."
    case .notRunning(let detail):
      guard let detail, !detail.isEmpty else { return "Open Fantastical and try again." }
      return "Fantastical's helper stopped: \(detail)"
    case .timeout: return "Fantastical did not answer within 60 seconds."
    case .invalidResponse: return "The helper returned something Tuna could not read."
    case .tool(let message): return message
    }
  }
}

struct FantasticalMCPResult: Sendable {
  let text: String
  let isError: Bool
}

/// Talks JSON-RPC over stdio to Fantastical's bundled MCP helper. One process lives for the
/// session; Fantastical asks the user once to allow the host app.
actor FantasticalMCPClient {
  static let shared = FantasticalMCPClient()
  static let log = Logger(subsystem: "com.brnbw.tuna.plugins.fantastical", category: "mcp")

  private var process: Process?
  private var input: FileHandle?
  private var output: FileHandle?
  private var errorOutput: FileHandle?
  private var startup: Task<Void, Error>?
  private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
  private var nextID = 1
  private var initialized = false
  private var lastStderrLine: String?
  private let timeoutSeconds: UInt64 = 60

  static func helperURL() -> URL? {
    guard
      let app = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: FantasticalIdentifiers.bundleIdentifier)
    else { return nil }
    let url = app.appending(path: "Contents/Helpers/FantasticalMCP.app/Contents/MacOS/FantasticalMCP")
    return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
  }

  static func makeRequest(id: Int?, method: String, params: [String: Any]) -> [String: Any] {
    var request: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
    if let id { request["id"] = id }
    return request
  }

  func call(_ tool: String, arguments: [String: Any] = [:]) async throws -> FantasticalMCPResult {
    Self.log.info("call \(tool, privacy: .public)")
    try await ensureRunning()
    let response = try await request(
      method: "tools/call", params: ["name": tool, "arguments": arguments])
    guard let result = response["result"] as? [String: Any] else {
      if let error = response["error"] as? [String: Any], let message = error["message"] as? String {
        throw FantasticalMCPError.tool(message)
      }
      throw FantasticalMCPError.invalidResponse
    }
    let content = result["content"] as? [[String: Any]] ?? []
    let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    let isError = result["isError"] as? Bool ?? false
    if isError {
      throw FantasticalMCPError.tool(text.isEmpty ? "Fantastical reported an error." : text)
    }
    return FantasticalMCPResult(text: text, isError: false)
  }

  func shutdown() {
    output?.readabilityHandler = nil
    output = nil
    errorOutput?.readabilityHandler = nil
    errorOutput = nil
    if let process {
      process.terminationHandler = nil
      try? input?.close()
      process.terminate()
      DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      }
    }
    process = nil
    input = nil
    initialized = false
    failAllPending(with: FantasticalMCPError.notRunning(detail: lastStderrLine))
  }

  // MARK: Process lifecycle

  /// Concurrent callers share one startup; the actor is reentrant at every await, so without
  /// this a second caller would see a process that is running but not yet initialized.
  private func ensureRunning() async throws {
    if let process, process.isRunning, initialized { return }
    if let startup {
      try await startup.value
      return
    }
    let task = Task { try await self.start() }
    startup = task
    defer { startup = nil }
    try await task.value
  }

  private func start() async throws {
    shutdown()
    lastStderrLine = nil
    guard let url = Self.helperURL() else { throw FantasticalMCPError.helperNotFound }

    let process = Process()
    process.executableURL = url
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    process.terminationHandler = { [weak self] _ in
      Task { await self?.handleTermination() }
    }
    try process.run()
    Self.log.info("helper started pid \(process.processIdentifier, privacy: .public)")
    self.process = process
    self.input = stdin.fileHandleForWriting
    output = stdout.fileHandleForReading
    errorOutput = stderr.fileHandleForReading
    Self.readLines(from: stdout.fileHandleForReading) { [weak self] line in
      Task { await self?.deliver(line: line) }
    }
    Self.readLines(from: stderr.fileHandleForReading) { [weak self] line in
      Task { await self?.remember(stderrLine: line) }
    }

    _ = try await request(
      method: "initialize",
      params: [
        "protocolVersion": "2025-06-18",
        "capabilities": [String: Any](),
        "clientInfo": ["name": "Tuna", "version": "1.0"],
      ])
    try send(Self.makeRequest(id: nil, method: "notifications/initialized", params: [:]))
    initialized = true
  }

  private func handleTermination() {
    Self.log.error("helper exited: \(self.lastStderrLine ?? "no stderr", privacy: .public)")
    process = nil
    input = nil
    initialized = false
    failAllPending(with: FantasticalMCPError.notRunning(detail: lastStderrLine))
  }

  private func remember(stderrLine: String) {
    let trimmed = stderrLine.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    Self.log.info("helper stderr: \(trimmed, privacy: .public)")
    lastStderrLine = trimmed.replacingOccurrences(
      of: #"^\S+ \S+ \S+: \[FantasticalMCP\] "#, with: "", options: .regularExpression)
  }

  private func failAllPending(with error: Error) {
    let waiting = pending
    pending = [:]
    for (_, continuation) in waiting {
      continuation.resume(throwing: error)
    }
  }

  // MARK: JSON-RPC

  private func request(method: String, params: [String: Any]) async throws -> [String: Any] {
    let id = nextID
    nextID += 1
    let payload = Self.makeRequest(id: id, method: method, params: params)
    return try await withThrowingTaskGroup(of: [String: Any].self) { group in
      group.addTask {
        try await withCheckedThrowingContinuation { continuation in
          Task { await self.register(id: id, continuation: continuation, payload: payload) }
        }
      }
      group.addTask { [timeoutSeconds] in
        try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
        throw FantasticalMCPError.timeout
      }
      guard let first = try await group.next() else { throw FantasticalMCPError.invalidResponse }
      group.cancelAll()
      return first
    }
  }

  private func register(
    id: Int, continuation: CheckedContinuation<[String: Any], Error>, payload: [String: Any]
  ) {
    pending[id] = continuation
    do {
      try send(payload)
    } catch {
      pending[id] = nil
      continuation.resume(throwing: error)
    }
  }

  private func send(_ payload: [String: Any]) throws {
    guard let input else { throw FantasticalMCPError.notRunning(detail: lastStderrLine) }
    var data = try JSONSerialization.data(withJSONObject: payload)
    data.append(0x0A)
    try input.write(contentsOf: data)
    Self.log.info("sent \(payload["method"] as? String ?? "?", privacy: .public) id \(payload["id"] as? Int ?? -1, privacy: .public)")
  }

  /// Splits the pipe into lines on Foundation's reader queue, never on the actor, so a
  /// waiting read can never stall the request that would produce the reply.
  nonisolated private static func readLines(from handle: FileHandle, _ onLine: @escaping @Sendable (String) -> Void) {
    let buffer = LineBuffer()
    handle.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        handle.readabilityHandler = nil
        return
      }
      for line in buffer.append(data) {
        onLine(line)
      }
    }
  }

  private func deliver(line: String) {
    Self.log.info("received \(line.count, privacy: .public) bytes")
    guard let data = line.data(using: .utf8),
      let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let id = message["id"] as? Int,
      let continuation = pending.removeValue(forKey: id)
    else { return }
    continuation.resume(returning: message)
  }
}

/// Accumulates pipe chunks and hands back complete lines.
final class LineBuffer: @unchecked Sendable {
  private var pending = Data()
  private let lock = NSLock()

  func append(_ data: Data) -> [String] {
    lock.lock()
    defer { lock.unlock() }
    pending.append(data)
    var lines: [String] = []
    while let newline = pending.firstIndex(of: 0x0A) {
      let chunk = pending.subdata(in: pending.startIndex..<newline)
      pending.removeSubrange(pending.startIndex...newline)
      if let line = String(data: chunk, encoding: .utf8) {
        lines.append(line)
      }
    }
    return lines
  }
}
