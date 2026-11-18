import Foundation
import TunaKit

@objc(StrongboxExtension)
public final class StrongboxExtension: Extension {
  static let catalogIdentifier = "strongbox.search"
  nonisolated static let actionsCatalogIdentifier = "strongbox.actions"

  public override var declaration: ExtensionDeclaration? {
    ExtensionDeclaration(
      metadata: ExtensionMetadata(
        displayName: "Strongbox",
        author: "Denis Maier",
        description:
          "Copy passwords, usernames, and one-time codes from Strongbox through its local MCP interface.",
        iconName: "lock.shield"
      ),
      compatibility: ExtensionDeclarationCompatibility(minTuna: "0.110", minTunaKit: "1.22.0"),
      catalogs: [
        // Only the two search roots enter global search. Entries are never indexed.
        CatalogDeclaration(
          id: Self.catalogIdentifier,
          type: StrongboxCatalog.self,
          name: "Strongbox",
          presentation: .source,
          enabledByDefault: true,
          initialGlobalScope: .all
        )
      ],
      actionCatalogs: [
        ActionCatalogDeclaration(
          id: Self.actionsCatalogIdentifier,
          type: StrongboxActionsCatalog.self,
          name: "Strongbox Actions"
        )
      ],
      typeRegistrations: [
        // No inheritance, so Tuna's generic text actions never apply to an entry.
        TypeRegistrationDefinition(
          typeID: .strongboxEntry, displayName: "Strongbox Entries", inheritsFrom: []),
        TypeRegistrationDefinition(
          typeID: .strongboxQuery, displayName: "Strongbox Queries", inheritsFrom: []),
      ],
      defaultActionRankings: [
        DefaultActionRankingDefinition(
          typeID: .strongboxEntry,
          actions: [
            ActionReference(
              catalogIdentifier: Self.actionsCatalogIdentifier, actionID: StrongboxActionsCatalog.copy)
          ]
        ),
        DefaultActionRankingDefinition(
          typeID: .strongboxQuery,
          actions: [
            ActionReference(
              catalogIdentifier: Self.actionsCatalogIdentifier, actionID: StrongboxActionsCatalog.find)
          ]
        ),
      ]
    )
  }
}

extension TypeID {
  static let strongboxEntry = TypeID("com.tuna.type.strongbox-entry")
  static let strongboxQuery = TypeID("com.tuna.type.strongbox-query")
}
