import Foundation
import TunaKit

@objc(ObsidianExtension)
public final class ObsidianExtension: Extension {
  public override var declaration: ExtensionDeclaration? {
    ExtensionDeclaration(
      metadata: ExtensionMetadata(
        displayName: "Obsidian",
        author: "Tuna",
        description: "Obsidian vaults, notes, and actions.",
        iconName: "square.stack.3d.up"
      ),
      compatibility: ExtensionDeclarationCompatibility(minTuna: "0.79", minTunaKit: "1.12.0"),
      catalogs: [
        CatalogDeclaration(
          id: "obsidian", type: ObsidianVaultsCatalog.self, name: "Vaults", enabledByDefault: true),
        CatalogDeclaration(
          id: "obsidian.notes", type: ObsidianNotesCatalog.self, name: "Notes",
          enabledByDefault: false),
        CatalogDeclaration(
          id: "obsidian.search", type: ObsidianSearchCatalog.self, name: "Notes",
          enabledByDefault: true),
      ],
      actionCatalogs: [
        ActionCatalogDeclaration(
          id: "obsidian.actions", type: ObsidianActionsCatalog.self, name: "Obsidian Actions"),
      ],
      typeRegistrations: [
        TypeRegistrationDefinition(
          typeID: TypeID("com.tuna.type.obsidian.note"), displayName: "Obsidian Notes",
          inheritsFrom: [TypeID("com.tuna.type.file")]),
        TypeRegistrationDefinition(
          typeID: TypeID("com.tuna.type.obsidian.vault"), displayName: "Obsidian Vaults",
          inheritsFrom: [TypeID("com.tuna.type.directory")]),
      ],
      defaultActionRankings: [
        DefaultActionRankingDefinition(
          typeID: TypeID("com.tuna.type.obsidian.note"),
          actions: [
            DefaultActionIdentifier(catalogIdentifier: "obsidian.actions", actionID: "open")
          ]
        ),
        DefaultActionRankingDefinition(
          typeID: TypeID("com.tuna.type.obsidian.vault"),
          actions: [
            DefaultActionIdentifier(
              catalogIdentifier: "obsidian.actions", actionID: "open-vault-in-obsidian")
          ]
        ),
      ],
      appBrowseEnrichments: [
        AppBrowseEnrichmentDefinition(
          bundleIdentifiers: ["md.obsidian"],
          entries: [AppBrowseEnrichmentEntryDefinition(catalogIdentifier: "obsidian.notes")]
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
