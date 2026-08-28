import Foundation
import TunaKit

@objc(PoofExtension)
public final class PoofExtension: Extension {
  public override var declaration: ExtensionDeclaration? {
    ExtensionDeclaration(
      metadata: ExtensionMetadata(
        displayName: "Poof",
        author: "Mikkel Malmberg",
        description: "Find, paste, create, delete, and edit Poof text snippets.",
        iconName: "text.quote"
      ),
      compatibility: ExtensionDeclarationCompatibility(minTuna: "0.94", minTunaKit: "1.20.0"),
      catalogs: [
        CatalogDeclaration(
          id: "poof.snippets",
          type: PoofCatalog.self,
          name: "Poof Snippets",
          enabledByDefault: true
        ),
        CatalogDeclaration(
          id: "poof.snippets.search",
          type: PoofBrowseCatalog.self,
          name: "Poof Snippets",
          enabledByDefault: true
        )
      ],
      actionCatalogs: [
        ActionCatalogDeclaration(
          id: "poof.actions",
          type: PoofActionsCatalog.self,
          name: "Poof Actions"
        )
      ],
      typeRegistrations: [
        TypeRegistrationDefinition(typeID: .poofSnippet, inheritsFrom: [.textSnippet]),
        TypeRegistrationDefinition(typeID: .poofLibrary, inheritsFrom: [.entity]),
      ],
      defaultActionRankings: [
        DefaultActionRankingDefinition(
          typeID: .poofLibrary,
          actions: [
            ActionReference(catalogIdentifier: "poof.actions", actionID: "open-library")
          ]
        ),
      ],
      appBrowseEnrichments: [
        AppBrowseEnrichmentDefinition(
          bundleIdentifiers: ["com.brnbw.Poof"],
          entries: [
            AppBrowseEnrichmentEntryDefinition(
              catalogIdentifier: "poof.snippets.search",
              title: "Snippets"
            )
          ]
        )
      ]
    )
  }
}
