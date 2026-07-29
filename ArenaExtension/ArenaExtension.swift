import Foundation
import TunaKit

@objc(ArenaExtension)
public final class ArenaExtension: Extension {
  static let catalogIdentifier = "arena"
  private static let clientIdentifier = "OtwIqy8-gmNYOQkd8BqrDWlJtymLiqbqR7Oq3ydscH0"

  public override var declaration: ExtensionDeclaration? {
    ExtensionDeclaration(
      metadata: ExtensionMetadata(
        displayName: "Are.na",
        author: "Tuna",
        description: "Browse Are.na channels and save links, text, and images.",
        iconName: "square.grid.2x2"
      ),
      compatibility: ExtensionDeclarationCompatibility(minTuna: "0.80", minTunaKit: "1.15.0"),
      catalogs: [
        CatalogDeclaration(
          id: Self.catalogIdentifier,
          type: ArenaCatalog.self,
          name: "Are.na",
          enabledByDefault: true)
      ],
      actionCatalogs: [
        ActionCatalogDeclaration(
          id: "arena.actions", type: ArenaActionsCatalog.self, name: "Are.na Actions")
      ],
      typeRegistrations: [
        TypeRegistrationDefinition(
          typeID: .arenaChannel,
          displayName: "Are.na Channels",
          inheritsFrom: [.entity]
        ),
        TypeRegistrationDefinition(
          typeID: .arenaBlock,
          displayName: "Are.na Blocks",
          inheritsFrom: [.url]
        ),
      ],
      defaultActionRankings: [
        DefaultActionRankingDefinition(
          typeID: .arenaChannel,
          actions: [
            ActionReference(catalogIdentifier: "arena.actions", actionID: "open-channel"),
            ActionReference(catalogIdentifier: "arena.actions", actionID: "resolve"),
          ]
        ),
        DefaultActionRankingDefinition(
          typeID: .arenaBlock,
          actions: [
            ActionReference(catalogIdentifier: "arena.actions", actionID: "open-block"),
            ActionReference(catalogIdentifier: "arena.actions", actionID: "resolve"),
          ]
        ),
      ]
    )
  }

  public override var connectionDefinitions: [ExtensionConnectionDefinition] {
    [
      ExtensionConnectionDefinition(
        providerIdentifier: "arena",
        providerName: "Are.na",
        oauthPKCE: OAuthPKCEConfiguration(
          clientIdentifier: Self.clientIdentifier,
          authorizationURL: URL(string: "https://www.are.na/oauth/authorize")!,
          tokenURL: URL(string: "https://api.are.na/v3/oauth/token")!,
          scopes: ["read", "write"]
        ),
        description: "Connect Are.na to browse channels and save links, text, and images.",
        connectButtonLabel: "Connect Are.na"
      )
    ]
  }
}
