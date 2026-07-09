import Foundation
import TunaKit

@objc(NotesExtension)
public final class NotesExtension: Extension {
  public override var declaration: ExtensionDeclaration? {
    ExtensionDeclaration(
      metadata: ExtensionMetadata(
        displayName: "Notes",
        author: "Tuna",
        description: "Search Apple Notes and create new notes.",
        iconName: "note.text"
      ),
      compatibility: ExtensionDeclarationCompatibility(minTuna: "0.65", minTunaKit: "1.11.0"),
      catalogs: [
        CatalogDeclaration(
          id: "notes", type: NotesCatalog.self, name: "Notes", enabledByDefault: true),
        CatalogDeclaration(
          id: "notes.search", type: NotesSearchCatalog.self, name: "Notes", enabledByDefault: true),
        CatalogDeclaration(
          id: "notes.actions", type: NotesActionsCatalog.self, name: "Notes Actions",
          enabledByDefault: true),
      ],
      typeRegistrations: [
        TypeRegistrationDefinition(
          typeID: TypeID("com.tuna.type.note"), displayName: "Notes",
          inheritsFrom: [TypeID("com.tuna.type.entity")])
      ],
      defaultActionRankings: [
        DefaultActionRankingDefinition(
          typeID: TypeID("com.tuna.type.note"),
          actions: [
            DefaultActionIdentifier(catalogIdentifier: "notes.search", actionID: "open-in-notes")
          ]
        )
      ],
      appBrowseEnrichments: [
        AppBrowseEnrichmentDefinition(
          bundleIdentifiers: ["com.apple.Notes"],
          entries: [AppBrowseEnrichmentEntryDefinition(catalogIdentifier: "notes")]
        )
      ],
      appActionEnrichments: [
        AppActionEnrichmentDefinition(
          bundleIdentifiers: ["com.apple.Notes"],
          catalogIdentifiers: ["notes.actions"]
        )
      ]
    )
  }
}
