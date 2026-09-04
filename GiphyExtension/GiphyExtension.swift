import Foundation
import TunaKit

@objc(GiphyExtension)
public final class GiphyExtension: Extension {
  public override var declaration: ExtensionDeclaration? {
    ExtensionDeclaration(
      metadata: ExtensionMetadata(
        displayName: "GIPHY",
        author: "Tuna",
        description: "Browse, search, and paste GIFs powered by GIPHY.",
        iconName: "photo.stack"
      ),
      compatibility: ExtensionDeclarationCompatibility(minTuna: "0.96", minTunaKit: "1.22.0"),
      settings: GiphySettings.definitions,
      catalogs: [
        CatalogDeclaration(
          id: "giphy",
          type: GiphyCatalog.self,
          name: "GIPHY",
          presentation: .liveSearch,
          description: "Search and paste GIFs · Powered by GIPHY",
          enabledByDefault: true
        )
      ],
      actionCatalogs: [
        ActionCatalogDeclaration(
          id: "giphy.actions",
          type: GiphyActionsCatalog.self,
          name: "GIPHY Actions"
        )
      ],
      typeRegistrations: [
        TypeRegistrationDefinition(
          typeID: .giphyGIF,
          displayName: "GIPHY GIFs",
          inheritsFrom: [.url]
        )
      ],
      defaultActionRankings: [
        DefaultActionRankingDefinition(
          typeID: .giphyGIF,
          actions: [
            ActionReference(catalogIdentifier: "giphy.actions", actionID: "copy-url"),
            ActionReference(catalogIdentifier: "giphy.actions", actionID: "resolve"),
          ]
        )
      ]
    )
  }
}

enum GiphySettings {
  static let sharedBetaAPIKey = "spHSUYH2w0W13jAdZ4QaV3lPNpTdSfBP"

  static let apiKey = CatalogSettingDefinition(
    key: "APIKey",
    type: .secret,
    label: "Personal GIPHY API key (optional)",
    defaultValue: "",
    description:
      "Overrides Tuna's shared beta key and its shared 100 requests/hour limit. Create a key at https://developers.giphy.com/dashboard/. It stays in your Mac Keychain."
  )

  static let rating = CatalogSettingDefinition(
    key: "Rating",
    type: .string,
    label: "Content rating",
    defaultValue: "g",
    description: "The highest content rating GIPHY may return.",
    options: [
      .init(value: "g", label: "G"),
      .init(value: "pg", label: "PG"),
      .init(value: "pg-13", label: "PG-13"),
      .init(value: "r", label: "R"),
    ]
  )

  static let definitions = [apiKey, rating]

  static var currentAPIKey: String {
    let value = currentStore.secretValue(for: apiKey)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? sharedBetaAPIKey : value
  }

  static var currentRating: String {
    let value = currentStore.stringValue(for: rating)
    return ["g", "pg", "pg-13", "r"].contains(value) ? value : "g"
  }

  private static var currentStore: CatalogSettingStore {
    let bundle = Bundle(for: GiphyExtension.self)
    let identifier = bundle.bundleIdentifier
      ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "TunaGiphy")
    return CatalogSettingStore(catalogIdentifier: identifier)
  }
}

extension TypeID {
  static let giphyGIF = TypeID("com.tuna.type.giphy-gif")
}
