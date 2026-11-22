import Foundation
import TunaKit

/// The subset of `networkQuality -c` JSON the extension shows.
struct NetworkQualityResult: Decodable, Equatable, Sendable {
  let downloadBitsPerSecond: Double?
  let uploadBitsPerSecond: Double?
  let responsivenessRPM: Double?
  let idleLatencyMilliseconds: Double?
  let interfaceName: String?
  let testEndpoint: String?
  let errorCode: Int?
  let errorDomain: String?

  enum CodingKeys: String, CodingKey {
    case downloadBitsPerSecond = "dl_throughput"
    case uploadBitsPerSecond = "ul_throughput"
    case responsivenessRPM = "responsiveness"
    case idleLatencyMilliseconds = "base_rtt"
    case interfaceName = "interface_name"
    case testEndpoint = "test_endpoint"
    case errorCode = "error_code"
    case errorDomain = "error_domain"
  }

  var hasMeasurements: Bool {
    downloadBitsPerSecond != nil || uploadBitsPerSecond != nil || responsivenessRPM != nil
  }

  var summary: String {
    var parts: [String] = []
    if let value = downloadBitsPerSecond { parts.append("Download \(SpeedFormat.bandwidth(value))") }
    if let value = uploadBitsPerSecond { parts.append("Upload \(SpeedFormat.bandwidth(value))") }
    if let value = responsivenessRPM { parts.append("Responsiveness \(SpeedFormat.rpm(value))") }
    if let value = idleLatencyMilliseconds { parts.append("Idle latency \(SpeedFormat.milliseconds(value))") }
    return parts.joined(separator: " · ")
  }
}

enum SpeedFormat {
  static func bandwidth(_ bitsPerSecond: Double) -> String {
    let megabits = bitsPerSecond / 1_000_000
    if megabits >= 1_000 {
      return "\((megabits / 1_000).formatted(.number.precision(.fractionLength(2)))) Gbps"
    }
    let digits = megabits >= 100 ? 0 : 1
    return "\(megabits.formatted(.number.precision(.fractionLength(digits)))) Mbps"
  }

  static func rpm(_ value: Double) -> String {
    "\(Int(value.rounded())) RPM"
  }

  /// Round-trip time under load implied by RPM (round trips per minute).
  static func loadedLatency(rpm: Double) -> String? {
    guard rpm > 0 else { return nil }
    return milliseconds(60_000 / rpm)
  }

  static func milliseconds(_ value: Double) -> String {
    "\(Int(value.rounded())) ms"
  }
}

enum NetworkQualityError: LocalizedError, Equatable {
  case unavailable
  case failed(String)
  case invalidOutput

  var errorDescription: String? {
    switch self {
    case .unavailable: "networkQuality isn't available on this Mac."
    case .failed(let message): message.isEmpty ? "The speed test failed." : message
    case .invalidOutput: "networkQuality returned results Tuna could not read."
    }
  }
}

enum NetworkQuality {
  static let executablePath = "/usr/bin/networkQuality"
  /// `-c` prints JSON; `-M` caps the run so a stalled network can't hang the task.
  static let arguments = ["-c", "-M", "60"]

  typealias Runner = @Sendable (CLIProcessRequest) async throws -> CLIProcessResult
  nonisolated(unsafe) static var runOverride: Runner?

  static func run() async throws -> NetworkQualityResult {
    let request = CLIProcessRequest(
      executablePath: executablePath, arguments: arguments, timeout: 90)
    let result: CLIProcessResult
    if let runOverride {
      result = try await runOverride(request)
    } else {
      guard FileManager.default.isExecutableFile(atPath: executablePath) else {
        throw NetworkQualityError.unavailable
      }
      result = try await CLIProcessRunner.run(request)
    }
    return try parse(result)
  }

  static func parse(_ result: CLIProcessResult) throws -> NetworkQualityResult {
    let output = result.standardOutput
    guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"),
      let data = String(output[start...end]).data(using: .utf8)
    else {
      throw result.succeeded
        ? NetworkQualityError.invalidOutput
        : NetworkQualityError.failed(result.preferredErrorMessage)
    }
    guard let decoded = try? JSONDecoder().decode(NetworkQualityResult.self, from: data) else {
      throw NetworkQualityError.invalidOutput
    }
    if !decoded.hasMeasurements {
      let detail = decoded.errorCode.map { "Error \($0)" } ?? result.preferredErrorMessage
      throw NetworkQualityError.failed("The speed test did not finish. \(detail)")
    }
    return decoded
  }
}
