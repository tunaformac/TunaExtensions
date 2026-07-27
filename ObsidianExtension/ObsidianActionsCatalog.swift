import AppKit
import Foundation
import TunaKit

enum ObsidianCatalogIdentifiers {
  static let actions = "obsidian.actions"
  static let search = "obsidian.search"
}

enum ObsidianActionHierarchyIdentifiers {
  static let openNote = "obsidian.action.open-note"
}

private final class ObsidianOpenNoteAction: CatalogAction, ActionPredicateProviding,
  @unchecked Sendable
{
  var subjectPredicate: CatalogActionSubjectPredicate?
  var targetPredicate: CatalogActionTargetPredicate?

  init(callback: @escaping ActionCallback) {
    super.init(
      id: ObsidianActionHierarchyIdentifiers.openNote,
      title: "Open",
      type: .action,
      callback: callback)
  }
}

public final class ObsidianActionsCatalog: NSObject, ActionCatalog {
  public let identifier: String
  public let name: String

  public private(set) lazy var actions: [CatalogAction] = Self.actions()

  public required init(definition: ActionCatalogDefinition) {
    self.identifier = definition.identifier
    self.name = definition.name
    super.init()
  }

  static func actions() -> [CatalogAction] {
    var items: [CatalogAction] = []

    let openNote = ObsidianOpenNoteAction { subject, _ in
      guard let note = subject as? ObsidianNoteItem else {
        return .failure("No Obsidian note selected")
      }
      guard
        let url = ObsidianActions.noteURL(
          vaultName: note.vaultName,
          relativePath: note.relativePath)
      else {
        return .failure("Invalid Obsidian URL")
      }
      ObsidianPreferences.lastUsedVaultName = note.vaultName
      URIOpener.open(url)
      return .success
    }
    openNote.systemSymbolName = "arrow.up.right.square"
    openNote.supportedSubjectTypes = [.obsidianNote]
    openNote.subjectPredicate = { $0 is ObsidianNoteItem }
    items.append(openNote)

    let openVault = PredicateAwareAction(
      id: "open-vault-in-obsidian", title: "Open Vault in Obsidian", type: .action
    ) { subject, _ in
      guard let vault = subject as? ObsidianVaultItem else {
        return .failure("No Obsidian vault selected")
      }
      guard let url = ObsidianActions.vaultURL(vaultName: vault.vaultName) else {
        return .failure("Invalid Obsidian URL")
      }
      ObsidianPreferences.lastUsedVaultName = vault.vaultName
      URIOpener.open(url)
      return .success
    }
    openVault.systemSymbolName = "book"
    openVault.supportedSubjectTypes = [.obsidianVault]
    openVault.subjectPredicate = { $0 is ObsidianVaultItem }
    items.append(openVault)

    let searchVault = PredicateAwareAction(id: "search-vault", title: "Search Vault", type: .action)
    { subject, target in
      guard let vault = subject as? ObsidianVaultItem else {
        return .failure("No Obsidian vault selected")
      }

      let query = target?.textValueFallback()?.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let url = ObsidianActions.searchURL(vaultName: vault.vaultName, query: query) else {
        return .failure("Invalid Obsidian URL")
      }

      ObsidianPreferences.lastUsedVaultName = vault.vaultName
      URIOpener.open(url)
      return .success
    }
    searchVault.systemSymbolName = "magnifyingglass"
    searchVault.targetRequirement = .optional
    searchVault.supportedSubjectTypes = [.obsidianVault]
    searchVault.allowedTargetTypes = [.textSnippet]
    searchVault.subjectPredicate = { $0 is ObsidianVaultItem }
    items.append(searchVault)

    let newNoteInVault = PredicateAwareAction(id: "new-note", title: "New Note", type: .action) {
      subject, _ in
      guard let vault = subject as? ObsidianVaultItem else {
        return .failure("No Obsidian vault selected")
      }
      return ObsidianCommandRunner.createBlankNote(inVaultNamed: vault.vaultName)
    }
    newNoteInVault.systemSymbolName = "square.and.pencil"
    newNoteInVault.supportedSubjectTypes = [.obsidianVault]
    newNoteInVault.subjectPredicate = { $0 is ObsidianVaultItem }
    items.append(newNoteInVault)

    let newNoteFromText = PredicateAwareAction(
      id: "new-obsidian-note", title: "New Obsidian Note", type: .action
    ) { subject, _ in
      guard let content = subject.textValueFallback() else {
        return .failure("Select text first")
      }
      return ObsidianCommandRunner.createNoteFromText(content)
    }
    newNoteFromText.systemSymbolName = "square.and.pencil"
    newNoteFromText.supportedSubjectTypes = [.textSnippet]
    newNoteFromText.subjectPredicate = { $0?.textValueFallback() != nil }
    items.append(newNoteFromText)

    let newNoteFromApp = PredicateAwareAction(
      id: "new-note.from-app", title: "New Note", type: .action
    ) { _, target in
      guard let content = target?.textValueFallback() else {
        return .failure("Missing note text")
      }
      return ObsidianCommandRunner.createNoteFromText(content)
    }
    newNoteFromApp.targetRequirement = .required
    newNoteFromApp.systemSymbolName = "square.and.pencil"
    newNoteFromApp.supportedSubjectTypes = [.application]
    newNoteFromApp.allowedTargetTypes = [.textSnippet]
    newNoteFromApp.subjectPredicate = ObsidianActions.isObsidianApplication
    newNoteFromApp.targetPredicate = { $0?.textValueFallback() != nil }
    items.append(newNoteFromApp)

    let searchFromApp = PredicateAwareAction(id: "search", title: "Search", type: .action) {
      _, target in
      let query = target?.textValueFallback()?.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let vaultName = ObsidianCommandRunner.resolvedVaultName() else {
        return .failure("Select an Obsidian vault first")
      }
      guard let url = ObsidianActions.searchURL(vaultName: vaultName, query: query) else {
        return .failure("Invalid Obsidian URL")
      }
      ObsidianPreferences.lastUsedVaultName = vaultName
      URIOpener.open(url)
      return .success
    }
    searchFromApp.targetRequirement = .optional
    searchFromApp.systemSymbolName = "magnifyingglass"
    searchFromApp.supportedSubjectTypes = [.application]
    searchFromApp.allowedTargetTypes = [.textSnippet]
    searchFromApp.subjectPredicate = ObsidianActions.isObsidianApplication
    items.append(searchFromApp)

    let copyURI = PredicateAwareAction(
      id: "copy-obsidian-uri", title: "Copy Obsidian URI", type: .action
    ) { subject, _ in
      guard let note = subject as? ObsidianNoteItem else {
        return .failure("No Obsidian note selected")
      }
      guard
        let url = ObsidianActions.noteURL(
          vaultName: note.vaultName,
          relativePath: note.relativePath)
      else {
        return .failure("Invalid Obsidian URL")
      }
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(url.absoluteString, forType: .string)
      return .success
    }
    copyURI.systemSymbolName = "link"
    copyURI.supportedSubjectTypes = [.obsidianNote]
    copyURI.subjectPredicate = { $0 is ObsidianNoteItem }
    items.append(copyURI)

    return items
  }
}

enum ObsidianActions {
  static func noteURL(vaultName: String, relativePath: String) -> URL? {
    let trimmedVault = vaultName.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedPath = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedVault.isEmpty, !trimmedPath.isEmpty else { return nil }

    var components = URLComponents()
    components.scheme = "obsidian"
    components.host = "open"
    components.percentEncodedQueryItems = [
      percentEncodedQueryItem(name: "vault", value: trimmedVault),
      percentEncodedQueryItem(name: "file", value: trimmedPath),
    ]
    return components.url
  }

  static func vaultURL(vaultName: String) -> URL? {
    let trimmed = vaultName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    var components = URLComponents()
    components.scheme = "obsidian"
    components.host = "open"
    components.percentEncodedQueryItems = [
      percentEncodedQueryItem(name: "vault", value: trimmed)
    ]
    return components.url
  }

  static func newNoteURL(
    vaultName: String,
    name: String,
    content: String
  ) -> URL? {
    let trimmedVault = vaultName.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedVault.isEmpty, !trimmedName.isEmpty else { return nil }

    var components = URLComponents()
    components.scheme = "obsidian"
    components.host = "new"
    components.percentEncodedQueryItems = [
      percentEncodedQueryItem(name: "vault", value: trimmedVault),
      percentEncodedQueryItem(name: "name", value: trimmedName),
      percentEncodedQueryItem(name: "content", value: content),
    ]
    return components.url
  }

  static func dailyNoteURL(vaultName: String) -> URL? {
    let trimmed = vaultName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    var components = URLComponents()
    components.scheme = "obsidian"
    components.host = "adv-uri"
    components.percentEncodedQueryItems = [
      URLQueryItem(name: "daily", value: "true"),
      percentEncodedQueryItem(name: "vault", value: trimmed),
    ]
    return components.url
  }

  static func isObsidianApplication(_ subject: CatalogItem?) -> Bool {
    guard let entity = subject as? CatalogEntity,
      let path = entity.path,
      TypeRegistry.shared.inherits(entity.typeID, from: .application)
    else { return false }
    return Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier == "md.obsidian"
  }

  static func searchURL(vaultName: String, query: String?) -> URL? {
    let trimmedVault = vaultName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedVault.isEmpty else { return nil }

    let normalizedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines)

    var components = URLComponents()
    components.scheme = "obsidian"
    components.host = "search"
    var items = [
      percentEncodedQueryItem(name: "vault", value: trimmedVault)
    ]
    if let normalizedQuery, !normalizedQuery.isEmpty {
      items.append(percentEncodedQueryItem(name: "query", value: normalizedQuery))
    }
    components.percentEncodedQueryItems = items
    return components.url
  }

  /// Percent-encodes a query value using only RFC 3986 unreserved characters, so literal "+"
  /// is escaped to "%2B" instead of being left ambiguous with encoded spaces (unlike
  /// `URLQueryItem`'s default `.urlQueryAllowed` encoding, which leaves "+" untouched).
  private static func percentEncodedQueryItem(name: String, value: String) -> URLQueryItem {
    URLQueryItem(
      name: name,
      value: value.addingPercentEncoding(withAllowedCharacters: .rfc3986Unreserved) ?? value)
  }
}

extension CharacterSet {
  fileprivate static let rfc3986Unreserved = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

private enum ObsidianPreferences {
  private static let key = "ObsidianLastUsedVaultName"

  static var lastUsedVaultName: String? {
    get {
      let value = UserDefaults.standard.string(forKey: key)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard let value, !value.isEmpty else { return nil }
      return value
    }
    set {
      let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let trimmed, !trimmed.isEmpty else { return }
      UserDefaults.standard.set(trimmed, forKey: key)
    }
  }
}

enum ObsidianCommandRunner {
  static func createBlankNote(inVaultNamed vaultName: String) -> ActionResult {
    let trimmedVault = vaultName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedVault.isEmpty else { return .failure("Missing vault") }

    let timestamp = Date.now.formatted(.dateTime.year().month().day().hour().minute())
    let title = ObsidianNoteNameSanitizer.sanitize("New Note \(timestamp)")

    guard
      let url = ObsidianActions.newNoteURL(
        vaultName: trimmedVault,
        name: title,
        content: "")
    else {
      return .failure("Invalid Obsidian URL")
    }

    ObsidianPreferences.lastUsedVaultName = trimmedVault
    URIOpener.open(url)
    return .success
  }

  static func createNoteFromText(_ text: String) -> ActionResult {
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty else { return .failure("Missing note text") }

    return .background(
      CommandBackgroundTask(
        title: "Creating note in Obsidian"
      ) {
        guard let vaultName = resolvedVaultName() else {
          return .failure(message: "Select an Obsidian vault first")
        }

        let title = ObsidianNoteNameSanitizer.sanitize(suggestedTitle(from: trimmedText))
        guard
          let url = ObsidianActions.newNoteURL(
            vaultName: vaultName,
            name: title,
            content: trimmedText)
        else {
          return .failure(message: "Invalid Obsidian URL")
        }

        ObsidianPreferences.lastUsedVaultName = vaultName

        await URIOpener.openOnMainActor(url)
        return .successWithoutResult()
      })
  }

  static func openDailyNote() -> ActionResult {
    .background(
      CommandBackgroundTask(
        title: "Opening daily note"
      ) {
        guard let vaultName = resolvedVaultName() else {
          return .failure(message: "Select an Obsidian vault first")
        }

        guard let url = ObsidianActions.dailyNoteURL(vaultName: vaultName) else {
          return .failure(message: "Invalid Obsidian URL")
        }

        ObsidianPreferences.lastUsedVaultName = vaultName

        await URIOpener.openOnMainActor(url)

        return .successWithoutResult()
      })
  }

  static func resolvedVaultName() -> String? {
    if let lastUsed = ObsidianPreferences.lastUsedVaultName {
      return lastUsed
    }

    let result = ObsidianVaultLocator.locateVaults()
    switch result {
    case .success(let vaults):
      if vaults.count == 1 {
        let name = vaults[0].name
        ObsidianPreferences.lastUsedVaultName = name
        return name
      }
      return nil
    case .failure:
      return nil
    }
  }

  private static func suggestedTitle(from content: String) -> String {
    let first =
      content.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
      ?? "New Note"
    let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "New Note" }
    return trimmed
  }
}

enum ObsidianNoteNameSanitizer {
  static func sanitize(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "New Note" }

    let forbidden = CharacterSet(charactersIn: "\\/:*?\"<>|")
    let replaced = trimmed
      .unicodeScalars
      .map { scalar in forbidden.contains(scalar) ? " " : String(scalar) }
      .joined()

    let collapsed =
      replaced
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    return collapsed.isEmpty ? "New Note" : collapsed
  }
}
