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
        categories: ["Browser"],
        iconName: "safari"
      ),
      compatibility: ExtensionDeclarationCompatibility(minTuna: "0.65"),
      catalogs: [
        CatalogDeclaration(
          id: "safari.bookmarks", type: SafariBookmarksCatalog.self, name: "Bookmarks",
          enabledByDefault: true),
        CatalogDeclaration(
          id: "safari.bookmarks.search", type: SafariBookmarksSearchCatalog.self, name: "Bookmarks",
          enabledByDefault: true),
        CatalogDeclaration(
          id: "safari.reading-list", type: SafariReadingListCatalog.self, name: "Reading List",
          enabledByDefault: true),
        CatalogDeclaration(
          id: "safari.reading-list.search", type: SafariReadingListSearchCatalog.self,
          name: "Reading List", enabledByDefault: true),
        CatalogDeclaration(
          id: "safari.favorites", type: SafariFavoritesCatalog.self, name: "Favorites",
          enabledByDefault: true),
        CatalogDeclaration(
          id: "safari.favorites.search", type: SafariFavoritesSearchCatalog.self, name: "Favorites",
          enabledByDefault: true),
        CatalogDeclaration(
          id: "safari.app", type: SafariMetaCatalog.self, name: "Safari Meta",
          enabledByDefault: true),
        CatalogDeclaration(
          id: "safari.actions", type: SafariActionsCatalog.self, name: "Safari Actions",
          enabledByDefault: true),
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
