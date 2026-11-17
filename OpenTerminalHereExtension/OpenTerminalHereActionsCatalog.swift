import AppKit
import Foundation
import TunaKit

public final class OpenTerminalHereActionsCatalog: ActionCatalog {
  public let identifier: String
  public let name: String

  public private(set) lazy var actions: [CatalogAction] = [Self.makeAction()]

  public required init(definition: ActionCatalogDefinition) {
    identifier = definition.identifier
    name = definition.name
  }

  private static func makeAction() -> CatalogAction {
    let action = PredicateAwareAction(
      id: "open-terminal-here",
      title: "Open Terminal Here",
      headlessEligibility: .guaranteed
    ) { subject, _ in
      await open([subject], terminalID: OpenTerminalHereSettings.currentTerminalID)
    }
    action.batchCallback = { subjects, _ in
      await open(subjects, terminalID: OpenTerminalHereSettings.currentTerminalID)
    }
    action.systemSymbolName = "terminal"
    action.supportedSubjectTypes = [.file, .directory, .textSnippet]
    action.subjectPredicate = { item in
      guard let item else { return false }
      return folder(for: item) != nil
    }
    action.executionPolicy = .dismiss
    return action
  }

  /// Opens the folders in the terminal chosen in the settings. It never falls back to another app.
  @MainActor
  static func open(
    _ subjects: [CatalogItem], terminalID: String, launcher: TerminalLauncher = .live
  ) async -> ActionResult {
    guard let app = TerminalApp.all.first(where: { $0.id == terminalID }) else {
      return .failure(
        "\"\(terminalID)\" is not a supported terminal. Choose one in Open Terminal Here's settings."
      )
    }
    return await open(subjects, in: app, launcher: launcher)
  }

  @MainActor
  static func open(
    _ subjects: [CatalogItem], in app: TerminalApp, launcher: TerminalLauncher = .live
  ) async -> ActionResult {
    guard let applicationURL = app.applicationURL else {
      return .failure(
        "\(app.name) is not installed. Install it, or choose another terminal in Open Terminal Here's settings."
      )
    }
    var folders: [URL] = []
    for folder in subjects.compactMap(folder(for:)) where !folders.contains(folder) {
      folders.append(folder)
    }
    guard !folders.isEmpty else {
      return .failure("Choose a file, a folder, or the text of an existing path")
    }
    if let message = folders.lazy.compactMap(app.unsupportedMessage(for:)).first {
      return .failure(message)
    }

    if let message = await app.open(folders, applicationURL: applicationURL, launcher: launcher) {
      return .failure("\(app.name) could not open the folder: \(message)")
    }
    return .success
  }

  /// The subject itself when it is a folder, otherwise the folder that contains it.
  static func folder(for item: CatalogItem) -> URL? {
    for path in candidatePaths(of: item) {
      let url = URL(fileURLWithPath: path).standardizedFileURL
      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
        return isDirectory.boolValue ? url : url.deletingLastPathComponent()
      }
    }
    return nil
  }

  /// The paths a subject may mean, best match first.
  ///
  /// A file or folder subject has exactly one. Text is tried as written, because names can start or
  /// end with whitespace, and then trimmed, because pasted paths often carry a newline or spaces.
  private static func candidatePaths(of item: CatalogItem) -> [String] {
    let registry = TypeRegistry.shared
    if registry.inherits(item.typeID, from: .file) || registry.inherits(item.typeID, from: .directory),
      let path = (item as? CatalogEntity)?.path
    {
      return [path]
    }

    guard let text = item.textInputValue() else { return [] }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return (text == trimmed ? [text] : [text, trimmed]).compactMap(path(fromText:))
  }

  /// Text that is an absolute, `~`, or `file:` path.
  private static func path(fromText text: String) -> String? {
    guard !text.isEmpty else { return nil }
    if let url = URL(string: text), url.isFileURL {
      return url.path
    }
    let expanded = (text as NSString).expandingTildeInPath
    return expanded.hasPrefix("/") ? expanded : nil
  }
}
