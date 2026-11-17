import Foundation
import TunaKit

@MainActor
public final class StrongboxActionsCatalog: ActionCatalog {
  static let copy = "copy"
  static let find = "find-and-copy"

  public let identifier: String
  public let name: String
  public let actions: [CatalogAction]

  public init(definition: ActionCatalogDefinition) {
    identifier = definition.identifier
    name = definition.name
    let copy = CatalogAction(id: Self.copy, title: "Copy from Strongbox") { subject, _ in
      guard let item = subject as? StrongboxEntryItem else {
        return .failure("Select a Strongbox entry first.")
      }
      return await StrongboxRuntime.copy(item.field, of: item.entry)
    }
    copy.supportedSubjectTypes = [.strongboxEntry]
    copy.systemSymbolName = "key"
    copy.targetRequirement = .none
    copy.recordsCommandHistory = false
    let find = CatalogAction(
      id: Self.find, title: "Find and Copy from Strongbox", executionPolicy: .resultDriven
    ) { subject, _ in
      guard let item = subject as? StrongboxQueryItem else {
        return .failure("Type an entry name first.")
      }
      return await StrongboxRuntime.find(item.query, field: item.field)
    }
    find.supportedSubjectTypes = [.strongboxQuery]
    find.systemSymbolName = "key"
    find.targetRequirement = .none
    find.recordsCommandHistory = false
    actions = [copy, find]
  }
}
