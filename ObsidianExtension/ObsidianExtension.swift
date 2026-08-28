import Foundation
import TunaKit

@objc(ObsidianExtension)
public final class ObsidianExtension: Extension {
  public override var declaration: ExtensionDeclaration? {
    ExtensionDeclaration(
      metadata: ExtensionMetadata(
        displayName: "Obsidian",
        author: "Tuna",
        description: "Browse Obsidian vaults, folders, and notes, with quick capture actions.",
        iconName: "square.stack.3d.up"
      ),
      compatibility: ExtensionDeclarationCompatibility(minTuna: "0.95", minTunaKit: "1.21.0"),
      catalogs: [
        CatalogDeclaration(
          id: "obsidian", type: ObsidianVaultsCatalog.self, name: "Vaults",
          presentation: .source, enabledByDefault: true),
        CatalogDeclaration(
          id: "obsidian.notes", type: ObsidianNotesCatalog.self, name: "Notes",
          presentation: .source, enabledByDefault: false),
        CatalogDeclaration(
          id: "obsidian.search", type: ObsidianSearchCatalog.self, name: "Notes",
          presentation: .browseRoot(contents: "obsidian.notes"), enabledByDefault: true),
      ],
      actionCatalogs: [
        ActionCatalogDeclaration(
          id: "obsidian.actions", type: ObsidianActionsCatalog.self, name: "Obsidian Actions"),
      ],
      typeRegistrations: [
        TypeRegistrationDefinition(
          typeID: TypeID("com.tuna.type.obsidian-note"), displayName: "Obsidian Notes",
          inheritsFrom: [TypeID("com.tuna.type.file")]),
        TypeRegistrationDefinition(
          typeID: TypeID("com.tuna.type.obsidian-vault"), displayName: "Obsidian Vaults",
          inheritsFrom: [TypeID("com.tuna.type.directory")]),
      ],
      defaultActionRankings: [
        DefaultActionRankingDefinition(
          typeID: TypeID("com.tuna.type.obsidian-note"),
          actions: [
            ActionReference(
              catalogIdentifier: ObsidianCatalogIdentifiers.actions,
              actionID: ObsidianActionHierarchyIdentifiers.openNote)
          ]
        ),
        DefaultActionRankingDefinition(
          typeID: TypeID("com.tuna.type.obsidian-vault"),
          actions: [
            ActionReference(
              catalogIdentifier: "obsidian.actions", actionID: "open-vault-in-obsidian")
          ]
        ),
      ],
      appBrowseEnrichments: [
        AppBrowseEnrichmentDefinition(
          bundleIdentifiers: ["md.obsidian"],
          entries: [
            AppBrowseEnrichmentEntryDefinition(catalogIdentifier: "obsidian", title: "Vaults")
          ]
        )
      ],
      appActionEnrichments: [
        AppActionEnrichmentDefinition(
          bundleIdentifiers: ["md.obsidian"],
          catalogIdentifiers: ["obsidian.actions"]
        )
      ]
    )
  }
}
