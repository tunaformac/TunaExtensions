import Foundation
import TunaKit

/// Text first: "github" → Search Password in Strongbox.
/// Command first: Password from Strongbox, or the Strongbox app → Copy Password… → "github".
/// Either way, Enter copies the one clear match or lists several to choose from.
@MainActor
public final class StrongboxActionsCatalog: ActionCatalog {
  nonisolated static let copy = "copy"

  /// Command first, the entry name typed in the third pane: `copy-password`, `copy-username`, `copy-totp`.
  nonisolated static func copyFieldID(_ field: StrongboxField) -> String { "copy-\(field.rawValue)" }
  /// Text first, no third pane: `search-password`, `search-username`, `search-totp`.
  nonisolated static func searchTextID(_ field: StrongboxField) -> String { "search-\(field.rawValue)" }

  public let identifier: String
  public let name: String
  public let actions: [CatalogAction]

  public init(definition: ActionCatalogDefinition) {
    identifier = definition.identifier
    name = definition.name
    actions =
      [Self.makeCopy()] + StrongboxField.allCases.map(Self.makeCopyField)
      + StrongboxField.allCases.map(Self.makeSearchText)
  }

  /// A listed match: copy its field.
  private static func makeCopy() -> CatalogAction {
    let action = CatalogAction(id: copy, title: "Copy from Strongbox") { subject, _ in
      guard let item = subject as? StrongboxEntryItem else {
        return .failure("Select a Strongbox entry first.")
      }
      return await StrongboxRuntime.copy(item.field, of: item.entry)
    }
    action.supportedSubjectTypes = [.strongboxEntry]
    action.systemSymbolName = "key"
    action.targetRequirement = .none
    action.recordsCommandHistory = false
    return action
  }

  /// "Copy Password…": its subject is Password from Strongbox or the Strongbox app, and its target
  /// the entry name. No text is seeded: the clipboard may hold a password copied a moment ago.
  private static func makeCopyField(_ field: StrongboxField) -> CatalogAction {
    let action = PredicateAwareAction(
      id: copyFieldID(field), title: "Copy \(field.name)…", executionPolicy: .resultDriven
    ) { _, target in
      await StrongboxRuntime.find(target?.textInputValue(), field: field)
    }
    action.supportedSubjectTypes = [.searchCatalogEntry, .application]
    action.subjectPredicate = { isSubject($0, for: field) }
    action.targetRequirement = .required
    action.allowedTargetTypes = [.textSnippet]
    action.targetPredicate = hasEntryName
    action.systemSymbolName = field.symbolName
    action.recordsCommandHistory = false
    return action
  }

  /// "Search Password in Strongbox": typed or selected text is the entry name.
  private static func makeSearchText(_ field: StrongboxField) -> CatalogAction {
    let action = PredicateAwareAction(
      id: searchTextID(field), title: "Search \(field.name) in Strongbox", executionPolicy: .resultDriven
    ) { subject, _ in
      await StrongboxRuntime.find(subject.textInputValue(), field: field)
    }
    action.supportedSubjectTypes = [.textSnippet]
    action.subjectPredicate = hasEntryName
    action.targetRequirement = .none
    action.systemSymbolName = field.symbolName
    action.recordsCommandHistory = false
    return action
  }

  nonisolated static func isSubject(_ subject: CatalogItem?, for field: StrongboxField) -> Bool {
    if let command = subject as? StrongboxFieldCommandItem { return command.field == field }
    return isStrongboxApplication(subject)
  }

  nonisolated static func isStrongboxApplication(_ subject: CatalogItem?) -> Bool {
    guard let entity = subject as? CatalogEntity, let path = entity.path,
      TypeRegistry.shared.inherits(entity.typeID, from: .application)
    else { return false }
    let identifier = Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier
    return identifier.map(StrongboxExtension.appBundleIdentifiers.contains) ?? false
  }

  /// At least two characters, as `find` needs. Shorter text isn't offered the action, so Tuna beeps
  /// and keeps the pane open instead of closing the launcher with a notice.
  nonisolated static func hasEntryName(_ item: CatalogItem?) -> Bool {
    StrongboxClient.entryName(item?.textInputValue()) != nil
  }
}
