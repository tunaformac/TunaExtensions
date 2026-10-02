import Foundation
import TunaKit

@objc(DokployExtension)
public final class DokployExtension: Extension {
  public override var declaration: ExtensionDeclaration? {
    ExtensionDeclaration(
      metadata: ExtensionMetadata(
        displayName: "Dokploy",
        author: "Mert Topuz",
        description: "Search Dokploy applications and compose services, deploy, start, and stop them.",
        iconName: "shippingbox"
      ),
      compatibility: ExtensionDeclarationCompatibility(minTuna: "0.95", minTunaKit: "1.21.0"),
      catalogs: [
        CatalogDeclaration(
          id: DokployCatalogIDs.services,
          type: DokployServicesCatalog.self,
          name: "Dokploy Services",
          presentation: .source,
          description: "Applications and compose services from your Dokploy servers.",
          enabledByDefault: true
        ),
        CatalogDeclaration(
          id: DokployCatalogIDs.browse,
          type: DokployBrowseCatalog.self,
          name: "Dokploy",
          presentation: .browseRoot(contents: DokployCatalogIDs.services),
          description: "Browse Dokploy projects and their services.",
          enabledByDefault: true
        ),
      ],
      actionCatalogs: [
        ActionCatalogDeclaration(
          id: DokployCatalogIDs.actions,
          type: DokployActionsCatalog.self,
          name: "Dokploy Actions"
        )
      ],
      typeRegistrations: [
        TypeRegistrationDefinition(
          typeID: .dokployApplication, displayName: "Dokploy Applications",
          inheritsFrom: [.entity]),
        TypeRegistrationDefinition(
          typeID: .dokployCompose, displayName: "Dokploy Compose Services",
          inheritsFrom: [.entity]),
      ],
      defaultActionRankings: [.dokployApplication, .dokployCompose].map { typeID in
        DefaultActionRankingDefinition(
          typeID: typeID,
          actions: [
            ActionReference(catalogIdentifier: DokployCatalogIDs.actions, actionID: "open-in-dokploy"),
            ActionReference(catalogIdentifier: DokployCatalogIDs.actions, actionID: "deploy"),
          ]
        )
      }
    )
  }

  public override var connectionDefinitions: [ExtensionConnectionDefinition] {
    [DokployConnections.definition]
  }
}

enum DokployCatalogIDs {
  static let services = "dokploy-apps"
  static let browse = "dokploy"
  static let actions = "dokploy-actions"
}

extension TypeID {
  static let dokployApplication = TypeID("com.tuna.type.dokploy-application")
  static let dokployCompose = TypeID("com.tuna.type.dokploy-compose")
}

/// A configured Dokploy server. The API key only ever lives inside `configuration`.
struct DokployConnection: Sendable {
  let recordID: String
  let displayName: String
  let configuration: DokployConfiguration
}

enum DokployConnections {
  static let providerIdentifier = "dokploy"

  static let definition = ExtensionConnectionDefinition(
    providerIdentifier: providerIdentifier,
    providerName: "Dokploy",
    kind: .secret,
    supportsBaseURL: true,
    defaultBaseURL: "",
    baseURLLabel: "Dokploy URL",
    secretLabel: "API Key",
    description:
      "Enter your Dokploy server address (for example https://dokploy.example.com) and an API key from Settings > Profile > API/CLI in the Dokploy panel.",
    connectButtonLabel: "Add Server"
  )

  /// Connections with a usable URL and key. Read from the store on every call so setting changes
  /// take effect on the next scan.
  static func all() -> [DokployConnection] {
    guard let store = store() else { return [] }
    return store.orderedRecords().compactMap { connection(for: $0, in: store) }
  }

  /// Number of saved records, including ones that are missing a URL or key.
  static func recordCount() -> Int {
    store()?.orderedRecords().count ?? 0
  }

  static func connection(recordID: String) -> DokployConnection? {
    guard let store = store(),
      let record = store.orderedRecords().first(where: { $0.id == recordID })
    else { return nil }
    return connection(for: record, in: store)
  }

  private static func store() -> ExtensionConnectionStore? {
    guard let bundleIdentifier = Bundle(for: DokployExtension.self).bundleIdentifier else {
      return nil
    }
    return ExtensionConnectionStore(
      extensionIdentifier: bundleIdentifier,
      providerIdentifier: providerIdentifier
    )
  }

  private static func connection(
    for record: ExtensionConnectionRecord, in store: ExtensionConnectionStore
  ) -> DokployConnection? {
    guard
      let apiKey = store.accessToken(for: record)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !apiKey.isEmpty,
      let configuration = DokployConfiguration(baseURLString: record.trimmedBaseURLString, apiKey: apiKey)
    else { return nil }
    let name = record.trimmedDisplayName
    return DokployConnection(
      recordID: record.id,
      displayName: name.isEmpty ? (configuration.baseURL.host ?? "Dokploy") : name,
      configuration: configuration
    )
  }
}
