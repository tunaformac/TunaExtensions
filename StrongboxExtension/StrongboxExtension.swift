import Foundation
import TunaKit

@objc(StrongboxExtension)
public final class StrongboxExtension: Extension {
  nonisolated static let catalogIdentifier = "strongbox.search"
  nonisolated static let vaultsCatalogIdentifier = "strongbox.vaults"
  nonisolated static let actionsCatalogIdentifier = "strongbox.actions"
  /// The App Store build is `.pro`; the plain identifier is Strongbox's older App Store app.
  /// Setapp isn't listed, because its MCP helper hasn't been verified.
  nonisolated static let appBundleIdentifiers = [
    "com.markmcguill.strongbox.pro", "com.markmcguill.strongbox",
  ]

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
        // Password, Username and OTP from Strongbox: the command-first subjects. Entries are never indexed.
        CatalogDeclaration(
          id: Self.catalogIdentifier,
          type: StrongboxCatalog.self,
          name: "Strongbox Commands",
          presentation: .source,
          description: "Password, Username and OTP from Strongbox",
          enabledByDefault: true,
          initialGlobalScope: .none
        ),
        // Only for Strongbox → Right Arrow, so vault names stay out of global search.
        CatalogDeclaration(
          id: Self.vaultsCatalogIdentifier,
          type: StrongboxVaultsCatalog.self,
          name: "Strongbox Vaults",
          presentation: .source,
          description: "The vault to search, chosen under the Strongbox app",
          enabledByDefault: true,
          initialGlobalScope: .none
        ),
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
          typeID: .strongboxEntry, displayName: "Strongbox Entries", inheritsFrom: [])
      ],
      defaultActionRankings: [
        DefaultActionRankingDefinition(
          typeID: .strongboxEntry,
          actions: [
            ActionReference(
              catalogIdentifier: Self.actionsCatalogIdentifier, actionID: StrongboxActionsCatalog.copy)
          ]
        )
      ],
      appBrowseEnrichments: [
        AppBrowseEnrichmentDefinition(
          bundleIdentifiers: Self.appBundleIdentifiers,
          entries: [
            AppBrowseEnrichmentEntryDefinition(catalogIdentifier: Self.vaultsCatalogIdentifier)
          ]
        )
      ],
      appActionEnrichments: [
        AppActionEnrichmentDefinition(
          bundleIdentifiers: Self.appBundleIdentifiers,
          catalogIdentifiers: [Self.actionsCatalogIdentifier],
          preferredActions: StrongboxField.allCases.map {
            ActionReference(
              catalogIdentifier: Self.actionsCatalogIdentifier,
              actionID: StrongboxActionsCatalog.copyFieldID($0))
          }
        )
      ]
    )
  }
}

extension TypeID {
  static let strongboxEntry = TypeID("com.tuna.type.strongbox-entry")
}
