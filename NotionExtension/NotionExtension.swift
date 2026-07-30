import Foundation
import TunaKit

@objc(NotionExtension)
public final class NotionExtension: Extension {
  public override var declaration: ExtensionDeclaration? {
    ExtensionDeclaration(
      metadata: ExtensionMetadata(
        displayName: "Notion",
        author: "Tuna",
        description: "Browse and search Notion, with optional top-level pages in global search.",
        iconName: "book.pages"
      ),
      compatibility: ExtensionDeclarationCompatibility(minTuna: "0.83", minTunaKit: "1.15.0"),
      catalogs: [
        CatalogDeclaration(
          id: "notion", type: NotionCatalog.self, name: "Notion", enabledByDefault: true),
        CatalogDeclaration(
          id: "notion.pages", type: NotionPagesCatalog.self, name: "Pages", enabledByDefault: false),
      ],
      appBrowseEnrichments: [
        AppBrowseEnrichmentDefinition(
          bundleIdentifiers: ["notion.id"],
          entries: [
            AppBrowseEnrichmentEntryDefinition(catalogIdentifier: "notion"),
            AppBrowseEnrichmentEntryDefinition(catalogIdentifier: "notion.pages", title: "Pages"),
          ]
        )
      ]
    )
  }

  public override var connectionDefinitions: [ExtensionConnectionDefinition] {
    [NotionCatalogSupport.connectionDefinition]
  }
}
