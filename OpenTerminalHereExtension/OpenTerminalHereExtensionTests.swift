import Foundation
import TunaKit
import XCTest

@testable import OpenTerminalHereExtension

final class OpenTerminalHereExtensionTests: XCTestCase {
  private var directory: URL!
  private var file: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .standardizedFileURL
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    file = directory.appendingPathComponent("notes.txt")
    try Data().write(to: file)
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: directory)
  }

  // MARK: Subjects

  @MainActor
  func testFolderOpensItselfAndFileOpensItsEnclosingFolder() {
    XCTAssertEqual(folder(ofText: directory.path), directory)
    XCTAssertEqual(folder(ofText: file.path), directory)
    XCTAssertEqual(folder(ofText: file.absoluteString), directory)
    XCTAssertEqual(folder(ofText: "  \(file.path)\n"), directory)
  }

  @MainActor
  func testFileAndFolderEntitiesAreSupportedSubjects() throws {
    let action = try makeAction()
    let predicate = try XCTUnwrap(action.subjectPredicate)
    let fileEntity = FileSystemEntity(displayName: "notes.txt", url: file, kind: .file)
    let folderEntity = FileSystemEntity(displayName: "folder", url: directory, kind: .directory)

    for (entity, expected) in [(fileEntity, directory), (folderEntity, directory)] {
      XCTAssertTrue(action.supportsSubject(type: entity.typeID), "\(entity.typeID)")
      XCTAssertTrue(predicate(entity), "\(entity.typeID)")
      XCTAssertEqual(OpenTerminalHereActionsCatalog.folder(for: entity), expected)
    }
  }

  @MainActor
  func testTildePathExpandsToHome() {
    let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL
    XCTAssertEqual(folder(ofText: "~"), home)
  }

  @MainActor
  func testTextThatIsNotAnExistingPathHasNoFolder() {
    XCTAssertNil(folder(ofText: ""))
    XCTAssertNil(folder(ofText: "hello world"))
    XCTAssertNil(folder(ofText: "relative/path"))
    XCTAssertNil(folder(ofText: directory.appendingPathComponent("missing").path))
  }

  @MainActor
  func testExactPathWinsOverTheTrimmedPath() throws {
    let plain = directory.appendingPathComponent("folder", isDirectory: true)
    let padded = directory.appendingPathComponent("folder ", isDirectory: true)
    try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: padded, withIntermediateDirectories: false)

    XCTAssertEqual(folder(ofText: plain.path), plain)
    XCTAssertEqual(folder(ofText: padded.path), padded)
    XCTAssertEqual(folder(ofText: "\(plain.path)\n"), plain)
  }

  @MainActor
  func testOnlyTheWhitespaceSuffixedNameExists() throws {
    let padded = directory.appendingPathComponent("folder ", isDirectory: true)
    try FileManager.default.createDirectory(at: padded, withIntermediateDirectories: false)

    XCTAssertEqual(folder(ofText: padded.path), padded)
    XCTAssertNil(folder(ofText: directory.appendingPathComponent("folder").path))
    XCTAssertNil(folder(ofText: directory.appendingPathComponent("folder").path + "\n"))
  }

  // MARK: Action

  @MainActor
  func testOneActionCoversFilesFoldersAndText() throws {
    let catalog = makeCatalog()

    XCTAssertEqual(catalog.actions.map(\.id), ["open-terminal-here"])
    XCTAssertEqual(catalog.actions.map(\.title), ["Open Terminal Here"])
    let action = try makeAction()
    XCTAssertEqual(action.supportedSubjectTypes, [.file, .directory, .textSnippet])
    XCTAssertNotNil(action.batchCallback)
    XCTAssertEqual(action.headlessEligibility, .guaranteed)
  }

  @MainActor
  func testActionAcceptsPathsOnly() throws {
    let predicate = try XCTUnwrap(try makeAction().subjectPredicate)

    XCTAssertTrue(predicate(TextSnippetItem(text: file.path)))
    XCTAssertFalse(predicate(TextSnippetItem(text: "hello world")))
    XCTAssertFalse(predicate(nil))
  }

  func testTerminalSettingListsEveryAppAndDefaultsToTerminal() throws {
    let setting = OpenTerminalHereSettings.terminal

    XCTAssertEqual(setting.key, "Terminal")
    XCTAssertEqual(setting.defaultValue, "terminal")
    XCTAssertEqual(
      setting.options.map(\.label),
      ["Alacritty", "Ghostty", "iTerm2", "kitty", "Terminal", "Warp", "WezTerm"])
    XCTAssertEqual(Set(setting.options.map(\.value)).count, TerminalApp.all.count)
    XCTAssertTrue(setting.options.map(\.value).contains(setting.defaultValue))
  }

  func testBundleIdentifiersAndLaunchMethods() {
    let byName = Dictionary(uniqueKeysWithValues: TerminalApp.all.map { ($0.name, $0) })

    XCTAssertEqual(byName["Alacritty"]?.bundleIdentifier, "org.alacritty")
    XCTAssertEqual(byName["Ghostty"]?.bundleIdentifier, "com.mitchellh.ghostty")
    XCTAssertEqual(byName["iTerm2"]?.bundleIdentifier, "com.googlecode.iterm2")
    XCTAssertEqual(byName["kitty"]?.bundleIdentifier, "net.kovidgoyal.kitty")
    XCTAssertEqual(byName["Terminal"]?.bundleIdentifier, "com.apple.Terminal")
    XCTAssertEqual(byName["Warp"]?.bundleIdentifier, "dev.warp.Warp-Stable")
    XCTAssertEqual(byName["WezTerm"]?.bundleIdentifier, "com.github.wez.wezterm")

    for name in ["Ghostty", "iTerm2", "kitty", "Terminal"] {
      XCTAssertEqual(byName[name]?.launchMethod, .openFolder, name)
    }
    XCTAssertEqual(byName["WezTerm"]?.launchMethod, .arguments(["start", "--cwd"]))
    XCTAssertEqual(
      byName["Alacritty"]?.launchMethod,
      .messageThenArguments(
        executable: "alacritty",
        message: ["msg", "create-window", "--working-directory"],
        arguments: ["--working-directory"]))
  }

  func testWarpLinkPercentEncodesThePath() throws {
    let folder = URL(fileURLWithPath: "/Users/me/A & B/c=d+e?#", isDirectory: true)
    let url = try XCTUnwrap(
      TerminalApp.url(prefix: "warp://action/new_window?path=", folder: folder))

    XCTAssertEqual(
      url.absoluteString, "warp://action/new_window?path=/Users/me/A%20%26%20B/c%3Dd%2Be%3F%23")
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    XCTAssertEqual(components.queryItems?.first?.value, folder.path)
  }

  @MainActor
  func testExtensionDeclarationIsValid() throws {
    let extensionInstance = try OpenTerminalHereExtension(
      bundle: Bundle(for: OpenTerminalHereExtension.self))
    let declaration = try XCTUnwrap(extensionInstance.declaration)

    try declaration.validate()
    XCTAssertEqual(declaration.settings.map(\.key), ["Terminal"])
    let compatibility = try XCTUnwrap(declaration.compatibility)
    XCTAssertEqual(compatibility.minTuna, "0.108")
    XCTAssertEqual(compatibility.minTunaKit, "1.22.0")
  }

  // MARK: Launching with a fake launcher

  @MainActor
  func testUnknownTerminalFailsWithoutLaunching() async {
    let recorder = Recorder()
    let result = await OpenTerminalHereActionsCatalog.open(
      [TextSnippetItem(text: directory.path)], terminalID: "hyper",
      launcher: recorder.launcher())

    XCTAssertEqual(failure(result)?.contains("not a supported terminal"), true)
    XCTAssertEqual(failure(result)?.contains("settings"), true)
    XCTAssertEqual(recorder.calls, [])
  }

  @MainActor
  func testUninstalledTerminalFailsWithoutOpeningAnotherApp() async {
    let missing = TerminalApp(
      id: "missing", name: "Missing", bundleIdentifier: "invalid.example.not-installed",
      launchMethod: .openFolder)
    let recorder = Recorder()
    let result = await OpenTerminalHereActionsCatalog.open(
      [TextSnippetItem(text: directory.path)], in: missing, launcher: recorder.launcher())

    XCTAssertEqual(failure(result)?.contains("Missing is not installed"), true)
    XCTAssertEqual(failure(result)?.contains("settings"), true)
    XCTAssertEqual(recorder.calls, [])
  }

  @MainActor
  func testTextThatIsNotAPathFails() async {
    let recorder = Recorder()
    let result = await OpenTerminalHereActionsCatalog.open(
      [TextSnippetItem(text: "hello world")], in: .terminal, launcher: recorder.launcher())

    XCTAssertNotNil(failure(result))
    XCTAssertEqual(recorder.calls, [])
  }

  @MainActor
  func testEachDistinctFolderGetsOneOpenRequest() async throws {
    let other = directory.appendingPathComponent("other", isDirectory: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
    let recorder = Recorder()
    let result = await OpenTerminalHereActionsCatalog.open(
      [
        TextSnippetItem(text: file.path), TextSnippetItem(text: directory.path),
        TextSnippetItem(text: other.path),
      ], in: .terminal, launcher: recorder.launcher())

    XCTAssertTrue(isSuccess(result))
    XCTAssertEqual(recorder.calls, ["open:\(directory.path)", "open:\(other.path)"])
  }

  @MainActor
  func testWarpGetsOneLinkPerFolder() async {
    let recorder = Recorder()
    let result = await OpenTerminalHereActionsCatalog.open(
      [TextSnippetItem(text: directory.path)], in: TerminalApp.warp.withInstalledBundle(),
      launcher: recorder.launcher())

    XCTAssertTrue(isSuccess(result))
    XCTAssertEqual(
      recorder.calls, ["open:warp://action/new_window?path=\(directory.path)"])
  }

  @MainActor
  func testOpenFailureIsReported() async {
    let recorder = Recorder(openError: "Launch Services refused")
    let result = await OpenTerminalHereActionsCatalog.open(
      [TextSnippetItem(text: directory.path)], in: .terminal, launcher: recorder.launcher())

    XCTAssertEqual(failure(result)?.contains("Terminal could not open the folder"), true)
    XCTAssertEqual(failure(result)?.contains("Launch Services refused"), true)
  }

  @MainActor
  func testWezTermLaunchesANewInstanceWithTheFolder() async {
    let recorder = Recorder()
    let result = await OpenTerminalHereActionsCatalog.open(
      [TextSnippetItem(text: directory.path)], in: TerminalApp.wezTerm.withInstalledBundle(),
      launcher: recorder.launcher())

    XCTAssertTrue(isSuccess(result))
    XCTAssertEqual(recorder.calls, ["launch:start --cwd \(directory.path)"])
  }

  @MainActor
  func testLaunchFailureIsReported() async {
    let recorder = Recorder(launchError: "no such app")
    let result = await OpenTerminalHereActionsCatalog.open(
      [TextSnippetItem(text: directory.path)], in: TerminalApp.wezTerm.withInstalledBundle(),
      launcher: recorder.launcher())

    XCTAssertEqual(failure(result)?.contains("WezTerm could not open the folder"), true)
  }

  @MainActor
  func testITerm2RejectsFoldersItWouldImport() async throws {
    let importable = directory.appendingPathComponent("project.its", isDirectory: true)
    try FileManager.default.createDirectory(at: importable, withIntermediateDirectories: false)
    let iTerm2 = TerminalApp.iTerm2.withInstalledBundle()
    let recorder = Recorder()

    let rejected = await OpenTerminalHereActionsCatalog.open(
      [TextSnippetItem(text: importable.path), TextSnippetItem(text: directory.path)], in: iTerm2,
      launcher: recorder.launcher())
    XCTAssertEqual(failure(rejected)?.contains("project.its"), true)
    XCTAssertEqual(failure(rejected)?.contains("settings"), true)
    XCTAssertEqual(recorder.calls, [])

    let accepted = await OpenTerminalHereActionsCatalog.open(
      [TextSnippetItem(text: directory.path)], in: iTerm2, launcher: recorder.launcher())
    XCTAssertTrue(isSuccess(accepted))

    let terminal = await OpenTerminalHereActionsCatalog.open(
      [TextSnippetItem(text: importable.path)], in: .terminal, launcher: recorder.launcher())
    XCTAssertTrue(isSuccess(terminal))
  }

  func testITerm2ReservedEndingsMatchTheImporters() {
    for name in [
      "a.its", "a.itermtab", "a.itr", "a.iterm2arrangement", "a.it2triggers",
      "a.iterm2passwords", "a.itermcolors", "A.ITS",
    ] {
      XCTAssertNotNil(
        TerminalApp.iTerm2.unsupportedMessage(for: URL(fileURLWithPath: "/tmp/\(name)")), name)
    }
    for name in ["project", "its", "a.itsx", "itr.d"] {
      XCTAssertNil(
        TerminalApp.iTerm2.unsupportedMessage(for: URL(fileURLWithPath: "/tmp/\(name)")), name)
    }
  }

  // MARK: Alacritty's window request

  @MainActor
  func testAlacrittyReusesARunningInstance() async {
    let recorder = Recorder(outcome: .exited(0))
    let result = await OpenTerminalHereActionsCatalog.open(
      [TextSnippetItem(text: directory.path)], in: alacritty(), launcher: recorder.launcher())

    XCTAssertTrue(isSuccess(result))
    XCTAssertEqual(
      recorder.calls,
      [
        "run:msg create-window --working-directory \(directory.path)",
        "activate:com.apple.Terminal",
      ])
  }

  @MainActor
  func testAlacrittyStartsAnInstanceWhenNoneAnswers() async {
    for outcome in [ProcessOutcome.exited(1), .failedToStart] {
      let recorder = Recorder(outcome: outcome)
      let result = await OpenTerminalHereActionsCatalog.open(
        [TextSnippetItem(text: directory.path)], in: alacritty(), launcher: recorder.launcher())

      XCTAssertTrue(isSuccess(result), "\(outcome)")
      XCTAssertEqual(
        recorder.calls,
        [
          "run:msg create-window --working-directory \(directory.path)",
          "launch:--working-directory \(directory.path)",
        ], "\(outcome)")
    }
  }

  @MainActor
  func testAlacrittyTimeoutDoesNotOpenAFallbackWindowOrContinue() async throws {
    let other = directory.appendingPathComponent("other", isDirectory: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
    let recorder = Recorder(outcome: .timedOut)
    let result = await OpenTerminalHereActionsCatalog.open(
      [TextSnippetItem(text: directory.path), TextSnippetItem(text: other.path)],
      in: alacritty(), launcher: recorder.launcher())

    XCTAssertEqual(failure(result)?.contains("did not answer"), true)
    XCTAssertEqual(failure(result)?.contains("No other window was opened"), true)
    XCTAssertEqual(
      recorder.calls, ["run:msg create-window --working-directory \(directory.path)"])
  }

  @MainActor
  func testAlacrittyCancellationDoesNotOpenAFallbackWindow() async {
    let recorder = Recorder(outcome: .cancelled)
    let result = await OpenTerminalHereActionsCatalog.open(
      [TextSnippetItem(text: directory.path)], in: alacritty(), launcher: recorder.launcher())

    XCTAssertEqual(failure(result)?.contains("cancelled"), true)
    XCTAssertEqual(
      recorder.calls, ["run:msg create-window --working-directory \(directory.path)"])
  }

  @MainActor
  func testAlacrittyFallbackFailureIsReported() async {
    let recorder = Recorder(outcome: .exited(1), launchError: "no such app")
    let result = await OpenTerminalHereActionsCatalog.open(
      [TextSnippetItem(text: directory.path)], in: alacritty(), launcher: recorder.launcher())

    XCTAssertEqual(failure(result)?.contains("Alacritty could not open the folder"), true)
  }

  // MARK: The real helper process

  func testBoundedProcessReportsExitStatus() async {
    let succeeded = await BoundedProcess.run(
      URL(fileURLWithPath: "/usr/bin/true"), arguments: [], timeout: 5)
    let failed = await BoundedProcess.run(
      URL(fileURLWithPath: "/usr/bin/false"), arguments: [], timeout: 5)
    let missing = await BoundedProcess.run(
      URL(fileURLWithPath: "/nonexistent/helper"), arguments: [], timeout: 5)

    XCTAssertEqual(succeeded, .exited(0))
    XCTAssertEqual(failed, .exited(1))
    XCTAssertEqual(missing, .failedToStart)
  }

  func testBoundedProcessTimesOutAndStopsTheProcess() async throws {
    let started = Date()
    let outcome = await BoundedProcess.run(
      URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 0.3)

    XCTAssertEqual(outcome, .timedOut)
    XCTAssertLessThan(Date().timeIntervalSince(started), 5)
  }

  func testBoundedProcessStopsWhenTheTaskIsCancelled() async throws {
    let started = Date()
    let task = Task {
      await BoundedProcess.run(
        URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 30)
    }
    try await Task.sleep(nanoseconds: 200_000_000)
    task.cancel()
    let outcome = await task.value

    XCTAssertEqual(outcome, .cancelled)
    XCTAssertLessThan(Date().timeIntervalSince(started), 5)
  }

  func testBoundedProcessCancelledBeforeItStartsNeverRuns() async {
    let marker = directory.appendingPathComponent("ran")
    let task = Task {
      try? await Task.sleep(nanoseconds: 1_000_000_000)
      return await BoundedProcess.run(
        URL(fileURLWithPath: "/usr/bin/touch"), arguments: [marker.path], timeout: 5)
    }
    task.cancel()
    let outcome = await task.value

    XCTAssertEqual(outcome, .cancelled)
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
  }

  // MARK: Helpers

  @MainActor
  private func makeCatalog() -> OpenTerminalHereActionsCatalog {
    OpenTerminalHereActionsCatalog(
      definition: ActionCatalogDefinition(identifier: "test.open-terminal-here.actions", name: "Actions")
    )
  }

  @MainActor
  private func makeAction() throws -> PredicateAwareAction {
    try XCTUnwrap(makeCatalog().actions.first as? PredicateAwareAction)
  }

  @MainActor
  private func folder(ofText text: String) -> URL? {
    OpenTerminalHereActionsCatalog.folder(for: TextSnippetItem(text: text))
  }

  /// Alacritty's launch method, aimed at an app that is installed on every Mac.
  private func alacritty() -> TerminalApp {
    TerminalApp.alacritty.withInstalledBundle()
  }

  private func failure(_ result: ActionResult) -> String? {
    if case .failure(let message) = result { return message }
    return nil
  }

  private func isSuccess(_ result: ActionResult) -> Bool {
    if case .success = result { return true }
    return false
  }
}

extension TerminalApp {
  /// The same launch method with Terminal's bundle identifier, so the app resolves on any Mac.
  fileprivate func withInstalledBundle() -> TerminalApp {
    TerminalApp(
      id: id, name: name, bundleIdentifier: "com.apple.Terminal", launchMethod: launchMethod,
      rejectedNameEndings: rejectedNameEndings)
  }
}

/// Stands in for the system calls a launch makes and records them in order.
private final class Recorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [String] = []
  private let outcome: ProcessOutcome
  private let openError: String?
  private let launchError: String?

  init(outcome: ProcessOutcome = .exited(0), openError: String? = nil, launchError: String? = nil) {
    self.outcome = outcome
    self.openError = openError
    self.launchError = launchError
  }

  var calls: [String] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  private func record(_ call: String) {
    lock.lock()
    recorded.append(call)
    lock.unlock()
  }

  func launcher() -> TerminalLauncher {
    TerminalLauncher(
      run: { _, arguments, _ in
        self.record("run:" + arguments.joined(separator: " "))
        return self.outcome
      },
      open: { url, _ in
        self.record("open:" + (url.isFileURL ? url.path : url.absoluteString))
        if let message = self.openError { throw RecorderError(message: message) }
      },
      launchNewInstance: { _, arguments in
        self.record("launch:" + arguments.joined(separator: " "))
        if let message = self.launchError { throw RecorderError(message: message) }
      },
      activate: { bundleIdentifier in
        self.record("activate:" + bundleIdentifier)
      }
    )
  }
}

private struct RecorderError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}
