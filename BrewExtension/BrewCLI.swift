import Foundation
import TunaKit

enum BrewDataError: LocalizedError, Sendable {
  case brewNotFound
  case invalidCustomBrewPath(String)
  case commandFailed(command: String, message: String)
  case invalidJSON(command: String)

  var errorDescription: String? {
    switch self {
    case .brewNotFound:
      return "Homebrew is not installed. Install Homebrew from brew.sh or set a custom path."
    case .invalidCustomBrewPath(let path):
      return "Custom brew path is invalid: \(path)"
    case .commandFailed(let command, let message):
      return "Homebrew command failed (\(command)): \(message)"
    case .invalidJSON(let command):
      return "Homebrew returned invalid JSON for \(command)."
    }
  }
}

actor BrewDataStore {
  static let shared = BrewDataStore()

  private var packageStatus: BrewPackageStatus?

  /// Chain of currently in-flight mutating `runCommand` calls (install/uninstall/upgrade/
  /// update/cleanup). Reads (`search`, `installed`, `outdated`) are intentionally NOT gated on
  /// this — they're safe to interleave with a running command since `status(customBrewPath:)`
  /// just shells out to `brew` again and refreshes the cache. Only mutating commands must never
  /// run concurrently with one another.
  private var inFlightCommand: Task<Void, Never>?

  func search(query: String, customBrewPath: String?) async throws -> [BrewPackageRecord] {
    let normalizedPath = BrewCLI.normalizedCustomPath(customBrewPath)
    let currentStatus = try await status(customBrewPath: normalizedPath)
    return try await BrewCLI.search(
      query: query,
      customBrewPath: normalizedPath,
      status: currentStatus
    )
  }

  func installed(customBrewPath: String?) async throws -> [BrewPackageRecord] {
    try await status(customBrewPath: BrewCLI.normalizedCustomPath(customBrewPath)).installed
      .sortedByName()
  }

  func outdated(customBrewPath: String?) async throws -> [BrewPackageRecord] {
    try await status(customBrewPath: BrewCLI.normalizedCustomPath(customBrewPath)).outdated
      .sortedByName()
  }

  func runCommand(arguments: [String], customBrewPath: String?) async throws -> BrewProcessOutput {
    // Chain onto whatever command is already in flight so mutating brew invocations always run
    // one at a time, even though this method suspends (see BrewCLI.execute/runProcess) and lets
    // other actor calls interleave while it awaits. Reading `previous` and publishing the new
    // `inFlightCommand` happens here with no `await` in between, so this block is a single,
    // non-interleavable actor turn — no other `runCommand` call can slip in and race it.
    let previous = inFlightCommand
    let normalizedPath = BrewCLI.normalizedCustomPath(customBrewPath)

    let commandTask = Task<BrewProcessOutput, Error> {
      await previous?.value
      return try await BrewCLI.execute(arguments: arguments, customBrewPath: normalizedPath)
    }
    inFlightCommand = Task { _ = try? await commandTask.value }

    let output = try await commandTask.value
    packageStatus = nil
    return output
  }

  private func status(customBrewPath: String?) async throws -> BrewPackageStatus {
    if let packageStatus, packageStatus.customBrewPath == customBrewPath {
      return packageStatus
    }

    let status = try await BrewCLI.status(customBrewPath: customBrewPath)
    packageStatus = status
    return status
  }
}

enum BrewCLI {
  private static let commandTimeout: TimeInterval = 600

  static func normalizedCustomPath(_ customPath: String?) -> String? {
    guard let customPath = customPath?.trimmingCharacters(in: .whitespacesAndNewlines),
      !customPath.isEmpty
    else {
      return nil
    }
    return customPath
  }

  static func search(query: String, customBrewPath: String?, status: BrewPackageStatus)
    async throws -> [BrewPackageRecord]
  {
    let executablePath = try await resolveExecutable(customBrewPath: customBrewPath)
    let formulae = try await execute(
      executablePath: executablePath,
      arguments: ["search", "--formula", query],
      commandName: "brew search --formula \(query)"
    )
    let casks = try await execute(
      executablePath: executablePath,
      arguments: ["search", "--cask", query],
      commandName: "brew search --cask \(query)"
    )

    let records =
      parseNameLines(formulae.stdout).map { status.record(name: $0, kind: .formula) }
      + parseNameLines(casks.stdout).map { status.record(name: $0, kind: .cask) }
    return records.sortedByName()
  }

  static func status(customBrewPath: String?) async throws -> BrewPackageStatus {
    let executablePath = try await resolveExecutable(customBrewPath: customBrewPath)
    return BrewPackageStatus(
      customBrewPath: customBrewPath,
      installed: try await installed(executablePath: executablePath),
      outdated: try await outdated(executablePath: executablePath)
    )
  }

  private static func installed(executablePath: String) async throws -> [BrewPackageRecord] {
    let formulae = try await execute(
      executablePath: executablePath,
      arguments: ["list", "--formula", "--versions"],
      commandName: "brew list --formula --versions"
    )
    let casks = try await execute(
      executablePath: executablePath,
      arguments: ["list", "--cask", "--versions"],
      commandName: "brew list --cask --versions"
    )

    return
      (parseVersionLines(formulae.stdout).map {
        record(name: $0.name, kind: .formula, installedVersion: $0.version)
      }
      + parseVersionLines(casks.stdout).map {
        record(name: $0.name, kind: .cask, installedVersion: $0.version)
      })
      .sortedByName()
  }

  private static func outdated(executablePath: String) async throws -> [BrewPackageRecord] {
    let output = try await execute(
      executablePath: executablePath,
      arguments: ["outdated", "--json=v2"],
      commandName: "brew outdated --json=v2"
    )

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    guard
      let payload = try? decoder.decode(BrewOutdatedPayload.self, from: Data(output.stdout.utf8))
    else {
      throw BrewDataError.invalidJSON(command: "brew outdated --json=v2")
    }

    return
      (payload.formulae.map {
        record(
          name: $0.name,
          kind: .formula,
          installedVersion: firstNonEmpty($0.installedVersions ?? []),
          latestVersion: $0.currentVersion,
          isOutdated: true
        )
      }
      + payload.casks.map {
        record(
          name: $0.name,
          kind: .cask,
          installedVersion: firstNonEmpty($0.installedVersions?.values ?? []),
          latestVersion: $0.currentVersion,
          isOutdated: true
        )
      }).sortedByName()
  }

  static func execute(arguments: [String], customBrewPath: String?) async throws
    -> BrewProcessOutput
  {
    let executablePath = try await resolveExecutable(customBrewPath: customBrewPath)
    return try await execute(
      executablePath: executablePath,
      arguments: arguments,
      commandName: "brew \(arguments.joined(separator: " "))"
    )
  }

  private static func record(
    name: String,
    kind: BrewPackageKind,
    installedVersion: String? = nil,
    latestVersion: String? = nil,
    isOutdated: Bool = false
  ) -> BrewPackageRecord {
    BrewPackageRecord(
      name: name,
      kind: kind,
      installedVersion: installedVersion,
      latestVersion: latestVersion,
      isOutdated: isOutdated
    )
  }

  private static func parseNameLines(_ output: String) -> [String] {
    output.split(whereSeparator: \.isNewline).map(String.init)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && !$0.hasPrefix("==>") }
  }

  private static func parseVersionLines(_ output: String) -> [(name: String, version: String?)] {
    output.split(whereSeparator: \.isNewline).compactMap { line in
      let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
      guard let name = parts.first else { return nil }
      return (name, parts.dropFirst().first)
    }
  }

  private static func firstNonEmpty(_ values: [String]) -> String? {
    values.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }

  private static func execute(
    executablePath: String,
    arguments: [String],
    commandName: String
  ) async throws -> BrewProcessOutput {
    let result = try await runProcess(executable: executablePath, arguments: arguments)
    guard result.status == 0 else {
      throw BrewDataError.commandFailed(
        command: commandName,
        message: preferredErrorMessage(stdout: result.stdout, stderr: result.stderr)
      )
    }
    return result
  }

  private static func resolveExecutable(customBrewPath: String?) async throws -> String {
    if let customBrewPath {
      guard FileManager.default.isExecutableFile(atPath: customBrewPath) else {
        throw BrewDataError.invalidCustomBrewPath(customBrewPath)
      }
      return customBrewPath
    }

    let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    if let match = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) {
      return match
    }

    if let whichResult = try? await runProcess(executable: "/usr/bin/which", arguments: ["brew"]),
      whichResult.status == 0
    {
      let resolved = whichResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      if !resolved.isEmpty, FileManager.default.isExecutableFile(atPath: resolved) {
        return resolved
      }
    }

    throw BrewDataError.brewNotFound
  }

  private static func runProcess(executable: String, arguments: [String]) async throws
    -> BrewProcessOutput
  {
    var environment = ProcessInfo.processInfo.environment
    environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
    let command = ([executable] + arguments).joined(separator: " ")
    let request = CLIProcessRequest(
      executablePath: executable,
      arguments: arguments,
      environment: environment,
      timeout: commandTimeout
    )

    do {
      // Run the (potentially minutes-long, e.g. `brew upgrade`) subprocess on a detached task so
      // this call only *suspends* its caller instead of blocking whatever executor invoked it.
      // In particular, BrewDataStore is an actor — if this ran synchronously inside an actor
      // method, the actor's executor (and a cooperative-pool thread) would be pinned for the
      // whole subprocess duration, freezing every other Brew feature (e.g. debounced search)
      // that awaits the actor. Task.detached fully severs actor inheritance, guaranteeing the
      // blocking work happens off the actor regardless of the caller's isolation.
      let result = try await Task.detached(priority: .utility) {
        try CLIProcessRunner.runSync(request)
      }.value
      return BrewProcessOutput(
        stdout: result.standardOutput, stderr: result.standardError, status: result.exitCode)
    } catch {
      throw BrewDataError.commandFailed(command: command, message: error.localizedDescription)
    }
  }

  private static func preferredErrorMessage(stdout: String, stderr: String) -> String {
    let preferred = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    if !preferred.isEmpty { return preferred }
    let fallback = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    if !fallback.isEmpty { return fallback }
    return "Unknown error"
  }
}

struct BrewProcessOutput: Sendable {
  let stdout: String
  let stderr: String
  let status: Int32
}

struct BrewPackageStatus: Sendable {
  let customBrewPath: String?
  let installed: [BrewPackageRecord]
  let outdated: [BrewPackageRecord]

  private var installedByKey: [BrewPackageKey: BrewPackageRecord] { installed.byPackageKey() }
  private var outdatedByKey: [BrewPackageKey: BrewPackageRecord] { outdated.byPackageKey() }

  func record(name: String, kind: BrewPackageKind) -> BrewPackageRecord {
    let key = BrewPackageKey(name: name, kind: kind)
    return outdatedByKey[key] ?? installedByKey[key] ?? BrewPackageRecord(name: name, kind: kind)
  }
}

private struct BrewPackageKey: Hashable, Sendable {
  let name: String
  let kind: BrewPackageKind
}

extension Array where Element == BrewPackageRecord {
  func sortedByName() -> [BrewPackageRecord] {
    sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  fileprivate func byPackageKey() -> [BrewPackageKey: BrewPackageRecord] {
    Dictionary(uniqueKeysWithValues: map { (BrewPackageKey(name: $0.name, kind: $0.kind), $0) })
  }
}

private struct BrewOutdatedPayload: Decodable {
  let formulae: [BrewOutdatedFormula]
  let casks: [BrewOutdatedCask]
}

private struct BrewOutdatedFormula: Decodable {
  let name: String
  let currentVersion: String?
  let installedVersions: [String]?
}

private struct BrewOutdatedCask: Decodable {
  let name: String
  let currentVersion: String?
  let installedVersions: StringListOrValue?
}

private enum StringListOrValue: Decodable {
  case single(String)
  case list([String])

  var values: [String] {
    switch self {
    case .single(let value): [value]
    case .list(let values): values
    }
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let stringValue = try? container.decode(String.self) {
      self = .single(stringValue)
    } else if let listValue = try? container.decode([String].self) {
      self = .list(listValue)
    } else {
      throw DecodingError.typeMismatch(
        StringListOrValue.self,
        DecodingError.Context(
          codingPath: decoder.codingPath, debugDescription: "Expected string or [string]")
      )
    }
  }
}
