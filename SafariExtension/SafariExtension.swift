import Foundation
import TunaKit

@objc(SafariExtension)
public final class SafariExtension: Extension {
  public override var declaration: ExtensionDeclaration? {
    ExtensionDeclaration(
      metadata: ExtensionMetadata(
        displayName: "Safari",
        author: "Tuna",
        description: "Safari bookmarks, reading list, and actions.",
        iconName: "safari"
      ),
      compatibility: ExtensionDeclarationCompatibility(minTuna: "0.95", minTunaKit: "1.21.0"),
      catalogs: [
        CatalogDeclaration(
          id: "safari.bookmarks", type: SafariBookmarksCatalog.self, name: "Bookmarks",
          presentation: .source, enabledByDefault: true),
        CatalogDeclaration(
          id: "safari.bookmarks.search", type: SafariBookmarksSearchCatalog.self, name: "Bookmarks",
          presentation: .browseRoot(contents: "safari.bookmarks"), enabledByDefault: true),
        CatalogDeclaration(
          id: "safari.reading-list", type: SafariReadingListCatalog.self, name: "Reading List",
          presentation: .source, enabledByDefault: true),
        CatalogDeclaration(
          id: "safari.reading-list.search", type: SafariReadingListSearchCatalog.self,
          name: "Reading List", presentation: .browseRoot(contents: "safari.reading-list"),
          enabledByDefault: true),
        CatalogDeclaration(
          id: "safari.favorites", type: SafariFavoritesCatalog.self, name: "Favorites",
          presentation: .source, enabledByDefault: true),
        CatalogDeclaration(
          id: "safari.favorites.search", type: SafariFavoritesSearchCatalog.self, name: "Favorites",
          presentation: .browseRoot(contents: "safari.favorites"), enabledByDefault: true),
        CatalogDeclaration(
          id: "safari.utilities", type: SafariMetaCatalog.self, name: "Safari Utilities",
          presentation: .source, enabledByDefault: true),
      ],
      actionCatalogs: [
        ActionCatalogDeclaration(
          id: "safari.actions", type: SafariActionsCatalog.self, name: "Safari Actions"),
      ],
      appBrowseEnrichments: [
        AppBrowseEnrichmentDefinition(
          bundleIdentifiers: ["com.apple.Safari"],
          entries: [
            AppBrowseEnrichmentEntryDefinition(
              catalogIdentifier: "safari.bookmarks.search", title: "Bookmarks"),
            AppBrowseEnrichmentEntryDefinition(
              catalogIdentifier: "safari.favorites.search", title: "Favorites"),
            AppBrowseEnrichmentEntryDefinition(
              catalogIdentifier: "safari.reading-list.search", title: "Reading List"),
          ]
        )
      ],
      appActionEnrichments: [
        AppActionEnrichmentDefinition(
          bundleIdentifiers: ["com.apple.Safari"],
          catalogIdentifiers: ["safari.actions"]
        )
      ]
    )
  }
}
