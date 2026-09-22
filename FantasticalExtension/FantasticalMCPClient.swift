import AppKit
import Foundation
import OSLog

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
  /// Bumped on every teardown, so a termination callback from a helper we already replaced
  /// cannot clear the state of the one running now.
  private var generation = 0
  private var lastStderrLine: String?
  private var chain: Task<Void, Never>?
  private let timeoutSeconds: UInt64 = 60
  static let stderrDetailLimit = 200

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

  /// The helper answers one request at a time; parallel calls make it drop its connection to
  /// Fantastical, so calls queue. Cancelling drops queued work; in-flight calls hit the deadline.
  func call(_ tool: String, arguments: [String: Any] = [:]) async throws -> FantasticalMCPResult {
    let prior = chain
    let task = Task<FantasticalMCPResult, Error> {
      await prior?.value
      try Task.checkCancellation()
      return try await self.performCall(tool, arguments: arguments)
    }
    chain = Task { _ = try? await task.value }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private func performCall(_ tool: String, arguments: [String: Any]) async throws -> FantasticalMCPResult {
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
    generation += 1
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
    let generation = self.generation
    process.terminationHandler = { [weak self] _ in
      Task { await self?.handleTermination(generation: generation) }
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

  private func handleTermination(generation: Int) {
    guard generation == self.generation else { return }
    Self.log.error("helper exited: \(self.lastStderrLine ?? "no stderr", privacy: .private)")
    process = nil
    input = nil
    initialized = false
    failAllPending(with: FantasticalMCPError.notRunning(detail: lastStderrLine))
  }

  private func remember(stderrLine: String) {
    let trimmed = stderrLine.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    Self.log.info("helper stderr: \(trimmed, privacy: .private)")
    let stripped = trimmed.replacingOccurrences(
      of: #"^\S+ \S+ \S+: \[FantasticalMCP\] "#, with: "", options: .regularExpression)
    lastStderrLine = String(stripped.prefix(Self.stderrDetailLimit))
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
    let deadline = Task { [timeoutSeconds] in
      try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
      await self.expire(id: id)
    }
    defer { deadline.cancel() }
    return try await withCheckedThrowingContinuation { continuation in
      Task { await self.register(id: id, continuation: continuation, payload: payload) }
    }
  }

  /// Frees a caller the helper never answered: `withCheckedThrowingContinuation` ignores
  /// cancellation, so the continuation is resumed here instead of raced against a sleep. The
  /// helper answers one request at a time, so a request it never answered leaves the pipe out of
  /// step; tearing it down here means the next call starts a fresh helper.
  private func expire(id: Int) {
    guard let continuation = pending.removeValue(forKey: id) else { return }
    Self.log.error("request \(id, privacy: .public) timed out")
    continuation.resume(throwing: FantasticalMCPError.timeout)
    shutdown()
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
