import Darwin
import Foundation
import Security

struct StrongboxInstallation: Sendable {
  private static let teamIdentifier = "4326J8XDF2"
  /// The helper's own designated requirement. Its App Store branch can't name the team, because
  /// App Store signing certificates don't carry one, so `mcpHelper()` also checks the signed Team ID.
  private static let requirement = """
    anchor apple generic and identifier "com.markmcguill.strongbox.mcp" and \
    (certificate leaf[field.1.2.840.113635.100.6.1.9] exists or \
    certificate 1[field.1.2.840.113635.100.6.2.6] exists and \
    certificate leaf[field.1.2.840.113635.100.6.1.13] exists and \
    certificate leaf[subject.OU] = "\(teamIdentifier)")
    """

  var applicationURL = URL(fileURLWithPath: "/Applications/Strongbox.app")

  func mcpHelper() throws -> URL {
    let url = applicationURL.appendingPathComponent("Contents/MacOS/strongbox-mcp")
    guard FileManager.default.isExecutableFile(atPath: url.path) else { throw StrongboxError.unavailable }
    var code: SecStaticCode?
    var requirement: SecRequirement?
    var information: CFDictionary?
    let validation = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
       SecRequirementCreateWithString(Self.requirement as CFString, [], &requirement) == errSecSuccess,
       let code, let requirement,
       SecStaticCodeCheckValidity(code, validation, requirement) == errSecSuccess,
       SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
       let metadata = information as? [String: Any],
       metadata[kSecCodeInfoTeamIdentifier as String] as? String == Self.teamIdentifier else {
      throw StrongboxError.untrustedHelper
    }
    return url
  }
}

final class HelperProcess {
  let process = Process()
  private let input = Pipe()
  private let output = Pipe()
  private var buffer = Data()
  private let responseLimit = 8 * 1024 * 1024

  init(executable: URL) throws {
    process.executableURL = executable
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do { try process.run() }
    catch { throw StrongboxError.unavailable }
    guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
      process.terminate()
      throw StrongboxError.unavailable
    }
  }

  deinit {
    if process.isRunning {
      process.terminate()
      let child = process
      DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
        if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
      }
    }
    try? input.fileHandleForWriting.close()
    try? output.fileHandleForReading.close()
  }

  func write(_ data: Data) throws {
    guard process.isRunning else { throw StrongboxError.unavailable }
    do { try input.fileHandleForWriting.write(contentsOf: data) }
    catch { throw StrongboxError.unavailable }
  }

  func readLine(deadline: Date) throws -> Data {
    // Only new bytes are searched, so a long line costs linear time.
    var searched = buffer.startIndex
    while true {
      if let newline = buffer[searched...].firstIndex(of: 10) {
        let line = Data(buffer[..<newline])
        buffer = Data(buffer[buffer.index(after: newline)...])
        return line
      }
      searched = buffer.endIndex
      try readMore(deadline: deadline)
    }
  }

  private func readMore(deadline: Date) throws {
    while true {
      let remaining = deadline.timeIntervalSinceNow
      guard remaining > 0 else { throw StrongboxError.timedOut }
      var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
      let ready = Darwin.poll(&descriptor, 1, Int32(min(remaining * 1000, 90_000)))
      if ready < 0 && errno == EINTR { continue }
      guard ready > 0 else { throw ready == 0 ? StrongboxError.timedOut : StrongboxError.unavailable }
      var bytes = [UInt8](repeating: 0, count: 32_768)
      let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
      if count < 0 && errno == EINTR { continue }
      guard count > 0 else { throw StrongboxError.disconnected }
      guard buffer.count + count <= responseLimit else { throw StrongboxError.invalidResponse }
      buffer.append(contentsOf: bytes.prefix(count))
      return
    }
  }
}

enum StrongboxTool: String {
  case list = "list_databases", unlock = "unlock_database"
  case search = "find_credentials", reveal = "reveal_credential"
}

final class MCPConnection {
  static let protocolVersion = "2025-06-18"
  private static let extensionVersion =
    Bundle(for: MCPConnection.self).object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
  private let helper: HelperProcess
  private var sequence = 0

  convenience init(installation: StrongboxInstallation) throws {
    try self.init(helper: HelperProcess(executable: installation.mcpHelper()))
  }

  /// Only tests pass an unverified helper. The extension always goes through `init(installation:)`.
  init(helper: HelperProcess) throws {
    self.helper = helper
    let result = try request("initialize", parameters: .object([
      "protocolVersion": .string(Self.protocolVersion),
      "capabilities": .object([:]),
      "clientInfo": .object([
        "name": .string("Tuna"), "version": .string(Self.extensionVersion),
      ]),
    ]), timeout: 10)
    // A server answers with another version only when it doesn't support this one.
    guard result["protocolVersion"]?.string == Self.protocolVersion else { throw StrongboxError.invalidResponse }
    try send(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]))
  }

  func tool(_ tool: StrongboxTool, arguments: [String: JSONValue]) throws -> JSONValue {
    let result = try request("tools/call", parameters: .object([
      "name": .string(tool.rawValue), "arguments": .object(arguments),
    ]), timeout: tool == .unlock || tool == .reveal ? 90 : 15)
    if result["isError"]?.boolean == true {
      let text = result["content"]?.array?.compactMap { $0["text"]?.string }.joined(separator: " ") ?? ""
      if text.contains("This MCP host is not paired") { throw StrongboxError.notPaired }
      if text.contains("Strongbox MCP access is disabled") { throw StrongboxError.disabled }
      if text.contains("database is locked") || text.contains("Call unlock_database") { throw StrongboxError.locked }
      throw StrongboxError.denied
    }
    if let value = result["structuredContent"] { return value }
    for content in result["content"]?.array ?? [] {
      if content["type"]?.string == "text", let text = content["text"]?.string,
       let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) {
        return value
      }
    }
    throw StrongboxError.invalidResponse
  }

  private func send(_ value: JSONValue) throws {
    var data = try JSONEncoder().encode(value)
    data.append(10)
    try helper.write(data)
  }

  private func request(_ method: String, parameters: JSONValue, timeout: TimeInterval) throws -> JSONValue {
    sequence += 1
    try send(.object([
      "jsonrpc": .string("2.0"), "id": .number(Double(sequence)),
      "method": .string(method), "params": parameters,
    ]))
    let deadline = Date().addingTimeInterval(timeout)
    while true {
      let line = try helper.readLine(deadline: deadline)
      guard !line.isEmpty else { continue }
      guard let message = try? JSONDecoder().decode(JSONValue.self, from: line) else {
        throw StrongboxError.invalidResponse
      }
      if message["method"] != nil {
        if let identifier = message["id"] {
          try send(.object([
            "jsonrpc": .string("2.0"), "id": identifier,
            "error": .object(["code": .number(-32601), "message": .string("Unsupported request")]),
          ]))
        }
        continue
      }
      guard message["id"]?.number == Double(sequence) else { continue }
      guard message["error"] == nil, let result = message["result"] else {
        throw StrongboxError.invalidResponse
      }
      return result
    }
  }
}
