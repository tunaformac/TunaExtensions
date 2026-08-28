import Foundation
import TunaKit

@objc(ThingsExtension)
public final class ThingsExtension: Extension {
  public override var declaration: ExtensionDeclaration? {
    ExtensionDeclaration(
      metadata: ExtensionMetadata(
        displayName: "Things",
        author: "Tuna",
        description: "Create Things to-dos and jump to lists.",
        iconName: "checkmark.circle"
      ),
      compatibility: ExtensionDeclarationCompatibility(minTuna: "0.95", minTunaKit: "1.21.0"),
      settings: [
        CatalogSettingDefinition(
          key: "ShowThingsWhenAdding",
          type: .bool,
          label: "Show Things when adding to-dos",
          defaultValue: "true",
          description: "When off, Tuna will try to add to-dos without activating Things."
        )
      ],
      catalogs: [
        CatalogDeclaration(
          id: "things", type: ThingsCatalog.self, name: "Things Items", presentation: .source,
          enabledByDefault: true),
      ],
      actionCatalogs: [
        ActionCatalogDeclaration(
          id: "things.actions", type: ThingsActionsCatalog.self, name: "Things Actions"),
      ],
      typeRegistrations: [
        TypeRegistrationDefinition(
          typeID: TypeID("com.tuna.type.things-list"), displayName: "Things Lists",
          inheritsFrom: [TypeID("com.tuna.type.entity")])
      ],
      defaultActionRankings: [
        DefaultActionRankingDefinition(
          typeID: TypeID("com.tuna.type.things-list"),
          actions: [
            ActionReference(catalogIdentifier: "things.actions", actionID: "show-in-things")
          ]
        )
      ],
      appBrowseEnrichments: [
        AppBrowseEnrichmentDefinition(
          bundleIdentifiers: ["com.culturedcode.ThingsMac"],
          entries: [AppBrowseEnrichmentEntryDefinition(catalogIdentifier: "things")]
        )
      ],
      appActionEnrichments: [
        AppActionEnrichmentDefinition(
          bundleIdentifiers: ["com.culturedcode.ThingsMac"],
          catalogIdentifiers: ["things.actions"]
        )
      ]
    )
  }
}
