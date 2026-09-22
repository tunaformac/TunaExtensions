import Foundation

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
