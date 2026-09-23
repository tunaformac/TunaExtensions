import AppKit
import Foundation
import OSLog
import TunaKit

/// Talks JSON-RPC over stdio to Fantastical's bundled MCP helper. One process lives for the
/// session; Fantastical asks the user once to allow the host app.
actor FantasticalMCPClient {
  static let shared = FantasticalMCPClient()
  static let log = Logger(subsystem: "com.brnbw.tuna.plugins.fantastical", category: "mcp")

  private var process: Process?
  private var input: FileHandle?
  /// Kept until the helper they belong to has exited: a descriptor closed under a reader that is
  /// still scheduled is the one thing `FileHandle` cannot recover from.
  private var pipes: [Pipe] = []
  private var retiringPipes: [Pipe] = []
  private var readers: [Task<Void, Never>] = []
  private var startup: Task<Void, Error>?
  private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
  private var nextID = 1
  private var initialized = false
  /// Bumped on every teardown, so a termination callback from a helper we already replaced
  /// cannot clear the state of the one running now.
  private var generation = 0
  /// A helper on its way out. The helper serves one client at a time, so a replacement launched
  /// while this one is still winding down would fight it for Fantastical's connection.
  private var retiring: Process?
  private var lastStderrLine: String?
  private var chain: Task<Void, Never>?
  private let timeoutSeconds: UInt64 = 60
  static let stderrDetailLimit = 200
  static let toolMessageLimit = 400

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
      throw FantasticalMCPError.tool(
        text.isEmpty ? "Fantastical reported an error." : String(text.prefix(Self.toolMessageLimit)))
    }
    return FantasticalMCPResult(text: text, isError: false)
  }

  func shutdown() {
    generation += 1
    for reader in readers { reader.cancel() }
    readers = []
    if let process {
      process.terminationHandler = nil
      try? input?.close()
      process.terminate()
      retiring = process
      retiringPipes = pipes
    }
    pipes = []
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
    if let retiring {
      await Self.waitForExit(retiring)
      self.retiring = nil
      retiringPipes = []
    }
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
    Self.suppressSIGPIPE(on: stdin.fileHandleForWriting)
    Self.log.info("helper started pid \(process.processIdentifier, privacy: .public)")
    self.process = process
    self.input = stdin.fileHandleForWriting
    pipes = [stdin, stdout, stderr]
    readers = [
      Task { [weak self] in
        for await line in Self.lines(from: stdout.fileHandleForReading) { await self?.deliver(line: line) }
      },
      Task { [weak self] in
        for await line in Self.lines(from: stderr.fileHandleForReading) { await self?.remember(stderrLine: line) }
      },
    ]

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

  /// A write into a pipe whose reader has died raises SIGPIPE and takes the host down with it;
  /// with this flag on the descriptor the same write throws EPIPE and `send` reports it instead.
  nonisolated private static func suppressSIGPIPE(on handle: FileHandle) {
    _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
  }

  /// Bounded, because a helper that ignores SIGTERM must not wedge every later call: SIGKILL goes
  /// out after two seconds and the wait gives up after three.
  nonisolated private static func waitForExit(_ process: Process) async {
    await withCheckedContinuation { continuation in
      let resumed = LockedValue(false)
      let finish = {
        let first = resumed.withValue { done -> Bool in
          defer { done = true }
          return !done
        }
        if first { continuation.resume() }
      }
      DispatchQueue.global().async {
        process.waitUntilExit()
        finish()
      }
      DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
        if process.isRunning, process.processIdentifier > 0 { kill(process.processIdentifier, SIGKILL) }
      }
      DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: finish)
    }
  }

  private func handleTermination(generation: Int) {
    guard generation == self.generation else { return }
    if let lastStderrLine {
      Self.log.error("helper exited: \(lastStderrLine, privacy: .private)")
    } else {
      Self.log.error("helper exited with no stderr")
    }
    process = nil
    input = nil
    initialized = false
    failAllPending(with: FantasticalMCPError.notRunning(detail: lastStderrLine))
  }

  private func remember(stderrLine: String) {
    let trimmed = stderrLine.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let stripped = String(
      trimmed.replacingOccurrences(
        of: #"^\S+ \S+ \S+: \[FantasticalMCP\] "#, with: "", options: .regularExpression
      ).prefix(Self.stderrDetailLimit))
    Self.log.info("helper stderr: \(stripped, privacy: .private)")
    lastStderrLine = stripped
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
      try await Task.sleep(for: .seconds(timeoutSeconds))
      await self.expire(id: id)
    }
    defer { deadline.cancel() }
    return try await withCheckedThrowingContinuation { continuation in
      register(id: id, continuation: continuation, payload: payload)
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

  /// Splits the pipe into lines on Foundation's reader queue, never on the actor, and hands them
  /// over in arrival order. The throwing read is deliberate: `availableData` raises an
  /// uncatchable exception once the descriptor is closed under it.
  nonisolated private static func lines(from handle: FileHandle) -> AsyncStream<String> {
    AsyncStream { continuation in
      let buffer = LineBuffer()
      handle.readabilityHandler = { handle in
        guard let data = try? handle.read(upToCount: 65_536), !data.isEmpty else {
          handle.readabilityHandler = nil
          continuation.finish()
          return
        }
        for line in buffer.append(data) { continuation.yield(line) }
      }
      continuation.onTermination = { _ in handle.readabilityHandler = nil }
    }
  }

  private func deliver(line: String) {
    Self.log.info("received \(line.count, privacy: .public) bytes")
    guard let data = line.data(using: .utf8),
      let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let id = message["id"] as? Int,
      let continuation = pending.removeValue(forKey: id)
    else { return }
    lastStderrLine = nil
    continuation.resume(returning: message)
  }
}
