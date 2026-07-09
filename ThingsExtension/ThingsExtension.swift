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
        iconName: "checklist"
      ),
      compatibility: ExtensionDeclarationCompatibility(minTuna: "0.75", minTunaKit: "1.11.0"),
      settings: [
        CatalogSettingDefinition(
          key: "ShowThingsWhenAdding",
          type: .bool,
          label: "Show Things when adding tasks",
          defaultValue: "true",
          description: "When off, Tuna will try to add tasks without activating Things."
        )
      ],
      catalogs: [
        CatalogDeclaration(
          id: "things", type: ThingsCatalog.self, name: "Things Items", enabledByDefault: true),
        CatalogDeclaration(
          id: "things.actions", type: ThingsActionsCatalog.self, name: "Things Actions",
          enabledByDefault: true),
        CatalogDeclaration(
          id: "things.app-actions", type: ThingsAppActionsCatalog.self, name: "Things App Actions",
          enabledByDefault: true),
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
            DefaultActionIdentifier(catalogIdentifier: "things.actions", actionID: "show-in-things")
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
          catalogIdentifiers: ["things.app-actions"]
        )
      ]
    )
  }
}
