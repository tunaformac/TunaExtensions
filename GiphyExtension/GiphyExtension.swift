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

  static let definitions = [rating]

  static var currentRating: String {
    let bundle = Bundle(for: GiphyExtension.self)
    let identifier = bundle.bundleIdentifier
      ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "TunaGiphy")
    let value = CatalogSettingStore(catalogIdentifier: identifier).stringValue(for: rating)
    return ["g", "pg", "pg-13", "r"].contains(value) ? value : "g"
  }
}

extension TypeID {
  static let giphyGIF = TypeID("com.tuna.type.giphy-gif")
}
