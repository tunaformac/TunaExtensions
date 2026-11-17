import AppKit
import Foundation

/// How a terminal app is told which folder to start in.
enum TerminalLaunchMethod: Sendable, Equatable {
  /// The app declares folders as a document type and opens a shell in the folder it is handed.
  case openFolder
  /// The app opens a URL built from this prefix and a percent-encoded folder path.
  case url(prefix: String)
  /// The app is launched as a new process with these arguments followed by the folder path.
  case arguments([String])
  /// Like `.arguments`, but first asks a running instance to open the window over its socket.
  case messageThenArguments(executable: String, message: [String], arguments: [String])
}

/// How a helper process ended.
enum ProcessOutcome: Equatable, Sendable {
  case exited(Int32)
  case failedToStart
  case timedOut
  case cancelled
}

/// The system calls a launch makes, so tests can replace them.
struct TerminalLauncher: Sendable {
  var run: @Sendable (_ executable: URL, _ arguments: [String], _ timeout: TimeInterval) async
    -> ProcessOutcome
  var open: @MainActor @Sendable (_ url: URL, _ applicationURL: URL) async throws -> Void
  var launchNewInstance: @MainActor @Sendable (_ applicationURL: URL, _ arguments: [String])
    async throws -> Void
  var activate: @MainActor @Sendable (_ bundleIdentifier: String) -> Void

  static let live = TerminalLauncher(
    run: { executable, arguments, timeout in
      await BoundedProcess.run(executable, arguments: arguments, timeout: timeout)
    },
    open: { url, applicationURL in
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = true
      _ = try await NSWorkspace.shared.open(
        [url], withApplicationAt: applicationURL, configuration: configuration)
    },
    launchNewInstance: { applicationURL, arguments in
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = true
      configuration.createsNewApplicationInstance = true
      configuration.arguments = arguments
      _ = try await NSWorkspace.shared.openApplication(
        at: applicationURL, configuration: configuration)
    },
    activate: { bundleIdentifier in
      NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        .first?.activate()
    }
  )
}

struct TerminalApp: Sendable {
  let id: String
  let name: String
  let bundleIdentifier: String
  let launchMethod: TerminalLaunchMethod
  /// Lowercased endings of folder names the app handles as files instead of opening as a folder.
  var rejectedNameEndings: [String] = []

  static let alacritty = TerminalApp(
    id: "alacritty",
    name: "Alacritty",
    bundleIdentifier: "org.alacritty",
    launchMethod: .messageThenArguments(
      executable: "alacritty",
      message: ["msg", "create-window", "--working-directory"],
      arguments: ["--working-directory"]
    )
  )
  static let ghostty = TerminalApp(
    id: "ghostty", name: "Ghostty", bundleIdentifier: "com.mitchellh.ghostty",
    launchMethod: .openFolder)
  // iTerm2's `application:openFile:` imports these as settings before it checks for a folder.
  static let iTerm2 = TerminalApp(
    id: "iterm2", name: "iTerm2", bundleIdentifier: "com.googlecode.iterm2",
    launchMethod: .openFolder,
    rejectedNameEndings: [
      ".its", ".itermtab", ".itr", ".iterm2arrangement", ".it2triggers", ".iterm2passwords",
      ".itermcolors",
    ])
  static let kitty = TerminalApp(
    id: "kitty", name: "kitty", bundleIdentifier: "net.kovidgoyal.kitty",
    launchMethod: .openFolder)
  static let terminal = TerminalApp(
    id: "terminal", name: "Terminal", bundleIdentifier: "com.apple.Terminal",
    launchMethod: .openFolder)
  static let warp = TerminalApp(
    id: "warp", name: "Warp", bundleIdentifier: "dev.warp.Warp-Stable",
    launchMethod: .url(prefix: "warp://action/new_window?path="))
  // `wezterm-gui start` hands the window to a running WezTerm unless the configs differ.
  // Opening a folder would instead type its path into a new shell.
  static let wezTerm = TerminalApp(
    id: "wezterm", name: "WezTerm", bundleIdentifier: "com.github.wez.wezterm",
    launchMethod: .arguments(["start", "--cwd"]))

  static let all = [alacritty, ghostty, iTerm2, kitty, terminal, warp, wezTerm]

  /// How long a running instance has to answer a window request.
  static let messageTimeout: TimeInterval = 5

  var applicationURL: URL? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
  }

  /// Why the app cannot open this folder, or nil when it can.
  func unsupportedMessage(for folder: URL) -> String? {
    let lowercased = folder.lastPathComponent.lowercased()
    guard rejectedNameEndings.contains(where: lowercased.hasSuffix) else { return nil }
    return "\(name) treats \"\(folder.lastPathComponent)\" as a file to import, so it cannot "
      + "open it as a folder. Choose another terminal in Open Terminal Here's settings."
  }

  /// Opens one window per folder. Returns an error message, or nil on success.
  @MainActor
  func open(
    _ folders: [URL], applicationURL: URL, launcher: TerminalLauncher = .live
  ) async -> String? {
    for folder in folders {
      if Task.isCancelled { return "The request was cancelled" }
      if let message = await open(folder, applicationURL: applicationURL, launcher: launcher) {
        return message
      }
    }
    return nil
  }

  @MainActor
  private func open(
    _ folder: URL, applicationURL: URL, launcher: TerminalLauncher
  ) async -> String? {
    switch launchMethod {
    case .openFolder:
      return await attempt { try await launcher.open(folder, applicationURL) }
    case .url(let prefix):
      guard let url = Self.url(prefix: prefix, folder: folder) else {
        return "Could not build a \(name) link for \(folder.path)"
      }
      return await attempt { try await launcher.open(url, applicationURL) }
    case .arguments(let arguments):
      return await attempt {
        try await launcher.launchNewInstance(applicationURL, arguments + [folder.path])
      }
    case .messageThenArguments(let executable, let message, let arguments):
      let executableURL = applicationURL.appendingPathComponent("Contents/MacOS/\(executable)")
      let outcome = await launcher.run(
        executableURL, message + [folder.path], Self.messageTimeout)
      switch outcome {
      case .exited(0):
        launcher.activate(bundleIdentifier)
        return nil
      case .timedOut:
        // The request may still be pending, so a second window could be a duplicate.
        return "\(name) did not answer within \(Int(Self.messageTimeout)) seconds. "
          + "No other window was opened."
      case .cancelled:
        return "The request was cancelled"
      case .exited, .failedToStart:
        return await attempt {
          try await launcher.launchNewInstance(applicationURL, arguments + [folder.path])
        }
      }
    }
  }

  @MainActor
  private func attempt(_ work: () async throws -> Void) async -> String? {
    do {
      try await work()
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  static func url(prefix: String, folder: URL) -> URL? {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&=+?#")
    guard let path = folder.path.addingPercentEncoding(withAllowedCharacters: allowed) else {
      return nil
    }
    return URL(string: prefix + path)
  }
}

/// Runs a helper process with a deadline. The process is terminated, and the result delivered
/// exactly once, when it exits, times out, or the calling task is cancelled.
final class BoundedProcess: @unchecked Sendable {
  private let lock = NSLock()
  private let process = Process()
  private var continuation: CheckedContinuation<ProcessOutcome, Never>?
  private var outcome: ProcessOutcome?

  static func run(
    _ executableURL: URL, arguments: [String], timeout: TimeInterval
  ) async -> ProcessOutcome {
    let bounded = BoundedProcess()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        bounded.start(executableURL, arguments: arguments, timeout: timeout, continuation)
      }
    } onCancel: {
      bounded.finish(.cancelled)
    }
  }

  private func start(
    _ executableURL: URL, arguments: [String], timeout: TimeInterval,
    _ continuation: CheckedContinuation<ProcessOutcome, Never>
  ) {
    lock.lock()
    if let outcome {
      lock.unlock()
      continuation.resume(returning: outcome)
      return
    }
    self.continuation = continuation
    lock.unlock()

    process.executableURL = executableURL
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.terminationHandler = { [self] process in
      finish(.exited(process.terminationStatus))
    }
    do {
      try process.run()
    } catch {
      finish(.failedToStart)
      return
    }
    // A cancellation or timeout that arrived before the process was running could not stop it.
    lock.lock()
    let alreadyFinished = outcome != nil
    lock.unlock()
    if alreadyFinished {
      terminate()
      return
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
      finish(.timedOut)
    }
  }

  private func terminate() {
    guard process.isRunning else { return }
    process.terminate()
    let identifier = process.processIdentifier
    DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
      if process.isRunning { kill(identifier, SIGKILL) }
    }
  }

  func finish(_ result: ProcessOutcome) {
    lock.lock()
    guard outcome == nil else {
      lock.unlock()
      return
    }
    outcome = result
    let continuation = continuation
    self.continuation = nil
    lock.unlock()

    if case .exited = result {
      // The process is already gone.
    } else {
      terminate()
    }
    continuation?.resume(returning: result)
  }
}
